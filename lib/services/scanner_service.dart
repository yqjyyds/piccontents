import 'dart:io';
import 'dart:math' as math;

import '../models/photo.dart';
import '../utils/index_paths.dart';
import 'database_service.dart';
import 'diagnostics.dart';
import 'image_indexer.dart';
import 'index_worker_pool.dart';
import 'scan_timings.dart';
import 'volume_identity.dart';

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
    required this.elapsedMs,
    required this.timingsMs,
    this.skippedDirs = 0,
    this.diskError = false,
    this.volumeChanged = false,
  });

  final int total;
  final int indexed;
  final int skipped;
  final int failed;

  /// 已从数据库中清除的失效记录数量。
  final int removed;
  final bool cancelled;

  /// 因无权限等原因被跳过的子目录数量。
  final int skippedDirs;

  /// 是否因连续读取失败而提前中止（通常意味着磁盘有坏块）。
  final bool diskError;

  /// 扫描期间盘符上的卷是否发生了变化（例如中途换了硬盘）。
  final bool volumeChanged;

  /// 实际墙钟耗时。
  final int elapsedMs;

  /// 各阶段累计耗时（毫秒），用于定位瓶颈。
  final Map<String, int> timingsMs;

  /// 实际处理（读盘 + 解析）过的照片数，跳过的未变化文件不计入。
  int get processed => total - skipped;

  /// 真实处理速度：用实际处理数而不是枚举总数，避免暂停/取消时虚高。
  double get photosPerSecond =>
      elapsedMs <= 0 ? 0 : processed * 1000 / elapsedMs;
}

/// 遍历文件夹、提取元数据并写入数据库。
class ScannerService {
  ScannerService(this._db, {this.indexer = const ImageIndexer()});

  final DatabaseService _db;
  final ImageIndexer indexer;

  /// 同时处理的图片数量。
  ///
  /// 读盘才是瓶颈，并发读对机械盘会造成寻道风暴，对坏块盘会让重试堆在一起，
  /// 所以这里压到 2~3；解码/编码本身很轻，不需要更高的并发。
  static int get _pipelineWorkers {
    final cpus = Platform.numberOfProcessors;
    return cpus < 4 ? 2 : 3;
  }

  /// 写库批量大小。
  static const int _dbBatchSize = 128;

  /// 进度回调的最小间隔，避免每张照片都重建整个界面。
  static const int _progressIntervalMs = 250;

  /// 连续读取失败多少张后判定磁盘异常并中止，避免对着坏盘空转。
  static const int _maxConsecutiveFailures = 12;

  /// 扫描 [folderPath] 下的所有图片。
  ///
  /// [isCancelled] 返回 true 时尽快停止；已处理的部分结果会保留。
  Future<ScanSummary> scan(
    String folderPath, {
    required void Function(ScanProgress progress) onProgress,
    bool Function()? isCancelled,
  }) async {
    final cancelled = isCancelled ?? () => false;
    final timings = ScanTimings();
    final totalWatch = Stopwatch()..start();
    folderPath = normalizeIndexRootPath(folderPath);
    final volumeAtStart = identifyVolume(folderPath);
    final library = await _db.activeLibrary(folderPath);
    if (library == null) {
      throw Exception('索引目录未注册：$folderPath');
    }
    final libraryId = library.id;

    ScanSummary buildSummary({
      required int total,
      required int indexed,
      required int skipped,
      required int failed,
      required int removed,
      required bool wasCancelled,
      int skippedDirs = 0,
      bool diskError = false,
      bool volumeChanged = false,
    }) => ScanSummary(
      total: total,
      indexed: indexed,
      skipped: skipped,
      failed: failed,
      removed: removed,
      cancelled: wasCancelled,
      elapsedMs: totalWatch.elapsedMilliseconds,
      timingsMs: timings.toMilliseconds(),
      skippedDirs: skippedDirs,
      diskError: diskError,
      volumeChanged: volumeChanged,
    );

    // ---------------------------------------------------------- 1. 枚举文件
    //
    // 不用 recursive: true：全盘扫描遇到 System Volume Information、
    // $RECYCLE.BIN 这类无权限目录时，递归遍历会直接抛异常中断整个扫描。
    // 改为逐层遍历，每个目录单独捕获，跳过无权限目录继续扫其余部分。
    final enumWatch = Stopwatch()..start();
    final files = <String>[];
    final visited = <String>{};
    final queue = <String>[folderPath];
    var skippedDirs = 0;
    var enumerateCancelled = false;
    while (queue.isNotEmpty) {
      if (cancelled()) {
        enumerateCancelled = true;
        break;
      }
      final dirPath = queue.removeLast();
      if (!visited.add(dirPath)) continue;
      try {
        await for (final entity in Directory(
          dirPath,
        ).list(followLinks: false)) {
          if (cancelled()) {
            enumerateCancelled = true;
            break;
          }
          if (entity is File) {
            if (isSupportedImage(entity.path)) files.add(entity.path);
          } else if (entity is Directory) {
            queue.add(entity.path);
          }
        }
      } on FileSystemException catch (e) {
        if (dirPath == folderPath) {
          // 根目录本身读不了（空光驱、脱机网络盘）才视为失败。
          timings.enumerateUs = enumWatch.elapsedMicroseconds;
          throw Exception(
            '无法读取文件夹 $folderPath：${e.osError?.message ?? e.message}',
          );
        }
        skippedDirs++;
      }
      if (enumerateCancelled) break;
    }
    timings.enumerateUs = enumWatch.elapsedMicroseconds;

    if (enumerateCancelled) {
      return buildSummary(
        total: files.length,
        indexed: 0,
        skipped: 0,
        failed: 0,
        removed: 0,
        wasCancelled: true,
        skippedDirs: skippedDirs,
      );
    }

    final signatures = await _db.signaturesUnder(libraryId);
    final currentPaths = files.toSet();

    // ------------------------------------------------- 2. stat（分批并发）
    final statWatch = Stopwatch()..start();
    final statCache = <String, List<int>>{};
    final pending = <String>[];
    const statChunk = 64;
    for (var i = 0; i < files.length; i += statChunk) {
      if (cancelled()) break;
      final end = math.min(i + statChunk, files.length);
      final slice = files.sublist(i, end);
      final results = await Future.wait(
        slice.map((path) async {
          try {
            final stat = await File(path).stat();
            return MapEntry(path, [
              stat.size,
              stat.modified.millisecondsSinceEpoch,
            ]);
          } catch (_) {
            return null;
          }
        }),
      );
      for (final entry in results) {
        if (entry == null) continue;
        statCache[entry.key] = entry.value;
        final existing = signatures[entry.key];
        if (existing == null ||
            existing[0] != entry.value[0] ||
            existing[1] != entry.value[1]) {
          pending.add(entry.key);
        }
      }
    }
    timings.statUs = statWatch.elapsedMicroseconds;

    // ---------------------------------------------------------- 3. 处理图片
    final total = files.length;
    var processed = total - pending.length;
    var indexed = 0;
    var failed = 0;
    final initiallySkipped = total - pending.length;
    var wasCancelled = false;

    var lastReportMs = -_progressIntervalMs;
    final reportWatch = Stopwatch()..start();

    void report(String? current, {bool force = false}) {
      final now = reportWatch.elapsedMilliseconds;
      if (!force && now - lastReportMs < _progressIntervalMs) return;
      lastReportMs = now;
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

    report(null, force: true);

    final buffer = <Photo>[];
    final failedSamples = <String>[];
    var cursor = 0;
    var consecutiveFailures = 0;
    var diskError = false;

    IndexWorkerPool? pool;
    try {
      pool = await IndexWorkerPool.start();
      final activePool = pool;

      Future<void> flush() async {
        if (buffer.isEmpty) return;
        final batch = List<Photo>.from(buffer);
        buffer.clear();
        final watch = Stopwatch()..start();
        await _db.upsertPhotos(batch);
        timings.dbUs += watch.elapsedMicroseconds;
      }

      Future<void> worker() async {
        while (true) {
          if (cancelled()) {
            wasCancelled = true;
            return;
          }
          if (diskError) return;
          final index = cursor++;
          if (index >= pending.length) return;
          final path = pending[index];
          final signature = statCache[path]!;
          Photo? photo;
          try {
            photo = await indexer.indexImage(
              path,
              folderPath,
              libraryId: libraryId,
              pool: activePool,
              fileSize: signature[0],
              fileModified: signature[1],
              timings: timings,
            );
          } catch (_) {
            photo = null;
          }
          if (photo != null) {
            buffer.add(photo);
            indexed++;
            consecutiveFailures = 0;
          } else {
            failed++;
            consecutiveFailures++;
            if (failedSamples.length < 20) failedSamples.add(path);
            if (consecutiveFailures >= _maxConsecutiveFailures) {
              diskError = true;
            }
          }
          processed++;
          if (buffer.length >= _dbBatchSize) {
            await flush();
          }
          report(path);
          if (diskError) return;
        }
      }

      final workerCount = math.min(
        _pipelineWorkers,
        math.max(1, pending.length),
      );
      await Future.wait(List.generate(workerCount, (_) => worker()));
      await flush();
    } finally {
      await pool?.close();
    }

    // 连续读取失败通常意味着坏块，把样本写进日志便于排查。
    if (failedSamples.isNotEmpty) {
      await writeDiagnosticLog(
        'ScanReadFailures',
        '本次扫描有 $failed 张读取失败，示例：\n${failedSamples.join('\n')}',
      );
    }

    // 扫描期间盘符上的卷被换掉时，绝不能按"旧盘的文件都不在了"去删记录。
    final volumeNow = identifyVolume(folderPath);
    final volumeChanged =
        volumeAtStart != null &&
        volumeNow != null &&
        !volumeAtStart.matches(volumeNow);

    // 只有当文件夹确实可访问且扫描完整时才清理失效记录，
    // 避免外接盘 / 网络盘脱机、坏盘中途失败或中途换盘时误删索引。
    var removed = 0;
    if (!wasCancelled && !diskError && !volumeChanged && files.isNotEmpty) {
      final stale = signatures.keys
          .where((path) => !currentPaths.contains(path))
          .toList();
      if (stale.isNotEmpty) {
        final watch = Stopwatch()..start();
        await _db.deletePhotosByPaths(libraryId, stale);
        timings.dbUs += watch.elapsedMicroseconds;
        removed = stale.length;
      }
    }

    await _db.markFolderScanned(folderPath);

    report(null, force: true);

    return buildSummary(
      total: total,
      indexed: indexed,
      skipped: initiallySkipped,
      failed: failed,
      removed: removed,
      wasCancelled: wasCancelled,
      skippedDirs: skippedDirs,
      diskError: diskError,
      volumeChanged: volumeChanged,
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
