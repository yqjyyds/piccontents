import 'package:path/path.dart' as p;

/// 统一索引目录写法：盘符根（`C:`、`C:/`、`c:\`）统一成 `C:\`，
/// 其余路径交给 `p.normalize`，并去掉末尾多余的分隔符。
///
/// 选择磁盘根目录时系统返回的写法并不固定，不统一会让 `folder_path`
/// 比较、面包屑和「移除索引」对不上。
String normalizeIndexRootPath(String path) {
  final value = path.trim();
  if (value.isEmpty) return value;
  final driveRoot = RegExp(r'^([A-Za-z]):[\\/]*$').firstMatch(value);
  if (driveRoot != null) {
    return '${driveRoot.group(1)!.toUpperCase()}:\\';
  }
  var normalized = p.normalize(value);
  while (normalized.length > 1 && normalized.endsWith(p.separator)) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}
