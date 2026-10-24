import 'dart:io';

import 'package:path/path.dart' as p;

/// 把启动期异常写到日志文件。
///
/// 从资源管理器直接双击 exe 时没有控制台，异常只会停留在界面上，
/// 这里同时写入数据目录和 exe 所在目录，任一可写即可留下线索。
Future<void> writeDiagnosticLog(
  String tag,
  Object error, {
  StackTrace? stack,
}) async {
  final content =
      '===== ${DateTime.now().toIso8601String()} [$tag] =====\n'
      '$error\n'
      '${stack ?? ''}\n\n';

  for (final path in _candidatePaths()) {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(content, mode: FileMode.append, flush: true);
      return;
    } catch (_) {
      // 换下一个位置继续尝试。
    }
  }
}

Iterable<String> _candidatePaths() sync* {
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    yield p.join(exeDir, 'diagnostics.log');
  } catch (_) {
    // 忽略。
  }

  final appData = Platform.environment['APPDATA'];
  if (appData != null && appData.isNotEmpty) {
    yield p.join(
      appData,
      'com.piccontents',
      'PicContents',
      'piccontents',
      'diagnostics.log',
    );
  }

  try {
    yield p.join(Directory.systemTemp.path, 'piccontents_diagnostics.log');
  } catch (_) {
    // 忽略。
  }
}
