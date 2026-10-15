import 'photo_filter.dart';

/// 筛选滑条的极值设置。
///
/// 默认使用库中实际数据的范围；用户也可以在设置里指定固定的极值，
/// 以便输入超出当前数据范围的条件。
class SliderBounds {
  const SliderBounds({
    required this.fNumberMin,
    required this.fNumberMax,
    required this.exposureMin,
    required this.exposureMax,
    required this.isoMin,
    required this.isoMax,
  });

  /// 光圈。
  final double fNumberMin;
  final double fNumberMax;

  /// 快门，单位秒。
  final double exposureMin;
  final double exposureMax;

  /// 感光度。
  final int isoMin;
  final int isoMax;

  bool get isValid =>
      fNumberMax > fNumberMin && exposureMax > exposureMin && isoMax > isoMin;
}

/// 库中缺少某项参数时，设置对话框里用来预填的兜底取值。
const SliderBounds kDefaultSliderBounds = SliderBounds(
  fNumberMin: 1.4,
  fNumberMax: 32,
  exposureMin: 1 / 8000,
  exposureMax: 30,
  isoMin: 50,
  isoMax: 204800,
);

/// 决定界面实际使用的滑条取值范围。
///
/// 用户设置过就完全按设置来；没设置过则沿用库中实际数据的范围，
/// 某一项没有数据时该维度不显示滑条（而不是给一个筛不出结果的范围）。
FilterOptions resolveFilterOptions(FilterOptions data, SliderBounds? bounds) {
  if (bounds != null) {
    return FilterOptions(
      cameraModels: data.cameraModels,
      lensModels: data.lensModels,
      fNumberMin: bounds.fNumberMin,
      fNumberMax: bounds.fNumberMax,
      exposureMin: bounds.exposureMin,
      exposureMax: bounds.exposureMax,
      isoMin: bounds.isoMin,
      isoMax: bounds.isoMax,
    );
  }
  return data;
}
