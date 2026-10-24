/// 扫描各阶段的累计耗时，用于定位瓶颈。
///
/// 注意：读文件、解码、编码等阶段是并发执行的，所以各项之和通常会
/// 大于实际墙钟时间；这里关心的是每个阶段的绝对开销占比。
class ScanTimings {
  int enumerateUs = 0;
  int statUs = 0;
  int readUs = 0;
  int exifUs = 0;
  int decodeUs = 0;
  int encodeUs = 0;
  int dbUs = 0;

  int get totalUs =>
      enumerateUs + statUs + readUs + exifUs + decodeUs + encodeUs + dbUs;

  Map<String, int> toMilliseconds() => {
    '枚举': enumerateUs ~/ 1000,
    'stat': statUs ~/ 1000,
    '读文件': readUs ~/ 1000,
    'EXIF': exifUs ~/ 1000,
    '解码': decodeUs ~/ 1000,
    '编码': encodeUs ~/ 1000,
    '写库': dbUs ~/ 1000,
  };

  String describe() =>
      toMilliseconds().entries.map((e) => '${e.key}=${e.value}ms').join(', ');
}
