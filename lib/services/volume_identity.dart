import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../utils/index_paths.dart';

/// 一个卷（分区）的身份信息。
///
/// 盘符会在换盘时重复使用，不能用来判断"是不是同一块硬盘"。
/// 这里用卷 GUID 作为主键、卷序列号作为兜底：
/// - 卷 GUID 由 Windows 按卷分配，换盘符也不变；
/// - 卷序列号在格式化后会变，所以只在拿不到 GUID 时使用。
class VolumeIdentity {
  const VolumeIdentity({this.guid, this.serial, this.label});

  /// 形如 `\\?\Volume{xxxxxxxx-....}\`。
  final String? guid;

  /// 卷序列号（32 位）。
  final int? serial;

  /// 卷标（可能为空）。
  final String? label;

  bool get isUsable => guid != null || serial != null;

  /// 与另一份记录是否指向同一个卷。
  bool matches(VolumeIdentity? other) {
    if (other == null) return false;
    if (guid != null && other.guid != null) return guid == other.guid;
    if (serial != null && other.serial != null) return serial == other.serial;
    return false;
  }

  String get displayName {
    final value = label?.trim() ?? '';
    return value.isEmpty ? '未命名卷' : value;
  }
}

const int _maxPath = 261;

final RegExp _driveRootPattern = RegExp(r'^[A-Za-z]:\\$');

/// 识别 [path] 所在卷（盘符根）的身份。
///
/// 网络路径、无法访问的盘、非 Windows 环境一律返回 null，
/// 调用方应退回"不检测"的旧行为。
VolumeIdentity? identifyVolume(String path) {
  if (!Platform.isWindows) return null;
  final root = p.rootPrefix(normalizeIndexRootPath(path));
  if (!_driveRootPattern.hasMatch(root)) return null;

  final _VolumeApi api;
  try {
    api = _VolumeApi.instance;
  } catch (_) {
    return null;
  }

  final rootPtr = root.toNativeUtf16();
  final guidRaw = calloc<Uint16>(_maxPath);
  final labelRaw = calloc<Uint16>(_maxPath);
  final fsRaw = calloc<Uint16>(_maxPath);
  final serialPtr = calloc<Uint32>();
  try {
    final gotGuid = api.getVolumeName(rootPtr, guidRaw.cast<Utf16>(), _maxPath);
    final gotInfo = api.getVolumeInfo(
      rootPtr,
      labelRaw.cast<Utf16>(),
      _maxPath,
      serialPtr,
      nullptr,
      nullptr,
      fsRaw.cast<Utf16>(),
      _maxPath,
    );

    final guid = gotGuid != 0 ? guidRaw.cast<Utf16>().toDartString() : null;
    final label = gotInfo != 0 ? labelRaw.cast<Utf16>().toDartString() : null;
    final serial = gotInfo != 0 ? serialPtr.value : null;
    if (guid == null && serial == null) return null;
    return VolumeIdentity(guid: guid, serial: serial, label: label);
  } catch (_) {
    return null;
  } finally {
    malloc.free(rootPtr);
    malloc.free(guidRaw);
    malloc.free(labelRaw);
    malloc.free(fsRaw);
    malloc.free(serialPtr);
  }
}

typedef _GetVolumeNameNative = Int32 Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
  Uint32,
);
typedef _GetVolumeNameDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int);

typedef _GetVolumeInfoNative = Int32 Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Utf16>,
  Uint32,
);
typedef _GetVolumeInfoDart = int Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
  int,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Utf16>,
  int,
);

class _VolumeApi {
  _VolumeApi() {
    final lib = DynamicLibrary.open('kernel32.dll');
    getVolumeName = lib
        .lookupFunction<_GetVolumeNameNative, _GetVolumeNameDart>(
          'GetVolumeNameForVolumeMountPointW',
        );
    getVolumeInfo = lib
        .lookupFunction<_GetVolumeInfoNative, _GetVolumeInfoDart>(
          'GetVolumeInformationW',
        );
  }

  late final _GetVolumeNameDart getVolumeName;
  late final _GetVolumeInfoDart getVolumeInfo;

  static final _VolumeApi instance = _VolumeApi();
}
