/// 库中可供选择的相机型号、镜头，以及各项拍摄参数的取值范围。
class FilterOptions {
  const FilterOptions({
    this.cameraModels = const [],
    this.lensModels = const [],
    this.fNumberMin,
    this.fNumberMax,
    this.exposureMin,
    this.exposureMax,
    this.isoMin,
    this.isoMax,
  });

  final List<String> cameraModels;
  final List<String> lensModels;

  final double? fNumberMin;
  final double? fNumberMax;

  /// 单位：秒。
  final double? exposureMin;
  final double? exposureMax;

  final int? isoMin;
  final int? isoMax;

  bool get hasFNumber =>
      fNumberMin != null && fNumberMax != null && fNumberMax! > fNumberMin!;

  bool get hasExposure =>
      exposureMin != null && exposureMax != null && exposureMax! > exposureMin!;

  bool get hasIso => isoMin != null && isoMax != null && isoMax! > isoMin!;

  bool get isEmpty =>
      cameraModels.isEmpty &&
      lensModels.isEmpty &&
      !hasFNumber &&
      !hasExposure &&
      !hasIso;
}

/// 照片筛选条件。所有字段都是"可选"，为空即代表该维度不做限制。
class PhotoFilter {
  const PhotoFilter({
    this.cameraModels = const {},
    this.lensModels = const {},
    this.fNumberMin,
    this.fNumberMax,
    this.exposureMin,
    this.exposureMax,
    this.isoMin,
    this.isoMax,
    this.captureFrom,
    this.captureTo,
  });

  final Set<String> cameraModels;
  final Set<String> lensModels;

  final double? fNumberMin;
  final double? fNumberMax;

  /// 单位：秒。
  final double? exposureMin;
  final double? exposureMax;

  final int? isoMin;
  final int? isoMax;

  /// 拍摄日期下界（含当天，比较时会取当天 00:00:00）。
  final DateTime? captureFrom;

  /// 拍摄日期上界（含当天，比较时会取当天 23:59:59.999）。
  final DateTime? captureTo;

  static const PhotoFilter none = PhotoFilter();

  bool get isEmpty => activeCount == 0;

  /// 已启用的筛选维度数量。
  int get activeCount {
    var count = 0;
    if (cameraModels.isNotEmpty) count++;
    if (lensModels.isNotEmpty) count++;
    if (fNumberMin != null || fNumberMax != null) count++;
    if (exposureMin != null || exposureMax != null) count++;
    if (isoMin != null || isoMax != null) count++;
    if (captureFrom != null || captureTo != null) count++;
    return count;
  }
}

/// 取某天的 00:00:00.000，用于日期区间的下界比较。
DateTime startOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// 取某天的 23:59:59.999，用于日期区间的上界比较（含当天）。
DateTime endOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day, 23, 59, 59, 999);

/// 「年 / 月 / 日」三个输入框的解析结果。
class DateFieldInput {
  const DateFieldInput({this.year, this.month, this.day, this.error});

  final int? year;

  /// 未填写时为 null。
  final int? month;
  final int? day;

  /// 校验失败原因；为空表示输入合法。
  final String? error;

  /// 三个输入框都为空。
  bool get isEmpty => year == null && month == null && day == null;
}

/// 解析日期输入框。年必填，月、日可留空（表示精确到年或月）。
DateFieldInput parseDateFields({
  required String year,
  required String month,
  required String day,
}) {
  final yearText = year.trim();
  final monthText = month.trim();
  final dayText = day.trim();
  if (yearText.isEmpty && monthText.isEmpty && dayText.isEmpty) {
    return const DateFieldInput();
  }

  final parsedYear = int.tryParse(yearText);
  if (parsedYear == null) {
    return const DateFieldInput(error: '请填写四位年份，例如 2019');
  }
  if (parsedYear < 1826 || parsedYear > 2200) {
    return const DateFieldInput(error: '年份需要在 1826 ~ 2200 之间');
  }

  int? parsedMonth;
  if (monthText.isNotEmpty) {
    parsedMonth = int.tryParse(monthText);
    if (parsedMonth == null || parsedMonth < 1 || parsedMonth > 12) {
      return const DateFieldInput(error: '月份需要在 1 ~ 12 之间');
    }
  }

  int? parsedDay;
  if (dayText.isNotEmpty) {
    if (parsedMonth == null) {
      return const DateFieldInput(error: '填写"日"时需要同时填写月份');
    }
    parsedDay = int.tryParse(dayText);
    final limit = DateTime(parsedYear, parsedMonth + 1, 0).day;
    if (parsedDay == null || parsedDay < 1 || parsedDay > limit) {
      return DateFieldInput(error: '该月的"日"需要在 1 ~ $limit 之间');
    }
  }

  return DateFieldInput(year: parsedYear, month: parsedMonth, day: parsedDay);
}

/// 把开始侧的输入解析为区间下界；未填写返回 null。
///
/// 只填年份表示从该年 1 月 1 日起，填到月份表示从该月 1 日起。
DateTime? dateRangeStart(DateFieldInput input) {
  final year = input.year;
  if (year == null) return null;
  return DateTime(year, input.month ?? 1, input.day ?? 1);
}

/// 把结束侧的输入解析为区间上界；未填写返回 null。
///
/// 只填年份表示到该年 12 月 31 日为止，填到月份表示到该月最后一天为止。
DateTime? dateRangeEnd(DateFieldInput input) {
  final year = input.year;
  if (year == null) return null;
  final month = input.month;
  final day = input.day;
  if (day != null) return DateTime(year, month!, day);
  if (month != null) return DateTime(year, month + 1, 0); // 该月最后一天
  return DateTime(year, 12, 31);
}

/// 滑条区间解析结果。
class SliderRange {
  const SliderRange({
    this.min,
    this.max,
    this.minMoved = false,
    this.maxMoved = false,
  });

  /// 下发用的下界；[isActive] 为 false 时为 null。
  final double? min;
  final double? max;

  /// 对应端点是否被用户拖动过。
  final bool minMoved;
  final bool maxMoved;

  /// 该维度是否有生效的限制。
  bool get isActive => min != null && max != null;
}

/// 把滑条的一对取值翻译成筛选区间。
///
/// - 两端都停在可选范围的两端 → 视为"不限制"（返回未激活），这样没有 EXIF
///   参数的照片不会被误排除。
/// - 只要有一端被拖动 → **两端都给出具体值**（没动的那端用原始边界补齐）。
///   若只下发被拖动的一端，区间条件就只剩半边，无法构成完整约束。
SliderRange resolveSliderRange({
  required double sliderStart,
  required double sliderEnd,
  required double boundMin,
  required double boundMax,
  double epsilon = 1e-9,
}) {
  final minMoved = sliderStart > boundMin + epsilon;
  final maxMoved = sliderEnd < boundMax - epsilon;
  if (!minMoved && !maxMoved) return const SliderRange();
  return SliderRange(
    min: minMoved ? sliderStart : boundMin,
    max: maxMoved ? sliderEnd : boundMax,
    minMoved: minMoved,
    maxMoved: maxMoved,
  );
}
