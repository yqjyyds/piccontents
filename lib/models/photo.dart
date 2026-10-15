import 'dart:typed_data';

/// 一条被索引的照片记录：包含文件信息、EXIF 元数据以及离线可用的缩略图。
class Photo {
  final int? id;

  /// 照片的绝对路径。
  final String path;
  final String fileName;

  /// 该照片所属的被扫描根目录。
  final String folderPath;

  /// 照片所在的实际目录（可能是根目录下的任意层级子目录）。
  final String dirPath;

  final int fileSize;
  final int fileModified;

  /// 文件中记录的像素尺寸（未按方向旋转）。
  final int? width;
  final int? height;

  final DateTime? captureTime;
  final String? cameraMake;
  final String? cameraModel;
  final String? lensModel;

  /// 光圈 F 值。
  final double? fNumber;

  /// 快门时间，单位秒。
  final double? exposureTime;
  final int? iso;
  final double? focalLength;
  final double? focalLength35mm;
  final double? exposureBias;

  /// EXIF 方向标记（1-8）。
  final int? orientation;

  final double? gpsLat;
  final double? gpsLon;
  final double? gpsAltitude;

  /// 预生成的缩略图（JPEG），已按方向旋正，离线时依然可显示。
  final Uint8List? thumbnail;

  final int indexedAt;

  Photo({
    this.id,
    required this.path,
    required this.fileName,
    required this.folderPath,
    String? dirPath,
    this.fileSize = 0,
    this.fileModified = 0,
    this.width,
    this.height,
    this.captureTime,
    this.cameraMake,
    this.cameraModel,
    this.lensModel,
    this.fNumber,
    this.exposureTime,
    this.iso,
    this.focalLength,
    this.focalLength35mm,
    this.exposureBias,
    this.orientation,
    this.gpsLat,
    this.gpsLon,
    this.gpsAltitude,
    this.thumbnail,
    this.indexedAt = 0,
  }) : dirPath = dirPath ?? parentDirectoryOf(path);

  /// 取文件所在目录，兼容 `C:\a.jpg` 这类位于盘符根目录的情况。
  static String parentDirectoryOf(String path) {
    final index = path.lastIndexOf(RegExp(r'[\\/]'));
    if (index < 0) return path;
    if (index == 2 && path.length > 2 && path[1] == ':') {
      return path.substring(0, 3);
    }
    return path.substring(0, index);
  }

  /// 原始文件是否还在磁盘上（文件夹脱机时为 false）。
  bool isFileAvailable = false;

  /// 是否包含相机相关的有效信息。
  bool get hasCameraInfo =>
      (cameraMake != null && cameraMake!.isNotEmpty) ||
      (cameraModel != null && cameraModel!.isNotEmpty);

  bool get hasGps => gpsLat != null && gpsLon != null;

  /// 显示用的相机名称，例如 "NIKON CORPORATION NIKON Z 6"。
  String get cameraLabel {
    final parts = <String>[];
    if (cameraMake != null && cameraMake!.trim().isNotEmpty) {
      parts.add(cameraMake!.trim());
    }
    if (cameraModel != null && cameraModel!.trim().isNotEmpty) {
      final model = cameraModel!.trim();
      if (parts.isEmpty ||
          !model.toLowerCase().startsWith(parts.first.toLowerCase())) {
        parts.add(model);
      }
    }
    return parts.isEmpty ? '未知设备' : parts.join(' ');
  }

  /// 按方向标记换算后的显示宽高。
  int? get displayWidth => _swapped ? height : width;
  int? get displayHeight => _swapped ? width : height;

  bool get _swapped {
    final o = orientation;
    return o == 5 || o == 6 || o == 7 || o == 8;
  }

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'path': path,
    'file_name': fileName,
    'folder_path': folderPath,
    'dir_path': dirPath,
    'file_size': fileSize,
    'file_modified': fileModified,
    'width': width,
    'height': height,
    'capture_time': captureTime?.millisecondsSinceEpoch,
    'camera_make': cameraMake,
    'camera_model': cameraModel,
    'lens_model': lensModel,
    'f_number': fNumber,
    'exposure_time': exposureTime,
    'iso': iso,
    'focal_length': focalLength,
    'focal_length_35mm': focalLength35mm,
    'exposure_bias': exposureBias,
    'orientation': orientation,
    'gps_lat': gpsLat,
    'gps_lon': gpsLon,
    'gps_altitude': gpsAltitude,
    'thumbnail': thumbnail,
    'indexed_at': indexedAt,
  };

  factory Photo.fromMap(Map<String, Object?> map) {
    final captureMs = map['capture_time'] as int?;
    return Photo(
      id: map['id'] as int?,
      path: map['path'] as String,
      fileName: map['file_name'] as String? ?? '',
      folderPath: map['folder_path'] as String? ?? '',
      dirPath: map['dir_path'] as String?,
      fileSize: map['file_size'] as int? ?? 0,
      fileModified: map['file_modified'] as int? ?? 0,
      width: map['width'] as int?,
      height: map['height'] as int?,
      captureTime: captureMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(captureMs),
      cameraMake: map['camera_make'] as String?,
      cameraModel: map['camera_model'] as String?,
      lensModel: map['lens_model'] as String?,
      fNumber: (map['f_number'] as num?)?.toDouble(),
      exposureTime: (map['exposure_time'] as num?)?.toDouble(),
      iso: map['iso'] as int?,
      focalLength: (map['focal_length'] as num?)?.toDouble(),
      focalLength35mm: (map['focal_length_35mm'] as num?)?.toDouble(),
      exposureBias: (map['exposure_bias'] as num?)?.toDouble(),
      orientation: map['orientation'] as int?,
      gpsLat: (map['gps_lat'] as num?)?.toDouble(),
      gpsLon: (map['gps_lon'] as num?)?.toDouble(),
      gpsAltitude: (map['gps_altitude'] as num?)?.toDouble(),
      thumbnail: map['thumbnail'] as Uint8List?,
      indexedAt: map['indexed_at'] as int? ?? 0,
    );
  }
}

/// 照片列表排序方式。
enum PhotoSort {
  captureTimeDesc('拍摄时间（新→旧）', '(capture_time IS NULL), capture_time DESC'),
  captureTimeAsc('拍摄时间（旧→新）', '(capture_time IS NULL), capture_time ASC'),
  fileNameAsc('文件名（A→Z）', 'file_name COLLATE NOCASE ASC'),
  fileModifiedDesc('文件修改时间（新→旧）', 'file_modified DESC'),
  fileSizeDesc('文件大小（大→小）', 'file_size DESC'),
  indexedDesc('索引时间（新→旧）', 'indexed_at DESC');

  const PhotoSort(this.label, this.orderBy);

  final String label;
  final String orderBy;
}
