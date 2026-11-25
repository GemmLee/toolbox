import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../core/storage/local_store.dart';

/// 尺子 / 量角器共用的几何与校准计算（纯逻辑，便于单元测试）。
class MeasureGeometry {
  MeasureGeometry._();

  /// 名义换算：Android 的 dp 定义为 1/160 英寸，即 1cm ≈ 63.0 逻辑像素。
  /// 真机差异在 ±6% 内，作为未校准时的默认值足够；校准后以用户值为准。
  static const double nominalPxPerCm = 160 / 2.54;

  /// 校准允许的区间（逻辑像素 / 厘米）：覆盖 4"~7.5" 主流手机屏。
  static const double minPxPerCm = 40;
  static const double maxPxPerCm = 95;

  /// 银行卡 / 身份证短边 53.98mm，作为校准基准物。
  static const double cardShortSideCm = 5.398;

  static const String _key = 'measure_calibration';

  /// 读取已保存的校准值；没有则用名义值。
  static Future<double> loadPxPerCm() async {
    final map = await LocalStore.readMap(_key);
    final value = map?['pxPerCm'];
    if (value is num && value >= minPxPerCm && value <= maxPxPerCm) {
      return value.toDouble();
    }
    return nominalPxPerCm;
  }

  static Future<void> savePxPerCm(double value) async {
    await LocalStore.writeMap(_key, <String, dynamic>{
      'pxPerCm': value.clamp(minPxPerCm, maxPxPerCm),
    });
  }

  /// 厘米 → 逻辑像素。
  static double cmToPx(double cm, double pxPerCm) => cm * pxPerCm;

  /// 逻辑像素 → 厘米。
  static double pxToCm(double px, double pxPerCm) => px / pxPerCm;

  /// 屏幕可视宽度对应的厘米数。
  static double visibleWidthCm(double widthPx, double pxPerCm) =>
      widthPx / pxPerCm;

  /// 格式化长度：小于 10cm 时保留两位小数（毫米级），否则一位。
  static String formatCm(double cm) {
    if (cm < 0) cm = 0;
    return cm < 10 ? cm.toStringAsFixed(2) : cm.toStringAsFixed(1);
  }

  static String formatMm(double cm) => (cm * 10).round().toString();

  /// 量角器角度：以半圆圆心为轴，把触点换算成 0~180°。
  ///
  /// [pivot] 与 [point] 都是相对半圆所在矩形的局部坐标，y 轴向下，
  /// 因此需要取反 dy 才是数学坐标系里的高度。
  static double angleFromPoint(Offset pivot, Offset point) {
    final dx = point.dx - pivot.dx;
    final dy = pivot.dy - point.dy;
    if (dx == 0 && dy == 0) return 0;
    // 基线以下（手机外）吸附到最近的端点：右侧 0°、左侧 180°。
    if (dy < 0) return dx >= 0 ? 0 : 180;
    final deg = math.atan2(dy, dx) * 180 / math.pi;
    return deg.clamp(0.0, 180.0);
  }

  /// 角度吸附：默认按 0.5° 取整，手势抖动不会让读数乱跳。
  static double snapAngle(double deg, {double step = 0.5}) {
    if (step <= 0) return deg;
    return (deg / step).round() * step;
  }

  /// 弧度（供绘制使用）。
  static double degreesToRadians(double deg) => deg * math.pi / 180;

  /// 常见角度参考，用于量角器页面的快捷按钮。
  static const List<int> presetAngles = <int>[0, 30, 45, 60, 90, 120, 135, 150, 180];
}
