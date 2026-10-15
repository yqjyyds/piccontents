import 'dart:io';
import 'dart:math' as math;

import '../models/photo.dart';
import 'database_service.dart';
import 'image_indexer.dart';

/// 扫描进度快照。
class ScanProgress {
  const ScanProgress({
    required this.total,
    required this.processed,
    required this.indexed,
    required this.skipped,
    required this.failed,
    this.currentPath,
  });

  /// 扫描到的图片总数。
  final int total;

  /// 已处理数量（含跳过与失败）。
  final int processed;
  final int indexed;
  final int skipped;
  final int failed;
  final String? currentPath;

  double get ratio => total == 0 ? 1 : processed / total;
}

/// 扫描结果概览。
class ScanSummary {
  const ScanSummary({
    required this.total,
    required this.indexed,
    required this.skipped,
    required this.failed,
    required this.removed,
    required this.cancelled,
  });

  final int total;
  final int indexed;
  final int skipped;
  final int failed;

  /// 已从数据库中清除的失效记录数量。
  final int removed;
  final bool cancelled;
}

/// 遍历文件夹、提取元数据并写入数据库。
class ScannerService {
  ScannerService(this._db, {this.indexer = const ImageIndexer()});

  final DatabaseService _db;
  final ImageIndexer indexer;

  /// 并行处理图片的数量。
  static int get _workerCount =>
      math.max(2, math.min(6, Platform.numberOfProcessors - 1));

  /// 扫描 [folderPath] 下的所有图片。
  ///
  /// [isCancelled] 返回 true 时尽快停止；已处理的部分结果会保留。
  Future<ScanSummary> scan(
    String folderPath, {
    required void Function(ScanProgress progress) onProgress,
    bool Function()? isCancelled,
  }) async {
    final cancelled = isCancelled ?? () => false;

    final files = <String>[];
    try {
      await for (final entity in Directory(
        folderPath,
      ).list(recursive: true, followLinks: false)) {
        if (cancelled()) {
          return ScanSummary(
            total: files.length,
            indexed: 0,
            skipped: 0,
            failed: 0,
            removed: 0,
            cancelled: true,
          );
        }
        if (entity is File && isSupportedImage(entity.path)) {
          files.add(entity.path);
        }
      }
    } on FileSystemException catch (e) {
      throw Exception('无法读取文件夹 $folderPath：${e.osError?.message ?? e.message}');
    }

    final signatures = await _db.signaturesUnder(folderPath);
    final currentPaths = files.toSet();

    // 文件大小与修改时间都没变时无需重新解析。
    final statCache = <String, List<int>>{};
    final pending = <String>[];
    for (final path in files) {
      List<int>? signature;
      try {
        final stat = await File(path).stat();
        signature = [stat.size, stat.modified.millisecondsSinceEpoch];
      } catch (_) {
        signature = null;
      }
      if (signature == null) continue;
      statCache[path] = signature;
      final existing = signatures[path];
      if (existing == null ||
          existing[0] != signature[0] ||
          existing[1] != signature[1]) {
        pending.add(path);
      }
    }

    final total = files.length;
    var processed = total - pending.length;
    var indexed = 0;
    var failed = 0;
    final initiallySkipped = total - pending.length;
    var wasCancelled = false;

    void report(String? current) {
      onProgress(
        ScanProgress(
          total: total,
          processed: processed,
          indexed: indexed,
          skipped: initiallySkipped,
          failed: failed,
          currentPath: current,
        ),
      );
    }

    report(null);

    final buffer = <Photo>[];
    var cursor = 0;

    Future<void> flush() async {
      if (buffer.isEmpty) return;
      final batch = List<Photo>.from(buffer);
      buffer.clear();
      await _db.upsertPhotos(batch);
    }

    Future<void> worker() async {
      while (true) {
        if (cancelled()) {
          wasCancelled = true;
          return;
        }
        final index = cursor++;
        if (index >= pending.length) return;
        final path = pending[index];
        final signature = statCache[path]!;
        try {
          final photo = await indexer.indexImage(
            path,
            folderPath,
            fileSize: signature[0],
            fileModified: signature[1],
          );
          if (photo != null) {
            buffer.add(photo);
            indexed++;
          } else {
            failed++;
          }
        } catch (_) {
          failed++;
        }
        processed++;
        if (buffer.length >= 16) {
          await flush();
        }
        report(path);
      }
    }

    final workerCount = math.min(_workerCount, math.max(1, pending.length));
    await Future.wait(List.generate(workerCount, (_) => worker()));
    await flush();

    // 只有当文件夹确实可访问且扫描完整时才清理失效记录，
    // 避免外接盘 / 网络盘脱机时误删索引。
    var removed = 0;
    if (!wasCancelled && files.isNotEmpty) {
      final stale = signatures.keys
          .where((path) => !currentPaths.contains(path))
          .toList();
      if (stale.isNotEmpty) {
        await _db.deletePhotosByPaths(stale);
        removed = stale.length;
      }
    }

    await _db.markFolderScanned(folderPath);

    onProgress(
      ScanProgress(
        total: total,
        processed: total,
        indexed: indexed,
        skipped: initiallySkipped,
        failed: failed,
      ),
    );

    return ScanSummary(
      total: total,
      indexed: indexed,
      skipped: initiallySkipped,
      failed: failed,
      removed: removed,
      cancelled: wasCancelled,
    );
  }

  /// 校验照片的原始文件是否仍在磁盘上（用于判断文件夹是否脱机）。
  Future<void> checkAvailability(List<Photo> photos) async {
    for (final photo in photos) {
      try {
        final stat = await File(photo.path).stat();
        photo.isFileAvailable = stat.type == FileSystemEntityType.file;
      } catch (_) {
        photo.isFileAvailable = false;
      }
    }
  }
}
