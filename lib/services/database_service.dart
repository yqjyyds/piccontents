import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/app_settings.dart';
import '../models/photo.dart';
import '../models/photo_filter.dart';
import '../utils/index_paths.dart';
import 'diagnostics.dart';
import 'volume_identity.dart';

/// 一份索引库（一块硬盘的索引），对应 `libraries` 表的一行。
///
/// `archivedAt` 为空表示当前接入并作为活动索引；非空表示已归档。
class IndexLibrary {
  const IndexLibrary({
    required this.id,
    required this.path,
    this.displayName,
    this.volumeGuid,
    this.volumeSerial,
    this.volumeLabel,
    this.lastScanAt,
    this.archivedAt,
  });

  factory IndexLibrary.fromMap(Map<String, Object?> row) {
    return IndexLibrary(
      id: row['id'] as int,
      path: row['path'] as String,
      displayName: row['display_name'] as String?,
      volumeGuid: row['volume_guid'] as String?,
      volumeSerial: row['volume_serial'] as int?,
      volumeLabel: row['volume_label'] as String?,
      lastScanAt: row['last_scan_at'] as int?,
      archivedAt: row['archived_at'] as int?,
    );
  }

  final int id;
  final String path;
  final String? displayName;
  final String? volumeGuid;
  final int? volumeSerial;
  final String? volumeLabel;
  final int? lastScanAt;
  final int? archivedAt;

  bool get isArchived => archivedAt != null;

  bool get isKnown => volumeGuid != null || volumeSerial != null;

  /// 用于界面区分不同硬盘的显示名。
  String get label {
    final volume = volumeLabel?.trim() ?? '';
    if (volume.isNotEmpty) return volume;
    final display = displayName?.trim() ?? '';
    if (display.isNotEmpty) return display;
    return path;
  }

  /// 是否与当前接在盘符上的卷是同一个。
  bool matches(VolumeIdentity other) {
    if (volumeGuid != null && other.guid != null) {
      return volumeGuid == other.guid;
    }
    if (volumeSerial != null && other.serial != null) {
      return volumeSerial == other.serial;
    }
    return false;
  }
}

/// 一份被归档的索引库（某块硬盘的索引，当前不在这台机器上）。
class ArchivedLibrary {
  const ArchivedLibrary({
    required this.id,
    required this.path,
    this.displayName,
    this.volumeGuid,
    this.volumeSerial,
    this.volumeLabel,
  });

  factory ArchivedLibrary.fromMap(Map<String, Object?> row) {
    return ArchivedLibrary(
      id: row['id'] as int,
      path: row['path'] as String,
      displayName: row['display_name'] as String?,
      volumeGuid: row['volume_guid'] as String?,
      volumeSerial: row['volume_serial'] as int?,
      volumeLabel: row['volume_label'] as String?,
    );
  }

  final int id;
  final String path;
  final String? displayName;
  final String? volumeGuid;
  final int? volumeSerial;
  final String? volumeLabel;

  bool matches(VolumeIdentity other) {
    if (volumeGuid != null && other.guid != null) {
      return volumeGuid == other.guid;
    }
    if (volumeSerial != null && other.serial != null) {
      return volumeSerial == other.serial;
    }
    return false;
  }
}

/// 侧栏展示用的归档库摘要。
class ArchivedLibrarySummary {
  const ArchivedLibrarySummary({
    required this.id,
    required this.path,
    required this.photoCount,
    required this.archivedAt,
    this.displayName,
    this.volumeLabel,
  });

  final int id;
  final String path;
  final int photoCount;
  final int archivedAt;
  final String? displayName;
  final String? volumeLabel;

  /// 优先用卷标（换盘时最容易辨认），其次自定义名，最后用路径。
  /// 自定义名是归档时从活动根目录复制来的，多块盘可能同名，不适合做主标题。
  String get name {
    final label = volumeLabel?.trim() ?? '';
    if (label.isNotEmpty) return label;
    final display = displayName?.trim() ?? '';
    if (display.isNotEmpty) return display;
    return path;
  }

  DateTime get archivedTime => DateTime.fromMillisecondsSinceEpoch(archivedAt);
}

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

  static const int _schemaVersion = 6;
  static const String _dbFileName = 'piccontents_library.db';

  /// 记录数据库保存位置的小配置文件，必须放在数据库之外，
  /// 否则「数据在哪」这件事本身也要先知道数据在哪才能读到。
  static const String _locationFileName = 'index_location.json';

  Database? _db;
  String? _dbPath;

  /// v6 迁移后需要回收旧表留下的空闲页（VACUUM 不能放在升级事务里）。
  bool _vacuumAfterOpen = false;

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

    final appDataDir = await _appDataDataDir();
    final localDataDir = _localDataDir();
    final portableDir = _portableDataDir();
    final preferredDir = await readPreferredDataDir();

    // 用户指定过位置就优先用它；其次便携目录里已经有库时优先使用
    // （说明之前因为主目录不可写而迁移过，继续用它才能保证多次启动
    // 看到的是同一份数据）；最后才按常规目录依次尝试。
    final candidates = <String>[
      if (preferredDir != null && preferredDir.isNotEmpty) preferredDir,
      if (portableDir != null &&
          await File(p.join(portableDir, _dbFileName)).exists())
        portableDir,
      ?appDataDir,
      ?localDataDir,
      ?portableDir,
    ];

    Object? lastError;
    for (final dir in candidates.toSet()) {
      Database? db;
      try {
        await Directory(dir).create(recursive: true);
        final dbPath = p.join(dir, _dbFileName);

        // 首次落到新目录时，把已有的库搬过来，避免看不到原来的索引。
        if (!await File(dbPath).exists()) {
          final source = await _findExistingDb(exclude: dbPath);
          if (source != null) {
            debugPrint('[Database] 迁移数据库 $source → $dbPath');
            await File(source).copy(dbPath);
            // 源库若处于 WAL 模式，附带文件也要一起复制。
            for (final suffix in ['-wal', '-shm']) {
              final side = File('$source$suffix');
              if (await side.exists()) {
                await side.copy('$dbPath$suffix');
              }
            }
          }
        }

        db = await _open(dbPath);
        // 目录不可写时 SQLite 仍能打开库，但第一次写入才报 READONLY，
        // 所以这里主动探测一次，失败就换下一个目录。
        await _verifyWritable(db);

        _db = db;
        _dbPath = dbPath;
        debugPrint('[Database] 使用数据目录：$dbPath');
        return;
      } catch (e, stack) {
        lastError = e;
        debugPrint('[Database] 数据目录不可用：$dir → $e');
        await db?.close();
        await writeDiagnosticLog('DatabaseInit', e, stack: stack);
      }
    }

    throw Exception('找不到可写的数据目录：$lastError');
  }

  /// 写入探测：目录不可写时会在这里抛出 SQLITE_READONLY。
  Future<void> _verifyWritable(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS __write_probe (x INTEGER)');
    await db.execute('DROP TABLE IF EXISTS __write_probe');
  }

  Future<String?> _appDataDataDir() async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      return p.join(supportDir.path, 'piccontents');
    } catch (e, stack) {
      await writeDiagnosticLog('AppDataDir', e, stack: stack);
      return null;
    }
  }

  /// 便携模式：数据放在 exe 同目录，适合主目录被安全软件限制的情况。
  String? _portableDataDir() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return p.join(exeDir, 'piccontents_data');
    } catch (_) {
      return null;
    }
  }

  /// 本机数据目录，比 exe 同目录稳定（不会因重新构建而被清掉）。
  String? _localDataDir() {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return null;
    return p.join(local, 'PicContents', 'piccontents');
  }

  Future<String?> _findExistingDb({required String exclude}) async {
    for (final dir in [
      await _appDataDataDir(),
      _localDataDir(),
      _portableDataDir(),
    ]) {
      if (dir == null) continue;
      final path = p.join(dir, _dbFileName);
      if (path != exclude && await File(path).exists()) {
        return path;
      }
    }
    return null;
  }

  // ------------------------------------------------------------ 数据位置设置

  /// 可以存放位置配置文件的目录，按稳定性排序。
  Future<List<String>> _locationConfigDirs() async {
    return [?await _appDataDataDir(), ?_localDataDir(), ?_portableDataDir()];
  }

  /// 读取用户指定的数据库目录；没设置过或配置不可读时返回 null。
  Future<String?> readPreferredDataDir() async {
    for (final dir in await _locationConfigDirs()) {
      try {
        final file = File(p.join(dir, _locationFileName));
        if (!await file.exists()) continue;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) continue;
        final value = decoded['dir'];
        if (value is String && value.trim().isNotEmpty) {
          return p.normalize(value.trim());
        }
      } catch (_) {
        // 配置损坏时当作没设置过，继续按默认目录查找。
      }
    }
    return null;
  }

  Future<void> _writePreferredDataDir(String dir) async {
    Object? lastError;
    for (final candidate in await _locationConfigDirs()) {
      try {
        await Directory(candidate).create(recursive: true);
        final file = File(p.join(candidate, _locationFileName));
        await file.writeAsString(jsonEncode({'dir': dir}), flush: true);
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('无法保存数据位置设置：$lastError');
  }

  /// 把数据库迁移到 [targetDir] 并记为默认位置。
  ///
  /// 先复制/移动文件再打开校验，成功后才会清理旧文件并写入配置；
  /// 任一步失败都会尽量回滚到原位置，避免索引「看起来还在但打不开」。
  Future<void> relocateTo(String targetDir) async {
    final currentPath = _dbPath;
    final currentDb = _db;
    if (currentPath == null || currentDb == null) {
      throw StateError('数据库尚未初始化');
    }

    final target = normalizeIndexRootPath(targetDir);
    if (p.equals(p.dirname(currentPath), target)) {
      await _writePreferredDataDir(target);
      return;
    }
    final targetPath = p.join(target, _dbFileName);

    // 先把 WAL 里的内容合并回主文件，迁移时只需要保证一个文件完整。
    try {
      await currentDb.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {}
    await close();

    final sameVolume =
        p.rootPrefix(currentPath).toLowerCase() ==
        p.rootPrefix(targetPath).toLowerCase();
    var moved = false;
    var copied = false;
    String? backupPath;

    try {
      await Directory(target).create(recursive: true);
      final probe = File(p.join(target, '.piccontents_write_probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();

      // 目标位置已有库：改名备份，避免直接覆盖。
      if (await File(targetPath).exists()) {
        backupPath = '$targetPath.bak_${DateTime.now().millisecondsSinceEpoch}';
        await File(targetPath).rename(backupPath);
        await _removeSideFiles(targetPath);
      }

      if (sameVolume) {
        await File(currentPath).rename(targetPath);
        // 同盘改名不会带走 WAL 附属文件，主文件已 checkpoint，直接清掉旧的。
        await _removeSideFiles(currentPath);
        moved = true;
      } else {
        await File(currentPath).copy(targetPath);
        copied = true;
      }

      final db = await _open(targetPath);
      _db = db;
      await _verifyWritable(db);
      _dbPath = targetPath;

      // 先落配置再清理旧文件：配置写不进去时可以原样回滚。
      await _writePreferredDataDir(target);
      if (copied) {
        try {
          await File(currentPath).delete();
          await _removeSideFiles(currentPath);
        } catch (e) {
          // 旧文件残留不影响使用，不因此判定迁移失败。
          debugPrint('[Database] 清理旧数据库失败：$e');
        }
      }
      debugPrint('[Database] 数据已迁移到：$targetPath');
    } catch (e) {
      // 回滚：把数据库恢复到原来的位置，保证程序仍然可用。
      await _db?.close();
      _db = null;
      var restored = false;
      try {
        if (moved && await File(targetPath).exists()) {
          await File(targetPath).rename(currentPath);
        }
        if (copied && await File(targetPath).exists()) {
          await File(targetPath).delete();
        }
        await _removeSideFiles(targetPath);
        if (backupPath != null && await File(backupPath).exists()) {
          await File(backupPath).rename(targetPath);
        }
        restored = await File(currentPath).exists();
      } catch (_) {}
      if (!restored) {
        throw Exception(
          '迁移数据库失败，且原数据库文件已不在原位。\n'
          '原位置：$currentPath\n新位置：$targetPath\n原因：$e',
        );
      }
      _db = await _open(currentPath);
      _dbPath = currentPath;
      throw Exception('迁移数据库失败，已保留原位置：$e');
    }
  }

  Future<Database> _open(String path) async {
    await _backupBeforeMigration(path);
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          // WAL + NORMAL：索引库是可重建的，用一点掉电安全换批量写入速度。
          // 网络盘等不支持 WAL 的场景会失败，忽略即可。
          try {
            await db.execute('PRAGMA journal_mode = WAL');
            await db.execute('PRAGMA synchronous = NORMAL');
          } catch (_) {}
        },
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
          if (oldVersion < 4) {
            // v4：索引目录支持自定义显示名（只改显示，不动磁盘文件夹）。
            await db.execute(
              'ALTER TABLE folders ADD COLUMN display_name TEXT',
            );
          }
          if (oldVersion < 5) {
            // v5：记录根目录所在卷的身份，用于识别"同一盘符换了硬盘"，
            // 并支持把不在这台机器上的硬盘索引归档保存。
            await db.execute('ALTER TABLE folders ADD COLUMN volume_guid TEXT');
            await db.execute(
              'ALTER TABLE folders ADD COLUMN volume_serial INTEGER',
            );
            await db.execute(
              'ALTER TABLE folders ADD COLUMN volume_label TEXT',
            );
            await _createArchiveTables(db);
          }
          if (oldVersion < 6) {
            await migrateToV6(db);
            _vacuumAfterOpen = true;
          }
        },
      ),
    );

    if (_vacuumAfterOpen) {
      _vacuumAfterOpen = false;
      try {
        await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
        await db.execute('VACUUM');
        debugPrint('[Database] v6 迁移后已回收空闲页');
      } catch (e) {
        debugPrint('[Database] 迁移后 VACUUM 失败（不影响使用）：$e');
      }
    }
    return db;
  }

  /// v5 及更早版本升级前先备份，迁移失败时还能拿回原库。
  Future<void> _backupBeforeMigration(String path) async {
    try {
      if (!await File(path).exists()) return;
      final backup = '$path.bak_v6';
      if (await File(backup).exists()) return;

      final probe = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      var version = 0;
      try {
        final rows = await probe.rawQuery('PRAGMA user_version');
        if (rows.isNotEmpty) {
          version = (rows.first.values.first as num?)?.toInt() ?? 0;
        }
      } finally {
        await probe.close();
      }
      if (version == 0 || version >= _schemaVersion) return;

      await File(path).copy(backup);
      for (final suffix in ['-wal', '-shm']) {
        final side = File('$path$suffix');
        if (await side.exists()) {
          await side.copy('$backup$suffix');
        }
      }
      debugPrint('[Database] v$version 升级前已备份：$backup');
    } catch (e, stack) {
      await writeDiagnosticLog('MigrationBackup', e, stack: stack);
    }
  }

  /// v6：把"活动表 + 归档表"合并成统一的 `photos`（按 library_id 区分硬盘），
  /// 并把缩略图拆到 `photo_thumbnails`，避免筛选排序时扫到 BLOB。
  @visibleForTesting
  static Future<void> migrateToV6(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    debugPrint('[Database] 开始 v6 迁移');

    await db.execute('DROP TABLE IF EXISTS libraries_v6');
    await db.execute('DROP TABLE IF EXISTS photos_v6');
    await db.execute('DROP TABLE IF EXISTS photo_thumbnails_v6');

    await db.execute('''
      CREATE TABLE libraries_v6 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL,
        display_name TEXT,
        volume_guid TEXT,
        volume_serial INTEGER,
        volume_label TEXT,
        added_at INTEGER NOT NULL,
        last_scan_at INTEGER,
        archived_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE photos_v6 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        library_id INTEGER NOT NULL,
        path TEXT NOT NULL,
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
        indexed_at INTEGER NOT NULL DEFAULT 0,
        UNIQUE(library_id, path)
      )
    ''');
    await db.execute('''
      CREATE TABLE photo_thumbnails_v6 (
        photo_id INTEGER PRIMARY KEY,
        bytes BLOB NOT NULL
      )
    ''');

    // 活动根目录 → 活动库
    await db.execute('''
      INSERT INTO libraries_v6 (
        path, display_name, volume_guid, volume_serial, volume_label,
        added_at, last_scan_at, archived_at)
      SELECT path, display_name, volume_guid, volume_serial, volume_label,
        added_at, last_scan_at, NULL
      FROM folders
    ''');
    // 孤立照片（没有对应根目录）也补一个活动库，避免迁移时丢失。
    await db.execute(
      '''
      INSERT INTO libraries_v6 (path, added_at)
      SELECT DISTINCT folder_path, ?
      FROM photos
      WHERE folder_path NOT IN (
        SELECT path FROM libraries_v6 WHERE archived_at IS NULL)
    ''',
      [now],
    );

    // 旧归档库 → 新归档库，记录 id 映射。
    final archivedRows = await db.query('libraries', orderBy: 'id ASC');
    final libraryMap = <int, int>{};
    for (final row in archivedRows) {
      final oldId = row['id'] as int;
      final archivedAt = (row['archived_at'] as int?) ?? now;
      final newId = await db.insert('libraries_v6', {
        'path': row['path'],
        'display_name': row['display_name'],
        'volume_guid': row['volume_guid'],
        'volume_serial': row['volume_serial'],
        'volume_label': row['volume_label'],
        'added_at': archivedAt,
        'last_scan_at': null,
        'archived_at': archivedAt,
      });
      libraryMap[oldId] = newId;
    }
    // 归档照片引用了不存在的库时，兜底建一个归档库。
    final referenced = await db.rawQuery(
      'SELECT DISTINCT library_id AS id FROM archived_photos',
    );
    for (final row in referenced) {
      final oldId = row['id'] as int;
      if (libraryMap.containsKey(oldId)) continue;
      final folderRows = await db.query(
        'archived_photos',
        columns: ['folder_path'],
        where: 'library_id = ?',
        whereArgs: [oldId],
        limit: 1,
      );
      final path = folderRows.isEmpty
          ? '未知硬盘\\'
          : (folderRows.first['folder_path'] as String? ?? '未知硬盘\\');
      final newId = await db.insert('libraries_v6', {
        'path': path,
        'added_at': now,
        'archived_at': now,
      });
      libraryMap[oldId] = newId;
    }

    const photoColumns =
        'path, file_name, folder_path, dir_path, file_size, file_modified, '
        'width, height, capture_time, camera_make, camera_model, lens_model, '
        'f_number, exposure_time, iso, focal_length, focal_length_35mm, '
        'exposure_bias, orientation, gps_lat, gps_lon, gps_altitude, '
        'indexed_at';

    await db.execute('''
      INSERT INTO photos_v6 (library_id, $photoColumns)
      SELECT (
        SELECT l.id FROM libraries_v6 l
        WHERE l.path = p.folder_path AND l.archived_at IS NULL
        LIMIT 1
      ), p.$photoColumns
      FROM photos p
    ''');
    for (final entry in libraryMap.entries) {
      await db.execute(
        '''
        INSERT INTO photos_v6 (library_id, $photoColumns)
        SELECT ?, $photoColumns FROM archived_photos WHERE library_id = ?
      ''',
        [entry.value, entry.key],
      );
    }

    // 缩略图搬到独立表。
    await db.execute('''
      INSERT INTO photo_thumbnails_v6 (photo_id, bytes)
      SELECT np.id, p.thumbnail
      FROM photos p
      JOIN libraries_v6 l
        ON l.path = p.folder_path AND l.archived_at IS NULL
      JOIN photos_v6 np ON np.library_id = l.id AND np.path = p.path
      WHERE p.thumbnail IS NOT NULL
    ''');
    for (final entry in libraryMap.entries) {
      await db.execute(
        '''
        INSERT INTO photo_thumbnails_v6 (photo_id, bytes)
        SELECT np.id, ap.thumbnail
        FROM archived_photos ap
        JOIN photos_v6 np
          ON np.library_id = ? AND np.path = ap.path
        WHERE ap.library_id = ? AND ap.thumbnail IS NOT NULL
      ''',
        [entry.value, entry.key],
      );
    }

    final expectedPhotos = await _scalar(
      db,
      'SELECT (SELECT COUNT(*) FROM photos) + '
      '(SELECT COUNT(*) FROM archived_photos)',
    );
    final actualPhotos = await _scalar(db, 'SELECT COUNT(*) FROM photos_v6');
    if (expectedPhotos != actualPhotos) {
      throw Exception('v6 迁移校验失败：照片数量 $expectedPhotos → $actualPhotos');
    }
    final expectedThumbs = await _scalar(
      db,
      'SELECT (SELECT COUNT(*) FROM photos WHERE thumbnail IS NOT NULL) + '
      '(SELECT COUNT(*) FROM archived_photos WHERE thumbnail IS NOT NULL)',
    );
    final actualThumbs = await _scalar(
      db,
      'SELECT COUNT(*) FROM photo_thumbnails_v6',
    );
    if (expectedThumbs != actualThumbs) {
      throw Exception('v6 迁移校验失败：缩略图数量 $expectedThumbs → $actualThumbs');
    }

    await db.execute('DROP TABLE archived_photos');
    await db.execute('DROP TABLE libraries');
    await db.execute('DROP TABLE folders');
    await db.execute('DROP TABLE photos');
    await db.execute('ALTER TABLE libraries_v6 RENAME TO libraries');
    await db.execute('ALTER TABLE photos_v6 RENAME TO photos');
    await db.execute(
      'ALTER TABLE photo_thumbnails_v6 RENAME TO photo_thumbnails',
    );
    await _createV6Indexes(db);
    debugPrint('[Database] v6 迁移完成：$actualPhotos 张照片');
  }

  static Future<int> _scalar(Database db, String sql) async {
    final rows = await db.rawQuery(sql);
    if (rows.isEmpty) return 0;
    return (rows.first.values.first as num?)?.toInt() ?? 0;
  }

  static Future<void> _createV6Indexes(Database db) async {
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_libraries_active_path '
      'ON libraries(path) WHERE archived_at IS NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_libraries_archived '
      'ON libraries(archived_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_photos_library_capture '
      'ON photos(library_id, capture_time)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_photos_library_dir '
      'ON photos(library_id, dir_path)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_photos_library_folder '
      'ON photos(library_id, folder_path)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_photos_camera '
      'ON photos(camera_model)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_photos_lens ON photos(lens_model)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_photos_iso ON photos(iso)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_photos_fnumber ON photos(f_number)',
    );
  }

  Future<void> _createArchiveTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS libraries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL,
        display_name TEXT,
        volume_guid TEXT,
        volume_serial INTEGER,
        volume_label TEXT,
        archived_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS archived_photos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        library_id INTEGER NOT NULL,
        path TEXT NOT NULL,
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
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_archived_photos_library '
      'ON archived_photos(library_id)',
    );
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE libraries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL,
        display_name TEXT,
        volume_guid TEXT,
        volume_serial INTEGER,
        volume_label TEXT,
        added_at INTEGER NOT NULL,
        last_scan_at INTEGER,
        archived_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE photos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        library_id INTEGER NOT NULL,
        path TEXT NOT NULL,
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
        indexed_at INTEGER NOT NULL DEFAULT 0,
        UNIQUE(library_id, path)
      )
    ''');
    await db.execute('''
      CREATE TABLE photo_thumbnails (
        photo_id INTEGER PRIMARY KEY,
        bytes BLOB NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await _createV6Indexes(db);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ---------------------------------------------------------------- 索引库

  /// 当前接入的索引库（archived_at 为空）。
  Future<List<IndexLibrary>> activeLibraries() async {
    final rows = await _database.query(
      'libraries',
      where: 'archived_at IS NULL',
      orderBy: 'added_at ASC',
    );
    return rows.map(IndexLibrary.fromMap).toList();
  }

  /// 活动库的路径 → id，供查询时限定所属硬盘。
  Future<Map<String, int>> activeLibraryIds() async {
    final rows = await _database.query(
      'libraries',
      columns: ['id', 'path'],
      where: 'archived_at IS NULL',
    );
    return {for (final row in rows) row['path'] as String: row['id'] as int};
  }

  Future<IndexLibrary?> activeLibrary(String path) async {
    final rows = await _database.query(
      'libraries',
      where: 'path = ? AND archived_at IS NULL',
      whereArgs: [normalizeIndexRootPath(path)],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return IndexLibrary.fromMap(rows.first);
  }

  Future<List<String>> getFolders() async {
    final libraries = await activeLibraries();
    return [for (final library in libraries) library.path];
  }

  Future<void> addFolder(String path) async {
    await _database.rawInsert(
      'INSERT OR IGNORE INTO libraries (path, added_at) VALUES (?, ?)',
      [normalizeIndexRootPath(path), DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// 索引目录的自定义显示名；只影响界面，不改动磁盘上的文件夹。
  Future<Map<String, String>> folderDisplayNames() async {
    final rows = await _database.query(
      'libraries',
      columns: ['path', 'display_name'],
      where: 'archived_at IS NULL',
    );
    final names = <String, String>{};
    for (final row in rows) {
      final path = row['path'] as String?;
      final name = row['display_name'] as String?;
      if (path != null && name != null && name.trim().isNotEmpty) {
        names[path] = name.trim();
      }
    }
    return names;
  }

  /// 设置索引目录的显示名；传空字符串表示恢复成真实文件夹名。
  Future<void> setFolderDisplayName(String path, String name) async {
    final trimmed = name.trim();
    await _database.update(
      'libraries',
      {'display_name': trimmed.isEmpty ? null : trimmed},
      where: 'path = ? AND archived_at IS NULL',
      whereArgs: [normalizeIndexRootPath(path)],
    );
  }

  // -------------------------------------------------------- 卷身份与归档

  /// `photos` 表除主键和缩略图外的全部列。
  static const List<String> _photoColumns = [
    'library_id',
    'path',
    'file_name',
    'folder_path',
    'dir_path',
    'file_size',
    'file_modified',
    'width',
    'height',
    'capture_time',
    'camera_make',
    'camera_model',
    'lens_model',
    'f_number',
    'exposure_time',
    'iso',
    'focal_length',
    'focal_length_35mm',
    'exposure_bias',
    'orientation',
    'gps_lat',
    'gps_lon',
    'gps_altitude',
    'indexed_at',
  ];

  /// 读取当前活动库的卷信息；路径没有活动库时返回 null。
  Future<IndexLibrary?> folderVolume(String path) => activeLibrary(path);

  /// 把当前接在该盘符上的卷身份记到活动库上。
  Future<void> setFolderVolume(String path, VolumeIdentity identity) async {
    await _database.update(
      'libraries',
      {
        'volume_guid': identity.guid,
        'volume_serial': identity.serial,
        'volume_label': identity.label,
      },
      where: 'path = ? AND archived_at IS NULL',
      whereArgs: [normalizeIndexRootPath(path)],
    );
  }

  /// 查找该路径下、属于 [identity] 的归档索引。
  Future<ArchivedLibrary?> findArchivedLibrary({
    required String path,
    required VolumeIdentity identity,
  }) async {
    final rows = await _database.query(
      'libraries',
      where: 'path = ? AND archived_at IS NOT NULL',
      whereArgs: [normalizeIndexRootPath(path)],
      orderBy: 'archived_at DESC',
    );
    for (final row in rows) {
      final library = ArchivedLibrary.fromMap(row);
      if (library.matches(identity)) return library;
    }
    return null;
  }

  /// 所有归档库（按归档时间倒序），带照片数量。
  Future<List<ArchivedLibrarySummary>> archivedLibraries() async {
    final rows = await _database.rawQuery(
      'SELECT l.id, l.path, l.display_name, l.volume_label, l.archived_at, '
      '(SELECT COUNT(*) FROM photos p WHERE p.library_id = l.id) '
      'AS photo_count '
      'FROM libraries l WHERE l.archived_at IS NOT NULL '
      'ORDER BY l.archived_at DESC',
    );
    return [
      for (final row in rows)
        ArchivedLibrarySummary(
          id: row['id'] as int,
          path: row['path'] as String,
          displayName: row['display_name'] as String?,
          volumeLabel: row['volume_label'] as String?,
          archivedAt: (row['archived_at'] as int?) ?? 0,
          photoCount: (row['photo_count'] as int?) ?? 0,
        ),
    ];
  }

  /// 按 id 读取索引库完整信息。
  Future<ArchivedLibrary?> libraryById(int id) async {
    final rows = await _database.query(
      'libraries',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ArchivedLibrary.fromMap(rows.first);
  }

  /// 删除一份归档索引（只删索引里的缩略图与元数据）。
  Future<void> deleteLibrary(int id) async {
    await _database.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM photo_thumbnails WHERE photo_id IN '
        '(SELECT id FROM photos WHERE library_id = ?)',
        [id],
      );
      await txn.delete('photos', where: 'library_id = ?', whereArgs: [id]);
      await txn.delete('libraries', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<int> archivedPhotoCount(int libraryId) async {
    final rows = await _database.rawQuery(
      'SELECT COUNT(*) AS c FROM photos WHERE library_id = ?',
      [libraryId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 把 [path] 的活动索引归档：只标记状态，照片原地保留。
  ///
  /// 返回索引库 id；该路径没有活动索引时返回 null。
  Future<int?> archiveFolder(String path) async {
    final library = await activeLibrary(path);
    if (library == null) return null;
    await _database.update(
      'libraries',
      {'archived_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [library.id],
    );
    return library.id;
  }

  /// 把归档索引恢复成活动索引。
  ///
  /// 同一路径上的其它活动库会先被归档，保证"一个盘符只有一个活动库"。
  Future<void> restoreLibrary(ArchivedLibrary library) async {
    await _database.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final actives = await txn.query(
        'libraries',
        columns: ['id'],
        where: 'path = ? AND archived_at IS NULL',
        whereArgs: [library.path],
      );
      for (final row in actives) {
        await txn.update(
          'libraries',
          {'archived_at': now},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
      await txn.update(
        'libraries',
        {'archived_at': null},
        where: 'id = ?',
        whereArgs: [library.id],
      );
    });
  }

  Future<void> markFolderScanned(String path) async {
    await _database.update(
      'libraries',
      {'last_scan_at': DateTime.now().millisecondsSinceEpoch},
      where: 'path = ? AND archived_at IS NULL',
      whereArgs: [normalizeIndexRootPath(path)],
    );
  }

  /// 移除根目录的同时删除它名下的所有索引记录。
  Future<void> removeFolder(String path) async {
    final library = await activeLibrary(path);
    if (library == null) return;
    await _database.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM photo_thumbnails WHERE photo_id IN '
        '(SELECT id FROM photos WHERE library_id = ?)',
        [library.id],
      );
      await txn.delete(
        'photos',
        where: 'library_id = ?',
        whereArgs: [library.id],
      );
      await txn.delete('libraries', where: 'id = ?', whereArgs: [library.id]);
    });
  }

  Future<Map<String, int>> folderCounts() async {
    final rows = await _database.rawQuery(
      'SELECT l.path AS path, COUNT(p.id) AS c '
      'FROM libraries l LEFT JOIN photos p ON p.library_id = l.id '
      'WHERE l.archived_at IS NULL GROUP BY l.id',
    );
    return {for (final r in rows) r['path'] as String: (r['c'] as int?) ?? 0};
  }

  /// 全部照片数量（包含归档库）。
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
    int? libraryId,
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
    final clause = _withLibrary(where, libraryId, args);
    final rows = await _database.rawQuery(
      'SELECT COUNT(*) AS c FROM photos$clause',
      args,
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<List<Photo>> queryPhotos({
    int? libraryId,
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
    final clause = _withLibrary(where, libraryId, args);
    // 只查元数据，缩略图按当前页的 id 单独取，避免筛选/排序触碰 BLOB。
    final rows = await _database.rawQuery(
      'SELECT p.*, ('
      '  SELECT COALESCE(NULLIF(l.volume_label, \'\'), '
      '    NULLIF(l.display_name, \'\'), l.path) '
      '  FROM libraries l WHERE l.id = p.library_id'
      ') AS library_label '
      'FROM photos p$clause ORDER BY ${sort.orderBy} LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    final ids = [
      for (final row in rows)
        if (row['id'] is int) row['id'] as int,
    ];
    final thumbnails = await _loadThumbnails(ids);
    return [
      for (final row in rows)
        Photo.fromMap({...row, 'thumbnail': thumbnails[row['id'] as int?]}),
    ];
  }

  /// 按 id 批量读取缩略图（当前页最多 120 条）。
  Future<Map<int, Uint8List>> _loadThumbnails(List<int> ids) async {
    if (ids.isEmpty) return const {};
    final result = <int, Uint8List>{};
    const chunkSize = 400;
    for (var i = 0; i < ids.length; i += chunkSize) {
      final chunk = ids.sublist(i, _min(i + chunkSize, ids.length));
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _database.rawQuery(
        'SELECT photo_id, bytes FROM photo_thumbnails '
        'WHERE photo_id IN ($placeholders)',
        chunk,
      );
      for (final row in rows) {
        final id = row['photo_id'] as int?;
        final bytes = row['bytes'] as Uint8List?;
        if (id != null && bytes != null) result[id] = bytes;
      }
    }
    return result;
  }

  /// 在现有 WHERE 后追加库过滤；[args] 按 SQL 中出现顺序追加。
  static String _withLibrary(String where, int? libraryId, List<Object?> args) {
    if (libraryId == null) return where;
    args.add(libraryId);
    return where.isEmpty
        ? ' WHERE library_id = ?'
        : '$where AND library_id = ?';
  }

  /// 读取库中已有的相机型号、镜头以及拍摄参数的取值范围。
  ///
  /// [libraryId] 为空表示全部库（"全部照片"）；指定时只看该硬盘。
  Future<FilterOptions> loadFilterOptions({int? libraryId}) async {
    final filter = libraryId == null ? '' : ' AND library_id = ?';
    final args = libraryId == null ? <Object?>[] : <Object?>[libraryId];
    final cameras = await _database.rawQuery(
      'SELECT DISTINCT camera_model AS v FROM photos '
      "WHERE camera_model IS NOT NULL AND camera_model <> ''$filter "
      'ORDER BY camera_model COLLATE NOCASE',
      args,
    );
    final lenses = await _database.rawQuery(
      'SELECT DISTINCT lens_model AS v FROM photos '
      "WHERE lens_model IS NOT NULL AND lens_model <> ''$filter "
      'ORDER BY lens_model COLLATE NOCASE',
      args,
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
      'FROM photos${libraryId == null ? '' : ' WHERE library_id = ?'}',
      args,
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
  ///
  /// [libraryId] 限定单个库（根目录/归档浏览）；[libraryIds] 限定一组库
  /// （"全部照片"的文件夹视图只统计当前接入的库）。
  Future<List<FolderSummary>> listSubFolders({
    int? libraryId,
    Set<int>? libraryIds,
    required String? scope,
    required List<String> roots,
  }) async {
    final args = <Object?>[];
    final clauses = <String>[];
    if (scope != null && scope.isNotEmpty) {
      clauses.add(_scopeCondition(scope, args));
    } else {
      clauses.add('dir_path IS NOT NULL');
    }
    if (libraryId != null) {
      clauses.add('library_id = ?');
      args.add(libraryId);
    } else if (libraryIds != null) {
      if (libraryIds.isEmpty) return const [];
      final placeholders = List.filled(libraryIds.length, '?').join(',');
      clauses.add('library_id IN ($placeholders)');
      args.addAll(libraryIds);
    }
    final rows = await _database.rawQuery(
      'SELECT dir_path AS d, COUNT(*) AS c FROM photos '
      'WHERE ${clauses.join(' AND ')} GROUP BY dir_path',
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
    final covers = await _loadCovers(
      coverSource.values.toSet(),
      libraryId: libraryId,
      libraryIds: libraryIds,
    );

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
  Future<Map<String, Uint8List>> _loadCovers(
    Set<String> dirs, {
    int? libraryId,
    Set<int>? libraryIds,
  }) async {
    if (dirs.isEmpty) return const {};
    final result = <String, Uint8List>{};
    final list = dirs.toList();
    const chunkSize = 400;
    for (var i = 0; i < list.length; i += chunkSize) {
      final chunk = list.sublist(i, _min(i + chunkSize, list.length));
      final placeholders = List.filled(chunk.length, '?').join(',');
      final clauses = <String>['dir_path IN ($placeholders)'];
      final args = <Object?>[...chunk];
      if (libraryId != null) {
        clauses.add('library_id = ?');
        args.add(libraryId);
      } else if (libraryIds != null) {
        if (libraryIds.isEmpty) continue;
        clauses.add(
          'library_id IN (${List.filled(libraryIds.length, '?').join(',')})',
        );
        args.addAll(libraryIds);
      }
      final rows = await _database.rawQuery(
        'SELECT dir_path, MIN(id) AS mid FROM photos '
        'WHERE ${clauses.join(' AND ')} GROUP BY dir_path',
        args,
      );
      final midIds = [
        for (final row in rows)
          if (row['mid'] is int) row['mid'] as int,
      ];
      final thumbnails = await _loadThumbnails(midIds);
      for (final row in rows) {
        final dir = row['dir_path'] as String?;
        final mid = row['mid'] as int?;
        final thumb = mid == null ? null : thumbnails[mid];
        if (dir != null && thumb != null) result[dir] = thumb;
      }
    }
    return result;
  }

  /// 某个库已有的照片签名（路径 → 大小/修改时间），用于增量扫描。
  Future<Map<String, List<int>>> signaturesUnder(int libraryId) async {
    final rows = await _database.query(
      'photos',
      columns: ['path', 'file_size', 'file_modified'],
      where: 'library_id = ?',
      whereArgs: [libraryId],
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
    // 用 UPSERT 而不是 INSERT OR REPLACE：后者会先删行再插入，
    // 表变大后每条记录都要重建所有索引，写放大很明显。
    final batch = _database.batch();
    for (final photo in photos) {
      final values = photo.toMap();
      batch.rawInsert(_photoUpsertSql, [
        for (final column in _photoColumns) values[column],
      ]);
      if (photo.thumbnail != null) {
        // 缩略图单独存；按 (library_id, path) 回查刚写入的 id。
        batch.rawInsert(
          'INSERT OR REPLACE INTO photo_thumbnails (photo_id, bytes) '
          'SELECT id, ? FROM photos WHERE library_id = ? AND path = ?',
          [photo.thumbnail, photo.libraryId, photo.path],
        );
      }
    }
    await batch.commit(noResult: true);
  }

  /// `photos` 的 UPSERT 语句：除 path 外全部覆盖为新值。
  static final String _photoUpsertSql = () {
    final columnList = _photoColumns.join(', ');
    final placeholders = List.filled(_photoColumns.length, '?').join(', ');
    final updates = _photoColumns
        .where((column) => column != 'path' && column != 'library_id')
        .map((column) => '$column = excluded.$column')
        .join(', ');
    return 'INSERT INTO photos ($columnList) VALUES ($placeholders) '
        'ON CONFLICT(library_id, path) DO UPDATE SET $updates';
  }();

  /// 删除某个库里已经失效的照片记录（同时清理缩略图）。
  Future<void> deletePhotosByPaths(
    int libraryId,
    Iterable<String> paths,
  ) async {
    final list = paths.toList();
    if (list.isEmpty) return;
    const chunkSize = 500;
    for (var i = 0; i < list.length; i += chunkSize) {
      final chunk = list.sublist(i, _min(i + chunkSize, list.length));
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _database.rawDelete(
        'DELETE FROM photo_thumbnails WHERE photo_id IN ('
        'SELECT id FROM photos WHERE library_id = ? AND path IN ($placeholders))',
        [libraryId, ...chunk],
      );
      await _database.delete(
        'photos',
        where: 'library_id = ? AND path IN ($placeholders)',
        whereArgs: [libraryId, ...chunk],
      );
    }
  }

  Future<void> clearAll() async {
    await _database.delete('photo_thumbnails');
    await _database.delete('photos');
    await _database.delete('libraries');
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
