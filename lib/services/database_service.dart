import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/app_settings.dart';
import '../models/photo.dart';
import '../models/photo_filter.dart';

/// 一个子文件夹的概览信息，用于文件夹视图。
class FolderSummary {
  const FolderSummary({
    required this.path,
    required this.name,
    required this.photoCount,
    required this.subFolderCount,
    this.cover,
  });

  /// 文件夹绝对路径。
  final String path;

  /// 显示名（最后一级目录名）。
  final String name;

  /// 该文件夹及其所有子目录下的照片总数。
  final int photoCount;

  /// 直接子文件夹数量。
  final int subFolderCount;

  /// 封面缩略图。
  final Uint8List? cover;
}

/// 本地 SQLite 图库数据库：保存缩略图与 EXIF 元数据，支持脱机检索。
class DatabaseService {
  DatabaseService._();

  static final DatabaseService instance = DatabaseService._();

  static const int _schemaVersion = 3;

  Database? _db;
  String? _dbPath;

  /// 当前数据库文件路径。
  String? get dbPath => _dbPath;

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('数据库尚未初始化');
    }
    return db;
  }

  Future<void> init() async {
    if (_db != null) return;
    sqfliteFfiInit();
    final supportDir = await getApplicationSupportDirectory();
    final dataDir = Directory(p.join(supportDir.path, 'piccontents'));
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }
    _dbPath = p.join(dataDir.path, 'piccontents_library.db');
    _db = await _open(_dbPath!);
  }

  Future<Database> _open(String path) {
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) => _createSchema(db),
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            // v2：新增 dir_path（照片所在的实际目录），用于文件夹视图。
            await db.execute('ALTER TABLE photos ADD COLUMN dir_path TEXT');
            await db.execute(
              'UPDATE photos SET dir_path = '
              'substr(path, 1, length(path) - length(file_name) - 1) '
              'WHERE dir_path IS NULL',
            );
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_photos_dir ON photos(dir_path)',
            );
          }
          if (oldVersion < 3) {
            // v3：新增设置表，用于保存筛选滑条的极值等偏好。
            await db.execute(
              'CREATE TABLE IF NOT EXISTS settings ('
              'key TEXT PRIMARY KEY, '
              'value TEXT NOT NULL)',
            );
          }
        },
      ),
    );
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE,
        added_at INTEGER NOT NULL,
        last_scan_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE photos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE,
        file_name TEXT NOT NULL,
        folder_path TEXT NOT NULL,
        dir_path TEXT,
        file_size INTEGER NOT NULL DEFAULT 0,
        file_modified INTEGER NOT NULL DEFAULT 0,
        width INTEGER,
        height INTEGER,
        capture_time INTEGER,
        camera_make TEXT,
        camera_model TEXT,
        lens_model TEXT,
        f_number REAL,
        exposure_time REAL,
        iso INTEGER,
        focal_length REAL,
        focal_length_35mm REAL,
        exposure_bias REAL,
        orientation INTEGER,
        gps_lat REAL,
        gps_lon REAL,
        gps_altitude REAL,
        thumbnail BLOB,
        indexed_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX idx_photos_folder ON photos(folder_path)');
    await db.execute('CREATE INDEX idx_photos_dir ON photos(dir_path)');
    await db.execute('CREATE INDEX idx_photos_capture ON photos(capture_time)');
    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ---------------------------------------------------------------- 索引根目录

  Future<List<String>> getFolders() async {
    final rows = await _database.query(
      'folders',
      columns: ['path'],
      orderBy: 'added_at ASC',
    );
    return rows.map((r) => r['path'] as String).toList();
  }

  Future<void> addFolder(String path) async {
    await _database.insert('folders', {
      'path': p.normalize(path),
      'added_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> markFolderScanned(String path) async {
    await _database.update(
      'folders',
      {'last_scan_at': DateTime.now().millisecondsSinceEpoch},
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  /// 移除根目录的同时删除它下面的所有索引记录。
  Future<void> removeFolder(String path) async {
    await _database.delete('folders', where: 'path = ?', whereArgs: [path]);
    await _database.delete(
      'photos',
      where: 'folder_path = ?',
      whereArgs: [path],
    );
  }

  Future<Map<String, int>> folderCounts() async {
    final rows = await _database.rawQuery(
      'SELECT folder_path, COUNT(*) AS c FROM photos GROUP BY folder_path',
    );
    return {
      for (final r in rows) r['folder_path'] as String: (r['c'] as int?) ?? 0,
    };
  }

  Future<int> totalCount() async {
    final rows = await _database.rawQuery('SELECT COUNT(*) AS c FROM photos');
    return (rows.first['c'] as int?) ?? 0;
  }

  // ---------------------------------------------------------------- 查询

  /// 生成"位于 [scope] 目录（含其所有子目录）之内"的 SQL 条件。
  ///
  /// 使用 `substr` 前缀比较而不是 `LIKE`，避免路径中的 `_`、`%` 被当作通配符。
  static String _scopeCondition(String scope, List<Object?> args) {
    final prefix = scope.endsWith(p.separator) ? scope : '$scope${p.separator}';
    args
      ..add(scope)
      ..add(prefix.length)
      ..add(prefix);
    return '(dir_path = ? OR substr(dir_path, 1, ?) = ?)';
  }

  static const String _keywordWhere =
      '(file_name LIKE ? OR path LIKE ? OR camera_make LIKE ? OR camera_model LIKE ? '
      'OR lens_model LIKE ? OR date(capture_time / 1000, \'unixepoch\', \'localtime\') LIKE ?)';

  static List<Object?> _keywordArgs(String keyword) {
    final like = '%${keyword.trim()}%';
    return [like, like, like, like, like, like];
  }

  /// 组装带作用域与筛选条件的 WHERE 子句。
  static String _buildWhere({
    String? scopePath,
    String? keyword,
    PhotoFilter? filter,
    required List<Object?> args,
  }) {
    final clauses = <String>[];
    if (scopePath != null && scopePath.isNotEmpty) {
      clauses.add(_scopeCondition(scopePath, args));
    }
    if (filter != null) {
      _addFilterConditions(filter, clauses, args);
    }
    if (keyword != null && keyword.trim().isNotEmpty) {
      clauses.add(_keywordWhere);
      args.addAll(_keywordArgs(keyword));
    }
    return clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}';
  }

  /// 把筛选条件翻译成 SQL。
  static void _addFilterConditions(
    PhotoFilter filter,
    List<String> clauses,
    List<Object?> args,
  ) {
    void addIn(String column, Set<String> values) {
      if (values.isEmpty) return;
      final placeholders = List.filled(values.length, '?').join(',');
      clauses.add('$column IN ($placeholders)');
      args.addAll(values);
    }

    // 单边区间也照常生效；两端都为空时该维度不做限制。
    void addRange(String column, num? min, num? max) {
      if (min == null && max == null) return;
      final parts = <String>['$column IS NOT NULL'];
      if (min != null) {
        parts.add('$column >= ?');
        args.add(min);
      }
      if (max != null) {
        parts.add('$column <= ?');
        args.add(max);
      }
      clauses.add('(${parts.join(' AND ')})');
    }

    addIn('camera_model', filter.cameraModels);
    addIn('lens_model', filter.lensModels);
    addRange('f_number', filter.fNumberMin, filter.fNumberMax);
    addRange('exposure_time', filter.exposureMin, filter.exposureMax);
    addRange('iso', filter.isoMin, filter.isoMax);

    // 拍摄日期区间：capture_time 存的是毫秒时间戳。
    final from = filter.captureFrom;
    final to = filter.captureTo;
    if (from != null || to != null) {
      final parts = <String>['capture_time IS NOT NULL'];
      if (from != null) {
        parts.add('capture_time >= ?');
        args.add(startOfDay(from).millisecondsSinceEpoch);
      }
      if (to != null) {
        parts.add('capture_time <= ?');
        args.add(endOfDay(to).millisecondsSinceEpoch);
      }
      clauses.add('(${parts.join(' AND ')})');
    }
  }

  Future<int> countPhotos({
    String? scopePath,
    String? keyword,
    PhotoFilter? filter,
  }) async {
    final args = <Object?>[];
    final where = _buildWhere(
      scopePath: scopePath,
      keyword: keyword,
      filter: filter,
      args: args,
    );
    final rows = await _database.rawQuery(
      'SELECT COUNT(*) AS c FROM photos$where',
      args,
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<List<Photo>> queryPhotos({
    String? scopePath,
    String? keyword,
    PhotoFilter? filter,
    PhotoSort sort = PhotoSort.captureTimeDesc,
    int offset = 0,
    int limit = 120,
  }) async {
    final args = <Object?>[];
    final where = _buildWhere(
      scopePath: scopePath,
      keyword: keyword,
      filter: filter,
      args: args,
    );
    final rows = await _database.rawQuery(
      'SELECT * FROM photos$where ORDER BY ${sort.orderBy} LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return rows.map(Photo.fromMap).toList();
  }

  /// 读取库中已有的相机型号、镜头以及拍摄参数的取值范围。
  Future<FilterOptions> loadFilterOptions() async {
    final cameras = await _database.rawQuery(
      'SELECT DISTINCT camera_model AS v FROM photos '
      "WHERE camera_model IS NOT NULL AND camera_model <> '' "
      'ORDER BY camera_model COLLATE NOCASE',
    );
    final lenses = await _database.rawQuery(
      'SELECT DISTINCT lens_model AS v FROM photos '
      "WHERE lens_model IS NOT NULL AND lens_model <> '' "
      'ORDER BY lens_model COLLATE NOCASE',
    );
    // 用 CASE 过滤掉 0 / 负数的异常 EXIF 值，否则对数滑条无法取值。
    final range = await _database.rawQuery(
      'SELECT '
      'MIN(CASE WHEN f_number > 0 THEN f_number END) AS f_min, '
      'MAX(CASE WHEN f_number > 0 THEN f_number END) AS f_max, '
      'MIN(CASE WHEN exposure_time > 0 THEN exposure_time END) AS e_min, '
      'MAX(CASE WHEN exposure_time > 0 THEN exposure_time END) AS e_max, '
      'MIN(CASE WHEN iso > 0 THEN iso END) AS i_min, '
      'MAX(CASE WHEN iso > 0 THEN iso END) AS i_max '
      'FROM photos',
    );

    final row = range.isEmpty ? const <String, Object?>{} : range.first;
    return FilterOptions(
      cameraModels: [for (final r in cameras) r['v'] as String],
      lensModels: [for (final r in lenses) r['v'] as String],
      fNumberMin: (row['f_min'] as num?)?.toDouble(),
      fNumberMax: (row['f_max'] as num?)?.toDouble(),
      exposureMin: (row['e_min'] as num?)?.toDouble(),
      exposureMax: (row['e_max'] as num?)?.toDouble(),
      isoMin: (row['i_min'] as num?)?.toInt(),
      isoMax: (row['i_max'] as num?)?.toInt(),
    );
  }

  /// 读取用户设置的滑条极值；未设置过时返回 null（表示按实际数据范围）。
  Future<SliderBounds?> loadSliderBounds() async {
    final rows = await _database.query(
      'settings',
      where: "key LIKE 'slider.%'",
    );
    final values = <String, String>{
      for (final row in rows) row['key'] as String: row['value'] as String,
    };

    double? readDouble(String key) => double.tryParse(values[key] ?? '');
    int? readInt(String key) => int.tryParse(values[key] ?? '');

    final fMin = readDouble('slider.fNumberMin');
    final fMax = readDouble('slider.fNumberMax');
    final eMin = readDouble('slider.exposureMin');
    final eMax = readDouble('slider.exposureMax');
    final iMin = readInt('slider.isoMin');
    final iMax = readInt('slider.isoMax');

    if (fMin == null ||
        fMax == null ||
        eMin == null ||
        eMax == null ||
        iMin == null ||
        iMax == null) {
      return null;
    }
    final bounds = SliderBounds(
      fNumberMin: fMin,
      fNumberMax: fMax,
      exposureMin: eMin,
      exposureMax: eMax,
      isoMin: iMin,
      isoMax: iMax,
    );
    return bounds.isValid ? bounds : null;
  }

  /// 保存滑条极值；传入 null 表示恢复为"按实际数据范围"。
  Future<void> saveSliderBounds(SliderBounds? bounds) async {
    if (bounds != null && !bounds.isValid) {
      throw ArgumentError('滑块极值必须满足最大值大于最小值');
    }
    final batch = _database.batch();
    batch.delete('settings', where: "key LIKE 'slider.%'");
    if (bounds != null) {
      final entries = <String, String>{
        'slider.fNumberMin': '${bounds.fNumberMin}',
        'slider.fNumberMax': '${bounds.fNumberMax}',
        'slider.exposureMin': '${bounds.exposureMin}',
        'slider.exposureMax': '${bounds.exposureMax}',
        'slider.isoMin': '${bounds.isoMin}',
        'slider.isoMax': '${bounds.isoMax}',
      };
      for (final entry in entries.entries) {
        batch.insert('settings', {
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    await batch.commit(noResult: true);
  }

  /// 列出 [scope] 下的直接子文件夹；[scope] 为 null 时返回全部索引根目录。
  Future<List<FolderSummary>> listSubFolders({
    required String? scope,
    required List<String> roots,
  }) async {
    final args = <Object?>[];
    final where = scope == null
        ? 'dir_path IS NOT NULL'
        : _scopeCondition(scope, args);
    final rows = await _database.rawQuery(
      'SELECT dir_path AS d, COUNT(*) AS c FROM photos WHERE $where GROUP BY dir_path',
      args,
    );

    final directCounts = <String, int>{};
    for (final row in rows) {
      final dir = row['d'] as String?;
      if (dir == null || dir.isEmpty) continue;
      directCounts[dir] = (row['c'] as int?) ?? 0;
    }

    // 1. 还原目录树（包含自身没有照片、只有子目录的中间层级）。
    final nodes = buildDirectoryTree(directCounts, scope: scope, roots: roots);
    final topLevel = scope == null
        ? roots.where(nodes.containsKey).toList()
        : (nodes[scope]?.children.toList() ?? const <String>[]);
    if (topLevel.isEmpty) return const [];

    // 2. 为每个子文件夹挑选封面来源目录（优先自身，其次第一个有照片的后代）。
    final coverSource = <String, String>{};
    for (final child in topLevel) {
      final source = coverDirectoryOf(child, nodes);
      if (source != null) coverSource[child] = source;
    }
    final covers = await _loadCovers(coverSource.values.toSet());

    // 3. 汇总输出。
    return [
      for (final child in topLevel)
        FolderSummary(
          path: child,
          name: displayFolderName(child),
          photoCount: folderTreeCountOf(child, nodes),
          subFolderCount: nodes[child]?.children.length ?? 0,
          cover: covers[coverSource[child]],
        ),
    ];
  }

  /// 逐张取封面：每个目录取 id 最小的那条含缩略图的记录。
  Future<Map<String, Uint8List>> _loadCovers(Set<String> dirs) async {
    if (dirs.isEmpty) return const {};
    final result = <String, Uint8List>{};
    final list = dirs.toList();
    const chunkSize = 400;
    for (var i = 0; i < list.length; i += chunkSize) {
      final chunk = list.sublist(i, _min(i + chunkSize, list.length));
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _database.rawQuery(
        'SELECT dir_path, MIN(id) AS mid, thumbnail FROM photos '
        'WHERE dir_path IN ($placeholders) AND thumbnail IS NOT NULL '
        'GROUP BY dir_path',
        chunk,
      );
      for (final row in rows) {
        final dir = row['dir_path'] as String?;
        final thumb = row['thumbnail'] as Uint8List?;
        if (dir != null && thumb != null) result[dir] = thumb;
      }
    }
    return result;
  }

  Future<Map<String, List<int>>> signaturesUnder(String folderPath) async {
    final rows = await _database.query(
      'photos',
      columns: ['path', 'file_size', 'file_modified'],
      where: 'folder_path = ?',
      whereArgs: [folderPath],
    );
    return {
      for (final r in rows)
        r['path'] as String: [
          r['file_size'] as int? ?? 0,
          r['file_modified'] as int? ?? 0,
        ],
    };
  }

  // ---------------------------------------------------------------- 写入

  Future<void> upsertPhotos(List<Photo> photos) async {
    if (photos.isEmpty) return;
    final batch = _database.batch();
    for (final photo in photos) {
      batch.insert(
        'photos',
        photo.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deletePhotosByPaths(Iterable<String> paths) async {
    final list = paths.toList();
    if (list.isEmpty) return;
    const chunkSize = 500;
    for (var i = 0; i < list.length; i += chunkSize) {
      final chunk = list.sublist(i, _min(i + chunkSize, list.length));
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _database.delete(
        'photos',
        where: 'path IN ($placeholders)',
        whereArgs: chunk,
      );
    }
  }

  Future<void> clearAll() async {
    await _database.delete('photos');
    await _database.delete('folders');
    await _database.execute('VACUUM');
  }

  // ---------------------------------------------------------------- 导出 / 导入

  /// 把当前数据库完整导出为单个文件（含缩略图与 EXIF）。
  Future<void> exportTo(String targetPath) async {
    final normalized = p.normalize(targetPath);
    final target = File(normalized);
    if (await target.exists()) {
      await target.delete();
    }
    // VACUUM INTO 需要目标文件不存在。
    final escaped = normalized.replaceAll("'", "''");
    await _database.execute("VACUUM INTO '$escaped'");
  }

  /// 校验并导入数据库文件，随后重新打开数据库。
  Future<void> importFrom(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw Exception('文件不存在：$sourcePath');
    }
    await _validate(sourcePath);

    final currentPath = _dbPath!;
    final current = File(currentPath);
    final backup = File('$currentPath.bak');

    // 先关闭连接，再把现有数据库改名备份，导入失败时可以回滚。
    await close();
    try {
      if (await backup.exists()) {
        await backup.delete();
      }
      if (await current.exists()) {
        await current.rename(backup.path);
      }
      await _removeSideFiles(currentPath);
      await source.copy(currentPath);
      // 源文件若为 WAL 模式，一并复制附属文件，避免数据丢失。
      for (final suffix in ['-wal', '-shm']) {
        final side = File('$sourcePath$suffix');
        if (await side.exists()) {
          await side.copy('$currentPath$suffix');
        }
      }
      _db = await _open(currentPath);
      if (await backup.exists()) {
        await backup.delete();
      }
    } catch (e) {
      await _removeSideFiles(currentPath);
      if (await backup.exists()) {
        await backup.rename(currentPath);
      }
      _db = await _open(currentPath);
      throw Exception('导入失败，已恢复原有数据库：$e');
    }
  }

  Future<void> _removeSideFiles(String path) async {
    for (final suffix in ['-wal', '-shm']) {
      final side = File('$path$suffix');
      if (await side.exists()) {
        await side.delete();
      }
    }
  }

  Future<void> _validate(String path) async {
    Database? probe;
    try {
      probe = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final rows = await probe.query(
        'sqlite_master',
        columns: ['name'],
        where: 'type = ? AND name = ?',
        whereArgs: ['table', 'photos'],
      );
      if (rows.isEmpty) {
        throw Exception('所选文件不是本软件导出的数据库（缺少 photos 表）');
      }
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('无法读取数据库文件：$e');
    } finally {
      await probe?.close();
    }
  }
}

/// 目录树节点，用于把"目录 → 直接照片数"还原成层级结构。
class FolderTreeNode {
  FolderTreeNode(this.path);

  final String path;

  /// 直接位于该目录下的照片数量。
  int directCount = 0;

  /// 直接子目录（保持插入顺序并去重）。
  final Set<String> children = <String>{};
}

/// 根据"目录 → 直接照片数"映射还原目录树。
///
/// 会自动补齐自身没有照片、只作为路径中转的中间层级。
/// [scope] 非空时只还原该目录以下的层级；[scope] 为空时以 [roots] 作为顶层边界。
Map<String, FolderTreeNode> buildDirectoryTree(
  Map<String, int> directCounts, {
  required String? scope,
  required List<String> roots,
}) {
  final nodes = <String, FolderTreeNode>{};
  FolderTreeNode ensure(String dir) =>
      nodes.putIfAbsent(dir, () => FolderTreeNode(dir));
  final rootSet = roots.toSet();

  for (final entry in directCounts.entries) {
    final dir = entry.key;
    if (dir.isEmpty) continue;
    ensure(dir).directCount += entry.value;

    var current = dir;
    while (true) {
      final parent = p.dirname(current);
      if (parent == current) break; // 已到盘符根
      if (scope != null && !_isInside(parent, scope)) break;
      ensure(parent).children.add(current);
      if (scope != null && parent == scope) break;
      if (scope == null && rootSet.contains(parent)) break;
      current = parent;
    }
  }
  return nodes;
}

/// 统计某目录（含全部子目录）下的照片总数。
int folderTreeCountOf(String dir, Map<String, FolderTreeNode> nodes) {
  final node = nodes[dir];
  if (node == null) return 0;
  var sum = node.directCount;
  for (final child in node.children) {
    sum += folderTreeCountOf(child, nodes);
  }
  return sum;
}

/// 找出该目录下第一个可作为封面的目录：优先自身，其次第一个含照片的后代。
String? coverDirectoryOf(String dir, Map<String, FolderTreeNode> nodes) {
  final node = nodes[dir];
  if (node == null) return null;
  if (node.directCount > 0) return dir;
  for (final child in node.children) {
    final found = coverDirectoryOf(child, nodes);
    if (found != null) return found;
  }
  return null;
}

/// 取目录的显示名（最后一级），盘符根目录则原样返回。
String displayFolderName(String path) {
  final name = p.basename(path);
  return name.isEmpty ? path : name;
}

int _min(int a, int b) => a < b ? a : b;

bool _isInside(String dir, String scope) {
  if (dir == scope) return true;
  final prefix = scope.endsWith(p.separator) ? scope : '$scope${p.separator}';
  return dir.startsWith(prefix);
}
