import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:piccontents/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('v5 → v6 迁移保留照片、缩略图、归档关系与同路径副本', () async {
    final dir = await Directory.systemTemp.createTemp('piccontents_migrate');
    final dbPath = '${dir.path}${Platform.pathSeparator}test.db';
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(dbPath);
    try {
      // ---- 构造 v5 表结构 ----
      await db.execute('''
        CREATE TABLE folders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          path TEXT NOT NULL UNIQUE,
          display_name TEXT,
          volume_guid TEXT,
          volume_serial INTEGER,
          volume_label TEXT,
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
      await db.execute('''
        CREATE TABLE libraries (
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
        CREATE TABLE archived_photos (
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

      // 活动根目录（五号盘）与一份已归档索引（系统盘）。
      await db.insert('folders', {
        'path': r'E:\',
        'display_name': '五号盘',
        'volume_guid': r'\\?\Volume{active}\',
        'volume_serial': 111,
        'volume_label': '五号盘',
        'added_at': 1,
        'last_scan_at': 2,
      });
      await db.insert('libraries', {
        'path': r'E:\',
        'display_name': '五号盘',
        'volume_guid': r'\\?\Volume{archived}\',
        'volume_serial': 222,
        'volume_label': '系统',
        'archived_at': 3,
      });

      // 同一条路径在活动盘和归档盘里各有一份（不同物理硬盘）。
      await db.insert('photos', {
        'path': r'E:\未命名导出\IMG_0001.JPG',
        'file_name': 'IMG_0001.JPG',
        'folder_path': r'E:\',
        'dir_path': r'E:\未命名导出',
        'file_size': 11,
        'thumbnail': Uint8List.fromList([1, 2, 3]),
      });
      await db.insert('photos', {
        'path': r'E:\未命名导出\IMG_0002.JPG',
        'file_name': 'IMG_0002.JPG',
        'folder_path': r'E:\',
        'dir_path': r'E:\未命名导出',
        'file_size': 12,
      });
      await db.insert('archived_photos', {
        'library_id': 1,
        'path': r'E:\未命名导出\IMG_0001.JPG',
        'file_name': 'IMG_0001.JPG',
        'folder_path': r'E:\',
        'dir_path': r'E:\未命名导出',
        'file_size': 21,
        'thumbnail': Uint8List.fromList([4, 5, 6]),
      });

      // ---- 执行迁移 ----
      await DatabaseService.migrateToV6(db);

      final libraries = await db.query('libraries', orderBy: 'id ASC');
      expect(libraries.length, 2);
      final active = libraries.firstWhere((r) => r['archived_at'] == null);
      final archived = libraries.firstWhere((r) => r['archived_at'] != null);
      expect(active['volume_label'], '五号盘');
      expect(archived['volume_label'], '系统');

      final photos = await db.query('photos');
      expect(photos.length, 3);
      // 同一路径允许在两个库中各存一份。
      final duplicate = photos.where(
        (r) => r['path'] == r'E:\未命名导出\IMG_0001.JPG',
      );
      expect(duplicate.length, 2);
      expect(duplicate.map((r) => r['library_id']).toSet().length, 2);

      final thumbnails = await db.query('photo_thumbnails');
      expect(thumbnails.length, 2);
      final archivedPhoto = duplicate.firstWhere(
        (r) => r['library_id'] == archived['id'],
      );
      expect(
        thumbnails.any((t) => t['photo_id'] == archivedPhoto['id']),
        isTrue,
      );

      // 关键索引存在。
      final indexes = await db.query(
        'sqlite_master',
        columns: ['name'],
        where: 'type = ?',
        whereArgs: ['index'],
      );
      final names = indexes.map((r) => r['name'] as String).toSet();
      expect(names, contains('ux_libraries_active_path'));
      expect(names, contains('idx_photos_library_capture'));

      // 旧表已被替换。
      final tables = await db.query(
        'sqlite_master',
        columns: ['name'],
        where: 'type = ?',
        whereArgs: ['table'],
      );
      final tableNames = tables.map((r) => r['name'] as String).toSet();
      expect(tableNames, isNot(contains('folders')));
      expect(tableNames, isNot(contains('archived_photos')));
      expect(tableNames, contains('photo_thumbnails'));
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
