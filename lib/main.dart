import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'pages/home_page.dart';
import 'services/database_service.dart';
import 'services/diagnostics.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 从资源管理器启动时没有控制台，把未捕获异常落到文件里便于排查。
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    writeDiagnosticLog('FlutterError', details.exception, stack: details.stack);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    writeDiagnosticLog('Uncaught', error, stack: stack);
    return true;
  };

  Object? initError;
  try {
    await DatabaseService.instance.init();
  } catch (e, stack) {
    initError = e;
    await writeDiagnosticLog('DatabaseInit', e, stack: stack);
  }

  runApp(PicContentsApp(initError: initError));
}

class PicContentsApp extends StatelessWidget {
  const PicContentsApp({super.key, this.initError});

  final Object? initError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '图片检索',
      debugShowCheckedModeBanner: false,
      // 让日期选择器等系统控件显示中文。
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2F6FEB),
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
      ),
      home: initError == null
          ? const HomePage()
          : _StartupErrorPage(error: initError!),
    );
  }
}

class _StartupErrorPage extends StatelessWidget {
  const _StartupErrorPage({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: Colors.redAccent,
              ),
              const SizedBox(height: 16),
              const Text(
                '数据库初始化失败',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 720,
                  maxHeight: 260,
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    '$error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: '$error'));
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('错误信息已复制')));
                    },
                    icon: const Icon(Icons.copy_all_outlined, size: 16),
                    label: const Text('复制错误'),
                  ),
                  FilledButton(
                    onPressed: () => exit(0),
                    child: const Text('退出'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '详细日志已写入 exe 同目录或数据目录下的 diagnostics.log',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
