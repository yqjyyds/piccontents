import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'image_codec.dart';

/// 常驻的 worker isolate 池。
///
/// 之前每张照片都 `Isolate.run` 新建一个 isolate（5~20ms 开销），
/// 这里改为一次性建好、反复复用。池子承担两类纯 Dart 任务：
/// - EXIF 解析（IO 轻、开销小）
/// - 缩略图 JPEG 编码（CPU 密集，是之前串行阻塞主线程的元凶）
///
/// 图片解码依赖 `dart:ui`，只能在根 isolate 做，因此不在这里。
class IndexWorkerPool {
  IndexWorkerPool._(this._workers);

  final List<_WorkerHandle> _workers;
  bool _closed = false;

  static int defaultWorkerCount() {
    final cpus = Platform.numberOfProcessors;
    if (cpus <= 2) return 2;
    return cpus - 1 > 8 ? 8 : cpus - 1;
  }

  static Future<IndexWorkerPool> start({int? workerCount}) async {
    final count = workerCount ?? defaultWorkerCount();
    final handles = <_WorkerHandle>[];
    try {
      for (var i = 0; i < count; i++) {
        handles.add(await _WorkerHandle.spawn());
      }
    } catch (_) {
      for (final handle in handles) {
        handle.kill();
      }
      rethrow;
    }
    return IndexWorkerPool._(handles);
  }

  /// 解析 EXIF。[microseconds] 是 worker 内部实际处理耗时。
  ///
  /// 传入的是主 isolate 已经读好的文件字节，worker 不再访问磁盘。
  Future<({Map<String, Object?> facts, int microseconds})> runExifBytes(
    Uint8List bytes,
  ) async {
    if (_closed) throw StateError('worker 池已关闭');
    final response = await _pick().send({
      'cmd': 'exifBytes',
      'bytes': TransferableTypedData.fromList([bytes]),
    });
    final microseconds = response['us'] as int? ?? 0;
    if (response['ok'] != true) {
      throw StateError('EXIF 解析失败：${response['error']}');
    }
    final facts = (response['facts'] as Map?)?.cast<String, Object?>();
    return (
      facts: facts ?? const <String, Object?>{},
      microseconds: microseconds,
    );
  }

  /// 编码缩略图。[microseconds] 是 worker 内部实际处理耗时。
  Future<({EncodedThumbnail? thumbnail, int microseconds})> runEncode(
    DecodedThumbnail source,
    int? orientation,
  ) async {
    if (_closed) throw StateError('worker 池已关闭');
    final response = await _pick().send({
      'cmd': 'encode',
      // 转移所有权，避免把 RGBA 拷贝一次。
      'rgba': TransferableTypedData.fromList([source.rgba]),
      'width': source.width,
      'height': source.height,
      'orientation': orientation,
    });
    final microseconds = response['us'] as int? ?? 0;
    if (response['ok'] != true) {
      return (thumbnail: null, microseconds: microseconds);
    }
    final jpeg = response['jpeg'] as TransferableTypedData?;
    if (jpeg == null) return (thumbnail: null, microseconds: microseconds);
    return (
      thumbnail: EncodedThumbnail(
        jpeg.materialize().asUint8List(),
        response['width'] as int? ?? source.width,
        response['height'] as int? ?? source.height,
      ),
      microseconds: microseconds,
    );
  }

  /// 选当前排队最少的 worker。
  _WorkerHandle _pick() {
    var best = _workers.first;
    for (final worker in _workers) {
      if (worker.pendingCount < best.pendingCount) best = worker;
    }
    return best;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final worker in _workers) {
      worker.kill();
    }
  }
}

class _WorkerHandle {
  _WorkerHandle._(this._isolate, this._receivePort);

  final Isolate _isolate;
  final ReceivePort _receivePort;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  SendPort? _sendPort;
  int _nextId = 1;

  int get pendingCount => _pending.length;

  static Future<_WorkerHandle> spawn() async {
    final receivePort = ReceivePort();
    final ready = Completer<SendPort>();
    final isolate = await Isolate.spawn(
      _workerMain,
      receivePort.sendPort,
      onError: receivePort.sendPort,
      onExit: receivePort.sendPort,
      errorsAreFatal: false,
    );
    final handle = _WorkerHandle._(isolate, receivePort);

    receivePort.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is Map) {
        final id = message['id'];
        if (id is int) {
          handle._pending.remove(id)?.complete(message.cast<String, Object?>());
          return;
        }
      }
      // onExit 发 null，onError 发 [error, stack]
      handle._failAll('worker isolate 异常退出：$message');
    });

    handle._sendPort = await ready.future;
    return handle;
  }

  Future<Map<String, Object?>> send(Map<String, Object?> payload) {
    final sendPort = _sendPort;
    if (sendPort == null) {
      return Future.error(StateError('worker 尚未就绪'));
    }
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    payload['id'] = id;
    sendPort.send(payload);
    return completer.future;
  }

  void _failAll(String message) {
    if (_pending.isEmpty) return;
    final error = StateError(message);
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  void kill() {
    _failAll('worker 池已关闭');
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// worker isolate 入口。必须保持为顶层函数。
void _workerMain(SendPort mainPort) {
  final receivePort = ReceivePort();
  mainPort.send(receivePort.sendPort);

  receivePort.listen((message) async {
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;

    final stopwatch = Stopwatch()..start();
    try {
      final command = message['cmd'];
      if (command == 'exifBytes') {
        final bytes = (message['bytes'] as TransferableTypedData)
            .materialize()
            .asUint8List();
        final facts = await readExifFactsFromBytes(bytes);
        mainPort.send({
          'id': id,
          'ok': true,
          'facts': facts,
          'us': stopwatch.elapsedMicroseconds,
        });
      } else if (command == 'encode') {
        final rgba = (message['rgba'] as TransferableTypedData)
            .materialize()
            .asUint8List();
        final encoded = encodeThumbnailFromRgba(
          rgba,
          message['width'] as int,
          message['height'] as int,
          message['orientation'] as int?,
        );
        if (encoded == null) {
          mainPort.send({
            'id': id,
            'ok': false,
            'error': '缩略图编码失败',
            'us': stopwatch.elapsedMicroseconds,
          });
        } else {
          mainPort.send({
            'id': id,
            'ok': true,
            'jpeg': TransferableTypedData.fromList([encoded.bytes]),
            'width': encoded.width,
            'height': encoded.height,
            'us': stopwatch.elapsedMicroseconds,
          });
        }
      } else {
        mainPort.send({'id': id, 'ok': false, 'error': '未知任务：$command'});
      }
    } catch (e) {
      mainPort.send({
        'id': id,
        'ok': false,
        'error': '$e',
        'us': stopwatch.elapsedMicroseconds,
      });
    }
  });
}
