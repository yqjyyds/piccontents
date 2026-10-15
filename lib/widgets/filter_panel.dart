import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/photo_filter.dart';
import '../utils/formatters.dart';

/// 筛选面板：按相机型号 / 镜头多选，按光圈 / 快门 / ISO 拖动或用输入框设定范围。
class FilterPanel extends StatefulWidget {
  const FilterPanel({
    super.key,
    required this.filter,
    required this.options,
    required this.onChanged,
    required this.onClear,
  });

  final PhotoFilter filter;
  final FilterOptions options;
  final ValueChanged<PhotoFilter> onChanged;
  final VoidCallback onClear;

  @override
  State<FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<FilterPanel> {
  late Set<String> _cameras;
  late Set<String> _lenses;

  /// 光圈滑条直接使用 F 值。
  late RangeValues _fNumber;

  /// 快门滑条使用 log10(秒)，ISO 滑条使用 log10(ISO)，
  /// 这样 1/8000s ~ 30s、ISO 50 ~ 25600 都能被均匀拖动。
  late RangeValues _shutterLog;
  late RangeValues _isoLog;

  /// 已生效的拍摄日期区间（仅精确到天）。
  DateTime? _captureFrom;
  DateTime? _captureTo;

  /// 日期输入框的校验提示。
  String? _dateError;

  final _startYear = TextEditingController();
  final _startMonth = TextEditingController();
  final _startDay = TextEditingController();
  final _endYear = TextEditingController();
  final _endMonth = TextEditingController();
  final _endDay = TextEditingController();

  final _fNumberStart = TextEditingController();
  final _fNumberEnd = TextEditingController();
  final _shutterStart = TextEditingController();
  final _shutterEnd = TextEditingController();
  final _isoStart = TextEditingController();
  final _isoEnd = TextEditingController();

  /// 记录面板自己发出的筛选条件，避免回传后重置用户正在编辑的输入框。
  PhotoFilter? _lastEmitted;

  FilterOptions get _options => widget.options;

  double get _fMin => _options.fNumberMin ?? 1.8;
  double get _fMax => _options.fNumberMax ?? 22;

  double get _shutterLogMin => _log10(_options.exposureMin ?? 0.001);
  double get _shutterLogMax => _log10(_options.exposureMax ?? 1);

  double get _isoLogMin => _log10((_options.isoMin ?? 100).toDouble());
  double get _isoLogMax => _log10((_options.isoMax ?? 6400).toDouble());

  @override
  void initState() {
    super.initState();
    _syncFromFilter(widget.filter);
  }

  @override
  void didUpdateWidget(FilterPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.options != oldWidget.options) {
      // 极值设置收窄后，界面上的取值可能被夹小，需要同步回筛选条件。
      // 这里正处于 build 阶段，推迟到当前帧结束后再回调外部。
      if (_clampToOptions()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _emit();
        });
      }
    }
    // 只有当筛选条件来自外部（清除、切换筛选等）时才重新同步控件。
    if (!identical(widget.filter, _lastEmitted)) {
      _syncFromFilter(widget.filter);
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _startYear,
      _startMonth,
      _startDay,
      _endYear,
      _endMonth,
      _endDay,
      _fNumberStart,
      _fNumberEnd,
      _shutterStart,
      _shutterEnd,
      _isoStart,
      _isoEnd,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  static double _log10(double value) => math.log(value) / math.ln10;

  /// 滑条刻度数。
  ///
  /// 必须封顶：极值设置放大后（例如光圈上限被设成几十万），
  /// 按步长算出的刻度数会达到百万级，绘制刻度会把界面卡死。
  static int _divisions(double min, double max, double step) {
    final count = ((max - min) / step).round();
    return count.clamp(1, 300);
  }

  void _syncFromFilter(PhotoFilter filter) {
    _cameras = Set.of(filter.cameraModels);
    _lenses = Set.of(filter.lensModels);
    _fNumber = RangeValues(
      (filter.fNumberMin ?? _fMin).clamp(_fMin, _fMax),
      (filter.fNumberMax ?? _fMax).clamp(_fMin, _fMax),
    );
    _shutterLog = RangeValues(
      _toShutterLog(filter.exposureMin ?? _options.exposureMin ?? 0.001),
      _toShutterLog(filter.exposureMax ?? _options.exposureMax ?? 1),
    );
    _isoLog = RangeValues(
      _toIsoLog((filter.isoMin ?? _options.isoMin ?? 100).toDouble()),
      _toIsoLog((filter.isoMax ?? _options.isoMax ?? 6400).toDouble()),
    );
    final from = filter.captureFrom;
    final to = filter.captureTo;
    _captureFrom = from;
    _captureTo = to;
    _dateError = null;
    _startYear.text = from == null ? '' : '${from.year}';
    _startMonth.text = from == null ? '' : '${from.month}';
    _startDay.text = from == null ? '' : '${from.day}';
    _endYear.text = to == null ? '' : '${to.year}';
    _endMonth.text = to == null ? '' : '${to.month}';
    _endDay.text = to == null ? '' : '${to.day}';
    _updateTexts();
  }

  /// 取值范围变化后（例如重新扫描、修改极值设置）把当前值夹到新范围内。
  ///
  /// 返回是否真的发生了夹取，需要调用方据此重新下发筛选条件。
  bool _clampToOptions() {
    var changed = false;

    final fNumber = RangeValues(
      _fNumber.start.clamp(_fMin, _fMax),
      _fNumber.end.clamp(_fMin, _fMax),
    );
    if (fNumber != _fNumber) changed = true;
    _fNumber = fNumber;

    final shutter = RangeValues(
      _shutterLog.start.clamp(_shutterLogMin, _shutterLogMax),
      _shutterLog.end.clamp(_shutterLogMin, _shutterLogMax),
    );
    if (shutter != _shutterLog) changed = true;
    _shutterLog = shutter;

    final iso = RangeValues(
      _isoLog.start.clamp(_isoLogMin, _isoLogMax),
      _isoLog.end.clamp(_isoLogMin, _isoLogMax),
    );
    if (iso != _isoLog) changed = true;
    _isoLog = iso;

    _updateTexts();
    return changed;
  }

  double _toShutterLog(double seconds) =>
      _log10(seconds).clamp(_shutterLogMin, _shutterLogMax);

  double _toIsoLog(double iso) => _log10(iso).clamp(_isoLogMin, _isoLogMax);

  double get _shutterLow => math.pow(10, _shutterLog.start).toDouble();

  double get _shutterHigh => math.pow(10, _shutterLog.end).toDouble();

  int get _isoLow => snapIso(math.pow(10, _isoLog.start).toDouble());

  int get _isoHigh => snapIso(math.pow(10, _isoLog.end).toDouble());

  void _updateTexts() {
    _fNumberStart.text = _fNumber.start.toStringAsFixed(1);
    _fNumberEnd.text = _fNumber.end.toStringAsFixed(1);
    _shutterStart.text = formatExposureTime(_shutterLow);
    _shutterEnd.text = formatExposureTime(_shutterHigh);
    _isoStart.text = '$_isoLow';
    _isoEnd.text = '$_isoHigh';
  }

  /// 把界面状态转换成筛选条件并通知外部。
  void _emit() {
    final options = _options;
    // 滑条两端都没动 → 该维度不限制，避免把没有 EXIF 参数的照片误排除；
    // 只要动了一端，两端都会带上具体值，保证区间条件完整生效。
    final fRange = options.hasFNumber
        ? resolveSliderRange(
            sliderStart: _fNumber.start,
            sliderEnd: _fNumber.end,
            boundMin: _fMin,
            boundMax: _fMax,
            epsilon: 1e-6,
          )
        : const SliderRange();
    final eRange = options.hasExposure
        ? resolveSliderRange(
            sliderStart: _shutterLog.start,
            sliderEnd: _shutterLog.end,
            boundMin: _shutterLogMin,
            boundMax: _shutterLogMax,
          )
        : const SliderRange();
    final iRange = options.hasIso
        ? resolveSliderRange(
            sliderStart: _isoLog.start,
            sliderEnd: _isoLog.end,
            boundMin: _isoLogMin,
            boundMax: _isoLogMax,
          )
        : const SliderRange();

    final filter = PhotoFilter(
      cameraModels: Set.of(_cameras),
      lensModels: Set.of(_lenses),
      fNumberMin: !fRange.isActive
          ? null
          : (fRange.minMoved ? fRange.min : options.fNumberMin),
      fNumberMax: !fRange.isActive
          ? null
          : (fRange.maxMoved ? fRange.max : options.fNumberMax),
      exposureMin: !eRange.isActive
          ? null
          : (eRange.minMoved
                ? math.pow(10, eRange.min!).toDouble()
                : options.exposureMin),
      exposureMax: !eRange.isActive
          ? null
          : (eRange.maxMoved
                ? math.pow(10, eRange.max!).toDouble()
                : options.exposureMax),
      isoMin: !iRange.isActive
          ? null
          : (iRange.minMoved
                ? snapIso(math.pow(10, iRange.min!).toDouble())
                : options.isoMin),
      isoMax: !iRange.isActive
          ? null
          : (iRange.maxMoved
                ? snapIso(math.pow(10, iRange.max!).toDouble())
                : options.isoMax),
      captureFrom: _captureFrom,
      captureTo: _captureTo,
    );
    _lastEmitted = filter;
    widget.onChanged(filter);
  }

  /// 三个日期输入框是否填了任何内容。
  bool get _hasDateInput =>
      _captureFrom != null ||
      _captureTo != null ||
      _startYear.text.isNotEmpty ||
      _startMonth.text.isNotEmpty ||
      _startDay.text.isNotEmpty ||
      _endYear.text.isNotEmpty ||
      _endMonth.text.isNotEmpty ||
      _endDay.text.isNotEmpty;

  /// 校验并应用日期输入。月、日留空表示精确到年 / 月。
  void _applyDateInput() {
    final startInput = parseDateFields(
      year: _startYear.text,
      month: _startMonth.text,
      day: _startDay.text,
    );
    final endInput = parseDateFields(
      year: _endYear.text,
      month: _endMonth.text,
      day: _endDay.text,
    );

    final error = startInput.error ?? endInput.error;
    if (error != null) {
      setState(() => _dateError = error);
      return;
    }

    final from = dateRangeStart(startInput);
    final to = dateRangeEnd(endInput);
    if (from != null && to != null && from.isAfter(to)) {
      setState(() => _dateError = '开始日期不能晚于结束日期');
      return;
    }

    setState(() {
      _dateError = null;
      _captureFrom = from;
      _captureTo = to;
    });
    _emit();
  }

  void _clearDateInput() {
    setState(() {
      _captureFrom = null;
      _captureTo = null;
      _dateError = null;
      for (final controller in [
        _startYear,
        _startMonth,
        _startDay,
        _endYear,
        _endMonth,
        _endDay,
      ]) {
        controller.clear();
      }
    });
    _emit();
  }

  /// 当前生效范围的说明文字，让用户确认自己填的日期被理解成了什么。
  String get _dateHint {
    if (_captureFrom == null && _captureTo == null) return '';
    final from = _captureFrom == null ? '不限' : formatDate(_captureFrom);
    final to = _captureTo == null ? '不限' : formatDate(_captureTo);
    return '生效范围：$from ~ $to';
  }

  void _toggleCamera(String value) {
    setState(() {
      if (!_cameras.remove(value)) _cameras.add(value);
    });
    _emit();
  }

  void _toggleLens(String value) {
    setState(() {
      if (!_lenses.remove(value)) _lenses.add(value);
    });
    _emit();
  }

  void _submitFNumber(bool isStart) {
    final parsed = double.tryParse(
      (isStart ? _fNumberStart : _fNumberEnd).text.trim(),
    );
    if (parsed == null) {
      _updateTexts();
      return;
    }
    final value = parsed.clamp(_fMin, _fMax);
    setState(() {
      _fNumber = isStart
          ? RangeValues(math.min(value, _fNumber.end), _fNumber.end)
          : RangeValues(_fNumber.start, math.max(value, _fNumber.start));
    });
    _updateTexts();
    _emit();
  }

  void _submitShutter(bool isStart) {
    final parsed = parseExposureTime(
      (isStart ? _shutterStart : _shutterEnd).text,
    );
    if (parsed == null) {
      _updateTexts();
      return;
    }
    final value = _toShutterLog(parsed);
    setState(() {
      _shutterLog = isStart
          ? RangeValues(math.min(value, _shutterLog.end), _shutterLog.end)
          : RangeValues(_shutterLog.start, math.max(value, _shutterLog.start));
    });
    _updateTexts();
    _emit();
  }

  void _submitIso(bool isStart) {
    final parsed = int.tryParse((isStart ? _isoStart : _isoEnd).text.trim());
    if (parsed == null || parsed <= 0) {
      _updateTexts();
      return;
    }
    final value = _toIsoLog(parsed.toDouble());
    setState(() {
      _isoLog = isStart
          ? RangeValues(math.min(value, _isoLog.end), _isoLog.end)
          : RangeValues(_isoLog.start, math.max(value, _isoLog.start));
    });
    _updateTexts();
    _emit();
  }

  void _clear() {
    widget.onClear();
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = _options;
    final hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.hintColor,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.tune, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text('筛选条件', style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                onPressed: widget.filter.isEmpty ? null : _clear,
                icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
                label: const Text('清除全部'),
              ),
            ],
          ),
          if (options.isEmpty && !_hasDateInput)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('尚未索引到可筛选的相机型号或拍摄参数。', style: hintStyle),
            )
          else ...[
            _CaptureDateRow(
              startYear: _startYear,
              startMonth: _startMonth,
              startDay: _startDay,
              endYear: _endYear,
              endMonth: _endMonth,
              endDay: _endDay,
              onSubmitted: _applyDateInput,
              onClear: _clearDateInput,
              hasValue: _captureFrom != null || _captureTo != null,
              error: _dateError,
              hint: _dateHint,
            ),
            if (options.cameraModels.isNotEmpty)
              _ChipSection(
                title: '相机型号',
                values: options.cameraModels,
                selected: _cameras,
                onToggle: _toggleCamera,
              ),
            if (options.lensModels.isNotEmpty)
              _ChipSection(
                title: '镜头',
                values: options.lensModels,
                selected: _lenses,
                onToggle: _toggleLens,
              ),
            if (options.hasFNumber)
              _RangeRow(
                label: '光圈',
                startController: _fNumberStart,
                endController: _fNumberEnd,
                onStartSubmitted: () => _submitFNumber(true),
                onEndSubmitted: () => _submitFNumber(false),
                slider: RangeSlider(
                  values: _fNumber,
                  min: _fMin,
                  max: _fMax,
                  divisions: _divisions(_fMin, _fMax, 0.1),
                  onChanged: (values) => setState(() => _fNumber = values),
                  onChangeEnd: (values) {
                    _updateTexts();
                    _emit();
                  },
                ),
              ),
            if (options.hasExposure)
              _RangeRow(
                label: '快门',
                startController: _shutterStart,
                endController: _shutterEnd,
                onStartSubmitted: () => _submitShutter(true),
                onEndSubmitted: () => _submitShutter(false),
                slider: RangeSlider(
                  values: _shutterLog,
                  min: _shutterLogMin,
                  max: _shutterLogMax,
                  divisions: _divisions(_shutterLogMin, _shutterLogMax, 0.1),
                  onChanged: (values) => setState(() => _shutterLog = values),
                  onChangeEnd: (values) {
                    _updateTexts();
                    _emit();
                  },
                ),
              ),
            if (options.hasIso)
              _RangeRow(
                label: 'ISO',
                startController: _isoStart,
                endController: _isoEnd,
                onStartSubmitted: () => _submitIso(true),
                onEndSubmitted: () => _submitIso(false),
                slider: RangeSlider(
                  values: _isoLog,
                  min: _isoLogMin,
                  max: _isoLogMax,
                  divisions: _divisions(_isoLogMin, _isoLogMax, 0.1),
                  onChanged: (values) => setState(() => _isoLog = values),
                  onChangeEnd: (values) {
                    _updateTexts();
                    _emit();
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 拍摄日期区间：直接填「年 / 月 / 日」，方便直接跳到几年前。
///
/// 月、日可以留空，表示按整年或整月筛选。
class _CaptureDateRow extends StatelessWidget {
  const _CaptureDateRow({
    required this.startYear,
    required this.startMonth,
    required this.startDay,
    required this.endYear,
    required this.endMonth,
    required this.endDay,
    required this.onSubmitted,
    required this.onClear,
    required this.hasValue,
    required this.error,
    required this.hint,
  });

  final TextEditingController startYear;
  final TextEditingController startMonth;
  final TextEditingController startDay;
  final TextEditingController endYear;
  final TextEditingController endMonth;
  final TextEditingController endDay;
  final VoidCallback onSubmitted;
  final VoidCallback onClear;
  final bool hasValue;
  final String? error;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = error ?? (hint.isEmpty ? null : hint);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  '拍摄日期',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _DateField(
                        controller: startYear,
                        suffix: '年',
                        width: 66,
                        onSubmitted: onSubmitted,
                      ),
                      const SizedBox(width: 4),
                      _DateField(
                        controller: startMonth,
                        suffix: '月',
                        width: 56,
                        onSubmitted: onSubmitted,
                      ),
                      const SizedBox(width: 4),
                      _DateField(
                        controller: startDay,
                        suffix: '日',
                        width: 56,
                        onSubmitted: onSubmitted,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text('~', style: theme.textTheme.bodyMedium),
                      ),
                      _DateField(
                        controller: endYear,
                        suffix: '年',
                        width: 66,
                        onSubmitted: onSubmitted,
                      ),
                      const SizedBox(width: 4),
                      _DateField(
                        controller: endMonth,
                        suffix: '月',
                        width: 56,
                        onSubmitted: onSubmitted,
                      ),
                      const SizedBox(width: 4),
                      _DateField(
                        controller: endDay,
                        suffix: '日',
                        width: 56,
                        onSubmitted: onSubmitted,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              if (hasValue)
                ElevatedButton(
                  onPressed: onSubmitted,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('应用'),
                )
              else
                const SizedBox(width: 60),
              if (hasValue)
                IconButton(
                  tooltip: '清除日期条件',
                  onPressed: onClear,
                  icon: const Icon(Icons.clear, size: 16),
                )
              else
                const SizedBox(width: 40),
            ],
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(left: 52, top: 4),
              child: Text(
                message,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: error != null
                      ? theme.colorScheme.error
                      : theme.hintColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单个日期数字输入框。
class _DateField extends StatelessWidget {
  const _DateField({
    required this.controller,
    required this.suffix,
    required this.width,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final String suffix;
  final double width;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12),
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(4),
        ],
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 8,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          suffixText: suffix,
          suffixStyle: theme.textTheme.labelSmall?.copyWith(
            color: theme.hintColor,
          ),
          hintStyle: theme.textTheme.bodySmall,
        ),
        onSubmitted: (_) => onSubmitted(),
        onTapOutside: (_) => onSubmitted(),
      ),
    );
  }
}

class _ChipSection extends StatelessWidget {
  const _ChipSection({
    required this.title,
    required this.values,
    required this.selected,
    required this.onToggle,
  });

  final String title;
  final List<String> values;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                title,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                selected.isEmpty ? '全部' : '已选 ${selected.length} 项',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 76),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final value in values)
                    FilterChip(
                      label: Text(value, style: const TextStyle(fontSize: 12)),
                      selected: selected.contains(value),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onSelected: (_) => onToggle(value),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RangeRow extends StatelessWidget {
  const _RangeRow({
    required this.label,
    required this.slider,
    required this.startController,
    required this.endController,
    required this.onStartSubmitted,
    required this.onEndSubmitted,
  });

  final String label;
  final Widget slider;
  final TextEditingController startController;
  final TextEditingController endController;
  final VoidCallback onStartSubmitted;
  final VoidCallback onEndSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          _RangeField(
            controller: startController,
            onSubmitted: onStartSubmitted,
          ),
          Expanded(child: slider),
          _RangeField(controller: endController, onSubmitted: onEndSubmitted),
        ],
      ),
    );
  }
}

class _RangeField extends StatelessWidget {
  const _RangeField({required this.controller, required this.onSubmitted});

  final TextEditingController controller;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 74,
      child: TextField(
        controller: controller,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9./\s]')),
        ],
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 6,
            vertical: 6,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          hintStyle: theme.textTheme.bodySmall,
        ),
        onSubmitted: (_) => onSubmitted(),
        onTapOutside: (_) => onSubmitted(),
      ),
    );
  }
}
