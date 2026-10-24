import 'dart:math' as math;
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:image/image.dart' as img;

/// 主 isolate 解码出来的缩略图源数据（尚未编码）。
class DecodedThumbnail {
  const DecodedThumbnail(
    this.rgba,
    this.width,
    this.height,
    this.originalWidth,
    this.originalHeight,
  );

  /// 紧凑排列的 RGBA8888 像素。
  final Uint8List rgba;

  /// 缩略图尺寸（未按 EXIF 方向旋转）。
  final int width;
  final int height;

  /// 原文件真实像素尺寸（未旋转）。
  final int originalWidth;
  final int originalHeight;
}

/// 编码完成的缩略图。
class EncodedThumbnail {
  const EncodedThumbnail(this.bytes, this.width, this.height);

  final Uint8List bytes;

  /// 已按 EXIF 方向旋正后的尺寸。
  final int width;
  final int height;
}

/// 把 RGBA 像素编码成 JPEG 缩略图，并烘焙 EXIF 方向。
///
/// 纯 Dart 计算，放在 worker isolate 里执行。
EncodedThumbnail? encodeThumbnailFromRgba(
  Uint8List rgba,
  int width,
  int height,
  int? orientation,
) {
  if (width <= 0 || height <= 0) return null;
  var image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  if (orientation != null && orientation > 1) {
    image.exif.imageIfd.orientation = orientation;
    image = img.bakeOrientation(image);
  }
  final encoded = img.encodeJpg(image, quality: 82);
  return EncodedThumbnail(
    Uint8List.fromList(encoded),
    image.width,
    image.height,
  );
}

// ---------------------------------------------------------------- EXIF 解析

/// 从已经读入内存的文件字节里解析 EXIF。
///
/// 复用解码时读取的同一份字节，避免为了读 EXIF 再把文件打开一次——
/// 在机械盘/有坏块的盘上，第二次读盘往往比解析本身贵几个数量级。
Future<Map<String, Object?>> readExifFactsFromBytes(Uint8List bytes) async {
  final result = <String, Object?>{};
  Map<String, IfdTag> tags;
  try {
    tags = await readExifFromBytes(bytes, details: false);
  } catch (_) {
    return result;
  }
  if (tags.isEmpty) return result;

  String? text(String key) {
    final value = tags[key]?.printable;
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  double? ratio(String key) {
    final values = tags[key]?.values;
    if (values == null || values.length == 0) return null;
    if (values is IfdRatios) {
      final r = values.ratios.first;
      if (r.denominator == 0) return null;
      final d = r.toDouble();
      return d.isFinite ? d : null;
    }
    return values.firstAsInt().toDouble();
  }

  int? integer(String key) {
    final values = tags[key]?.values;
    if (values == null || values.length == 0) return null;
    return values.firstAsInt();
  }

  result['make'] = text('Image Make');
  result['model'] = text('Image Model');
  result['lensModel'] = text('EXIF LensModel') ?? text('EXIF Lens');
  result['orientation'] = integer('Image Orientation');
  result['imageWidth'] =
      integer('Image ImageWidth') ?? integer('EXIF ExifImageWidth');
  result['imageLength'] =
      integer('Image ImageLength') ?? integer('EXIF ExifImageLength');
  result['software'] = text('Image Software');

  final dateText =
      text('EXIF DateTimeOriginal') ??
      text('EXIF DateTimeDigitized') ??
      text('Image DateTime');
  final captureMs = parseExifDate(dateText);
  if (captureMs != null) result['captureTime'] = captureMs;

  var fNumber = ratio('EXIF FNumber');
  if (fNumber == null) {
    // 没有 FNumber 时用 APEX 光圈值换算：F = sqrt(2)^Av
    final apex = ratio('EXIF ApertureValue');
    if (apex != null) fNumber = math.pow(math.sqrt2, apex).toDouble();
  }
  result['fNumber'] = fNumber;

  var exposureTime = ratio('EXIF ExposureTime');
  if (exposureTime == null) {
    // 快门优先值时换算：t = 1 / 2^Tv
    final apex = ratio('EXIF ShutterSpeedValue');
    if (apex != null) {
      final seconds = 1 / math.pow(2, apex);
      exposureTime = seconds.isFinite ? seconds : null;
    }
  }
  result['exposureTime'] = exposureTime;

  result['iso'] =
      integer('EXIF ISOSpeedRatings') ??
      integer('EXIF PhotographicSensitivity');
  result['focalLength'] = ratio('EXIF FocalLength');
  result['focalLength35mm'] = ratio('EXIF FocalLengthIn35mmFilm');
  result['exposureBias'] = ratio('EXIF ExposureBiasValue');
  result['exposureProgram'] = text('EXIF ExposureProgram');
  result['meteringMode'] = text('EXIF MeteringMode');
  result['flash'] = text('EXIF Flash');
  result['whiteBalance'] = text('EXIF WhiteBalance');

  final lat = _gpsToDecimal(tags, 'GPS GPSLatitude', 'GPS GPSLatitudeRef');
  final lon = _gpsToDecimal(tags, 'GPS GPSLongitude', 'GPS GPSLongitudeRef');
  if (lat != null) result['gpsLat'] = lat;
  if (lon != null) result['gpsLon'] = lon;

  final altitude = ratio('GPS GPSAltitude');
  if (altitude != null) {
    final belowSea = integer('GPS GPSAltitudeRef') == 1;
    result['gpsAltitude'] = belowSea ? -altitude : altitude;
  }

  return result;
}

double? _gpsToDecimal(
  Map<String, IfdTag> tags,
  String valueKey,
  String refKey,
) {
  final values = tags[valueKey]?.values;
  if (values is! IfdRatios || values.ratios.length < 3) return null;
  final degrees = values.ratios[0].denominator == 0
      ? 0.0
      : values.ratios[0].toDouble();
  final minutes = values.ratios[1].denominator == 0
      ? 0.0
      : values.ratios[1].toDouble();
  final seconds = values.ratios[2].denominator == 0
      ? 0.0
      : values.ratios[2].toDouble();
  var decimal = degrees + minutes / 60 + seconds / 3600;
  if (!decimal.isFinite) return null;
  final ref = tags[refKey]?.printable.trim().toUpperCase();
  if (ref == 'S' || ref == 'W') decimal = -decimal;
  return decimal;
}

/// 解析 EXIF 日期字符串，例如 `2024:05:01 12:30:45`。
int? parseExifDate(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'(\d{4})[:\-/](\d{1,2})[:\-/](\d{1,2})[ T](\d{1,2}):(\d{1,2}):(\d{1,2})',
  ).firstMatch(value);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  if (year < 1826 || year > 2200) return null;
  try {
    return DateTime(
      year,
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    ).millisecondsSinceEpoch;
  } catch (_) {
    return null;
  }
}
