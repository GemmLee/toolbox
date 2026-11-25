import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/device_status/battery_detail_page.dart';
import 'package:toolbox/features/tools/device_status/device_status_page.dart';
import '../support/test_env.dart';

const MethodChannel _channel = MethodChannel('toolbox/device_status');

/// 系统 avg 电流不可用（0）、sysfs 容量数据缺失的典型机型。
Map<String, Object?> _detail({
  int currentNowUa = -500000,
  int currentAvgUa = 0,
  int chargeCounterUah = 2000000,
  double level = 50,
}) =>
    <String, Object?>{
      'level': level,
      'temperature': 31.5,
      'voltageMv': 4000,
      'status': 3,
      'plugged': 0,
      'health': 2,
      'technology': 'Li-ion',
      'chargeCounterUah': chargeCounterUah,
      'capacityPercent': 50,
      'currentNowUa': currentNowUa,
      'currentAvgUa': currentAvgUa,
      'chargeFullUah': 0,
      'chargeFullDesignUah': 0,
      'cycleCount': 0,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  installCleanEnv();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets('平均电流在系统值缺失时用实测滚动均值', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'batteryDetail') return _detail();
      return null;
    });

    await tester.pumpWidget(const MaterialApp(home: BatteryDetailPage()));
    await tester.pump(); // 首次拉取
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    // 500 mA 的放电电流：当前电流与平均电流都应给出数值（两处 500 mA）
    expect(find.text('500 mA'), findsNWidgets(2));
    // 平均电流不应再空白
    expect(find.text('平均电流'), findsOneWidget);
  });

  testWidgets('容量数据缺失时显示「系统未提供」，满充容量按电量推算', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'batteryDetail') return _detail();
      return null;
    });

    await tester.pumpWidget(const MaterialApp(home: BatteryDetailPage()));
    await tester.pumpAndSettle();

    // 容量卡在页面底部（趋势/曲线卡之后），先滚到可视范围再断言
    await tester.dragUntilVisible(
      find.text('容量与寿命'),
      find.byType(ListView),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();

    // 标称容量 / 循环次数：系统节点没给，显示未提供，不再提示需要 root
    expect(find.text('系统未提供'), findsNWidgets(3));
    expect(find.textContaining('root'), findsNothing);
    // 2000 mAh ÷ 50% → 估算 4000 mAh
    expect(find.textContaining('4,000 mAh'), findsOneWidget);
    expect(find.textContaining('由当前电量推算'), findsOneWidget);
  });

  test('开机时长不足一天显示小时分钟，超过一天改显示天小时', () {
    expect(formatUptime(const Duration(hours: 5, minutes: 30)),
        '5 小时 30 分');
    expect(formatUptime(const Duration(hours: 23, minutes: 59)),
        '23 小时 59 分');
    expect(formatUptime(const Duration(hours: 24)), '1 天 0 小时');
    expect(formatUptime(const Duration(hours: 49, minutes: 42)),
        '2 天 1 小时');
  });
}
