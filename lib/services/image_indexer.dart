import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;

import '../models/photo.dart';
import 'image_codec.dart';
import 'index_worker_pool.dart';
import 'scan_timings.dart';

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
///
/// 分工：
/// - 主 isolate：读文件、用引擎原生解码（`dart:ui` 只能在根 isolate 用）
/// - worker 池：EXIF 解析、JPEG 编码（纯 Dart、CPU 密集）
class ImageIndexer {
  const ImageIndexer({this.thumbnailSize = 400});

  /// 缩略图最长边的像素尺寸。
  final int thumbnailSize;

  Future<Photo?> indexImage(
    String path,
    String folderPath, {
    required int libraryId,
    required IndexWorkerPool pool,
    int? fileSize,
    int? fileModified,
    ScanTimings? timings,
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

    // 一次读盘同时供解码和 EXIF 使用：慢盘/坏块盘上第二次读文件是主要瓶颈。
    Uint8List bytes;
    final readWatch = Stopwatch()..start();
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      // 读不出来（坏块、权限、文件被删除）直接算失败，不写入半条记录。
      timings?.readUs += readWatch.elapsedMicroseconds;
      return null;
    }
    timings?.readUs += readWatch.elapsedMicroseconds;

    final decodeWatch = Stopwatch()..start();
    final decoded = await decodeThumbnailSource(bytes, thumbnailSize);
    timings?.decodeUs += decodeWatch.elapsedMicroseconds;

    final exifResult = await _safeExif(pool, bytes);
    timings?.exifUs += exifResult.microseconds;
    final exif = exifResult.facts;
    final orientation = _asInt(exif['orientation']);

    // EXIF 里的尺寸容易被二次编辑的软件写错或剥离，只作为解码失败时的兜底。
    int? width = _asInt(exif['imageWidth']);
    int? height = _asInt(exif['imageLength']);

    Uint8List? thumbnail;
    if (decoded != null) {
      // 解码得到的才是文件真实分辨率。
      width = decoded.originalWidth;
      height = decoded.originalHeight;
      try {
        final encoded = await pool.runEncode(decoded, orientation);
        timings?.encodeUs += encoded.microseconds;
        thumbnail = encoded.thumbnail?.bytes;
      } catch (_) {
        thumbnail = null;
      }
    }

    final fileName = path.split(RegExp(r'[\\/]')).last;

    return Photo(
      libraryId: libraryId,
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

  /// EXIF 失败不影响整条记录，返回空字典继续。
  Future<({Map<String, Object?> facts, int microseconds})> _safeExif(
    IndexWorkerPool pool,
    Uint8List bytes,
  ) async {
    try {
      return await pool.runExifBytes(bytes);
    } catch (_) {
      return (facts: const <String, Object?>{}, microseconds: 0);
    }
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

/// 用引擎原生解码把图片缩到目标尺寸，并取出 RGBA 像素。
///
/// 必须在主 isolate 调用；编码交给 worker 池。
Future<DecodedThumbnail?> decodeThumbnailSource(
  Uint8List bytes,
  int maxSize,
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

    return DecodedThumbnail(
      rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
      image.width,
      image.height,
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
