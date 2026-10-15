import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:exif/exif.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../models/photo.dart';

/// 支持索引的图片扩展名。
const Set<String> kSupportedExtensions = {
  '.jpg',
  '.jpeg',
  '.jpe',
  '.jfif',
  '.png',
  '.bmp',
  '.gif',
  '.webp',
  '.tif',
  '.tiff',
  '.heic',
  '.heif',
  '.avif',
};

bool isSupportedImage(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return kSupportedExtensions.contains(path.substring(dot).toLowerCase());
}

/// 负责把单个图片文件转换成带缩略图的 [Photo] 记录。
class ImageIndexer {
  const ImageIndexer({this.thumbnailSize = 400});

  /// 缩略图最长边的像素尺寸。
  final int thumbnailSize;

  Future<Photo?> indexImage(
    String path,
    String folderPath, {
    int? fileSize,
    int? fileModified,
  }) async {
    final file = File(path);
    var size = fileSize ?? 0;
    var modified = fileModified ?? 0;
    if (fileSize == null || fileModified == null) {
      try {
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) return null;
        size = stat.size;
        modified = stat.modified.millisecondsSinceEpoch;
      } catch (_) {
        return null;
      }
    }

    // EXIF 解析是同步 IO + 纯 Dart 计算，放进独立 isolate 以免卡住界面。
    Map<String, Object?> exif = const {};
    try {
      exif = await Isolate.run(() => readExifFacts(path));
    } catch (_) {
      exif = const {};
    }

    final orientation = _asInt(exif['orientation']);

    Uint8List? thumbnail;
    // EXIF 里的尺寸容易被二次编辑的软件写错或剥离，只作为解码失败时的兜底。
    int? width = _asInt(exif['imageWidth']);
    int? height = _asInt(exif['imageLength']);
    try {
      final bytes = await file.readAsBytes();
      final result = await buildThumbnail(bytes, thumbnailSize, orientation);
      if (result != null) {
        thumbnail = result.bytes;
        // 解码得到的才是文件真实分辨率。
        width = result.originalWidth;
        height = result.originalHeight;
      }
    } catch (_) {
      // 无法解码时依旧保留元数据记录。
    }

    final fileName = path.split(RegExp(r'[\\/]')).last;

    return Photo(
      path: path,
      fileName: fileName,
      folderPath: folderPath,
      dirPath: p.dirname(path),
      fileSize: size,
      fileModified: modified,
      width: width,
      height: height,
      captureTime: _asDateTime(exif['captureTime']),
      cameraMake: _asString(exif['make']),
      cameraModel: _asString(exif['model']),
      lensModel: _asString(exif['lensModel']),
      fNumber: _asDouble(exif['fNumber']),
      exposureTime: _asDouble(exif['exposureTime']),
      iso: _asInt(exif['iso']),
      focalLength: _asDouble(exif['focalLength']),
      focalLength35mm: _asDouble(exif['focalLength35mm']),
      exposureBias: _asDouble(exif['exposureBias']),
      orientation: orientation,
      gpsLat: _asDouble(exif['gpsLat']),
      gpsLon: _asDouble(exif['gpsLon']),
      gpsAltitude: _asDouble(exif['gpsAltitude']),
      thumbnail: thumbnail,
      indexedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  // ------------------------------------------------------------ 类型转换

  static String? _asString(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  static int? _asInt(Object? v) => v is num ? v.toInt() : null;

  static double? _asDouble(Object? v) {
    if (v is! num) return null;
    final d = v.toDouble();
    return d.isFinite ? d : null;
  }

  static DateTime? _asDateTime(Object? v) {
    if (v is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(v);
  }
}

/// 生成缩略图的结果。
class ThumbnailResult {
  const ThumbnailResult(
    this.bytes,
    this.width,
    this.height,
    this.originalWidth,
    this.originalHeight,
  );

  final Uint8List bytes;

  /// 缩略图自身尺寸（已按 EXIF 方向旋正）。
  final int width;
  final int height;

  /// 原文件记录的真实像素尺寸（未按方向旋转），用于展示照片分辨率。
  final int originalWidth;
  final int originalHeight;
}

/// 使用引擎原生解码（快）拿到目标尺寸的 RGBA，再用纯 Dart 编码为 JPEG。
Future<ThumbnailResult?> buildThumbnail(
  Uint8List bytes,
  int maxSize,
  int? orientation,
) async {
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final originWidth = descriptor.width;
    final originHeight = descriptor.height;
    if (originWidth <= 0 || originHeight <= 0) return null;

    final scale = maxSize / math.max(originWidth, originHeight);
    final targetWidth = scale < 1
        ? math.max(1, (originWidth * scale).round())
        : originWidth;
    final targetHeight = scale < 1
        ? math.max(1, (originHeight * scale).round())
        : originHeight;

    codec = await descriptor.instantiateCodec(
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;

    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) return null;

    var decoded = img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );

    if (orientation != null && orientation > 1) {
      decoded.exif.imageIfd.orientation = orientation;
      decoded = img.bakeOrientation(decoded);
    }

    final encoded = img.encodeJpg(decoded, quality: 82);
    return ThumbnailResult(
      Uint8List.fromList(encoded),
      decoded.width,
      decoded.height,
      originWidth,
      originHeight,
    );
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
  }
}

// ---------------------------------------------------------------- EXIF 解析

/// 解析 EXIF，返回仅含基本类型的字典以便跨 isolate 传递。
///
/// 该函数是同步文件读写的，必须在独立 isolate 中调用。
Future<Map<String, Object?>> readExifFacts(String path) async {
  final result = <String, Object?>{};
  Map<String, IfdTag> tags;
  try {
    tags = await readExifFromFile(File(path), details: false);
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
