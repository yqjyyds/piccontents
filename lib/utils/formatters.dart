import 'package:intl/intl.dart';

final DateFormat _dateTimeFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

String formatDateTime(DateTime? value) =>
    value == null ? '—' : _dateTimeFormat.format(value);

String formatDate(DateTime? value) =>
    value == null ? '—' : DateFormat('yyyy-MM-dd').format(value);

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(unit == 0 ? 0 : 2)} ${units[unit]}';
}

/// 把秒数格式化成摄影中常见的快门表示法，例如 `1/250 s`、`2.5 s`。
String formatExposureTime(double? seconds) {
  if (seconds == null || seconds <= 0) return '—';
  if (seconds >= 1) {
    final rounded = seconds.toStringAsFixed(
      seconds == seconds.roundToDouble() ? 0 : 1,
    );
    return '$rounded s';
  }
  return '1/${(1 / seconds).round()} s';
}

String formatFNumber(double? value) =>
    value == null ? '—' : 'f/${value.toStringAsFixed(1)}';

String formatFocalLength(double? value) => value == null
    ? '—'
    : '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} mm';

String formatExposureBias(double? value) {
  if (value == null) return '—';
  if (value == 0) return '±0 EV';
  return '${value > 0 ? '+' : ''}${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} EV';
}

String formatIso(int? value) => value == null ? '—' : 'ISO $value';

String formatResolution(int? width, int? height) {
  if (width == null || height == null) return '—';
  final megapixels = width * height / 1000000;
  return '$width × $height（${megapixels.toStringAsFixed(1)} MP）';
}

String formatGps(double? lat, double? lon, double? altitude) {
  if (lat == null || lon == null) return '—';
  final buffer = StringBuffer(
    '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}',
  );
  if (altitude != null) {
    buffer.write('（海拔 ${altitude.toStringAsFixed(1)} m）');
  }
  return buffer.toString();
}

/// 解析用户手动输入的快门时间，支持 `1/250`、`1/250 s`、`0.004`、`2` 等写法。
///
/// 返回秒数；无法解析或非正数时返回 null。
double? parseExposureTime(String text) {
  final trimmed = text.trim().replaceAll(RegExp(r'[sS]$'), '').trim();
  if (trimmed.isEmpty) return null;

  final fraction = RegExp(r'^(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)$')
      .firstMatch(trimmed);
  if (fraction != null) {
    final numerator = double.parse(fraction.group(1)!);
    final denominator = double.parse(fraction.group(2)!);
    if (denominator == 0) return null;
    final value = numerator / denominator;
    return value > 0 && value.isFinite ? value : null;
  }

  final value = double.tryParse(trimmed);
  if (value == null || value <= 0 || !value.isFinite) return null;
  return value;
}

/// 常见的标准 ISO 感光度档位。
const List<int> kIsoStops = [
  25,
  32,
  40,
  50,
  64,
  80,
  100,
  125,
  160,
  200,
  250,
  320,
  400,
  500,
  640,
  800,
  1000,
  1250,
  1600,
  2000,
  2500,
  3200,
  4000,
  5000,
  6400,
  8000,
  10000,
  12800,
  16000,
  20000,
  25600,
  32000,
  40000,
  51200,
  64000,
  80000,
  102400,
  204800,
];

/// 把任意数值吸附到最接近的标准 ISO 档位，避免滑条产生 126、398 这类数字。
int snapIso(double value) {
  var best = kIsoStops.first;
  for (final stop in kIsoStops) {
    if ((stop - value).abs() < (best - value).abs()) best = stop;
  }
  return best;
}
