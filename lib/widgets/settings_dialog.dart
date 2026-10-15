import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/photo_filter.dart';
import '../utils/formatters.dart';

/// 设置对话框的返回值。[bounds] 为 null 表示恢复成"按实际数据范围"。
class SliderBoundsResult {
  const SliderBoundsResult(this.bounds);

  final SliderBounds? bounds;
}

/// 滑条极值设置：让用户自己指定光圈 / 快门 / ISO 的可调范围，
/// 从而可以输入超出当前数据范围的条件。
class SliderBoundsDialog extends StatefulWidget {
  const SliderBoundsDialog({
    super.key,
    required this.effectiveOptions,
    required this.currentBounds,
  });

  /// 当前界面实际使用的取值范围，用于预填。
  final FilterOptions effectiveOptions;

  /// 已保存的设置；null 表示当前按实际数据范围。
  final SliderBounds? currentBounds;

  @override
  State<SliderBoundsDialog> createState() => _SliderBoundsDialogState();
}

class _SliderBoundsDialogState extends State<SliderBoundsDialog> {
  late final TextEditingController _fNumberMin;
  late final TextEditingController _fNumberMax;
  late final TextEditingController _exposureMin;
  late final TextEditingController _exposureMax;
  late final TextEditingController _isoMin;
  late final TextEditingController _isoMax;

  String? _error;

  @override
  void initState() {
    super.initState();
    final options = widget.effectiveOptions;
    _fNumberMin = _controller(
      (options.fNumberMin ?? kDefaultSliderBounds.fNumberMin).toStringAsFixed(
        1,
      ),
    );
    _fNumberMax = _controller(
      (options.fNumberMax ?? kDefaultSliderBounds.fNumberMax).toStringAsFixed(
        1,
      ),
    );
    _exposureMin = _controller(
      formatExposureTime(
        options.exposureMin ?? kDefaultSliderBounds.exposureMin,
      ),
    );
    _exposureMax = _controller(
      formatExposureTime(
        options.exposureMax ?? kDefaultSliderBounds.exposureMax,
      ),
    );
    _isoMin = _controller('${options.isoMin ?? kDefaultSliderBounds.isoMin}');
    _isoMax = _controller('${options.isoMax ?? kDefaultSliderBounds.isoMax}');
  }

  TextEditingController _controller(String text) =>
      TextEditingController(text: text);

  @override
  void dispose() {
    for (final controller in [
      _fNumberMin,
      _fNumberMax,
      _exposureMin,
      _exposureMax,
      _isoMin,
      _isoMax,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    final fMin = double.tryParse(_fNumberMin.text.trim());
    final fMax = double.tryParse(_fNumberMax.text.trim());
    if (fMin == null || fMax == null || fMin <= 0 || fMax <= 0) {
      setState(() => _error = '光圈需要填写正数');
      return;
    }
    if (fMax <= fMin) {
      setState(() => _error = '光圈的最大值需要大于最小值');
      return;
    }

    final eMin = parseExposureTime(_exposureMin.text);
    final eMax = parseExposureTime(_exposureMax.text);
    if (eMin == null || eMax == null) {
      setState(() => _error = '快门请填写 1/250 或 0.004 这类正数');
      return;
    }
    if (eMax <= eMin) {
      setState(() => _error = '快门的最大值需要大于最小值');
      return;
    }

    final iMin = int.tryParse(_isoMin.text.trim());
    final iMax = int.tryParse(_isoMax.text.trim());
    if (iMin == null || iMax == null || iMin <= 0 || iMax <= 0) {
      setState(() => _error = 'ISO 需要填写正整数');
      return;
    }
    if (iMax <= iMin) {
      setState(() => _error = 'ISO 的最大值需要大于最小值');
      return;
    }

    Navigator.pop(
      context,
      SliderBoundsResult(
        SliderBounds(
          fNumberMin: fMin,
          fNumberMax: fMax,
          exposureMin: eMin,
          exposureMax: eMax,
          isoMin: iMin,
          isoMax: iMax,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCustom = widget.currentBounds != null;

    return AlertDialog(
      title: const Text('设置'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '筛选滑条的可调范围',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                isCustom
                    ? '当前使用自定义范围。修改后即可输入超出照片数据范围的条件。'
                    : '当前按库中照片的实际数据范围。也可以在这里固定一个范围。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
              const SizedBox(height: 12),
              _BoundsRow(
                label: '光圈',
                startController: _fNumberMin,
                endController: _fNumberMax,
                hintStart: '最小',
                hintEnd: '最大',
              ),
              const SizedBox(height: 8),
              _BoundsRow(
                label: '快门',
                startController: _exposureMin,
                endController: _exposureMax,
                hintStart: '最小',
                hintEnd: '最大',
                helper: '支持 1/250 或 0.004 两种写法，单位为秒',
              ),
              const SizedBox(height: 8),
              _BoundsRow(
                label: 'ISO',
                startController: _isoMin,
                endController: _isoMax,
                hintStart: '最小',
                hintEnd: '最大',
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: isCustom
              ? () => Navigator.pop(context, const SliderBoundsResult(null))
              : null,
          child: const Text('恢复数据范围'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

class _BoundsRow extends StatelessWidget {
  const _BoundsRow({
    required this.label,
    required this.startController,
    required this.endController,
    required this.hintStart,
    required this.hintEnd,
    this.helper,
  });

  final String label;
  final TextEditingController startController;
  final TextEditingController endController;
  final String hintStart;
  final String hintEnd;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 56,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: startController,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: hintStart,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('~'),
                  ),
                  Expanded(
                    child: TextField(
                      controller: endController,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: hintEnd,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              if (helper != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    helper!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
