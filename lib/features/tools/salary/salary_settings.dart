import 'package:flutter/foundation.dart';

/// 到手工资页当前使用的口径，供同一页面里的「工资统计」页签复用。
///
/// 三个页签各自独立滚动，但算社保余额与税后工资需要同一套城市 / 比例 /
/// 基数；用一个进程内 Notifier 传递，省得把整组参数沿构造器逐层往下塞。
class SalarySettings {
  const SalarySettings({
    required this.cityId,
    required this.personalRates,
    this.socialBase = 0,
    this.fundBase = 0,
    this.specialDeduction = 0,
  });

  final String cityId;
  final Map<String, double> personalRates;
  final double socialBase;
  final double fundBase;
  final double specialDeduction;

  /// 最近一次在「到手工资」页生效的设置；没打开过时为空。
  static final ValueNotifier<SalarySettings?> current =
      ValueNotifier<SalarySettings?>(null);

  /// 测试用：清掉跨用例残留。
  static void resetForTest() => current.value = null;
}
