import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/device_status/battery_history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('toolbox/device_status');

  void mockBattery({double level = 76, double temp = 33.5}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'batteryDetail') {
        return <String, dynamic>{
          'level': level,
          'temperature': temp,
          'currentNowUa': -450000,
        };
      }
      return null;
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sampleNow 直接读原生电量并落一个采样点', () async {
    await BatteryHistory.clear();
    mockBattery(level: 76, temp: 33.5);
    expect(await BatteryHistory.sampleNow(force: true), isTrue);
    expect(BatteryHistory.samples, hasLength(1));
    final sample = BatteryHistory.samples.last;
    expect(sample.level, 76);
    expect(sample.temp, 33.5);
    expect(sample.currentUa, -450000);
  });

  test('间隔不足 minGap 时不开新点，只刷新最后一个点', () async {
    await BatteryHistory.clear();
    mockBattery(level: 80);
    expect(await BatteryHistory.sampleNow(force: true), isTrue);
    mockBattery(level: 79);
    expect(await BatteryHistory.sampleNow(), isFalse);
    expect(BatteryHistory.samples, hasLength(1));
    expect(BatteryHistory.samples.last.level, 79, reason: '最近一次电量要更新');
  });

  test('原生通道不可用时静默返回 false，不抛给调用方', () async {
    await BatteryHistory.clear();
    expect(await BatteryHistory.sampleNow(force: true), isFalse);
    expect(BatteryHistory.samples, isEmpty);
  });

  test('自动采样间隔提升到 15 分钟', () {
    expect(BatteryHistory.autoInterval.inMinutes, 15);
  });

  group('温度轴动态范围', () {
    test('上下各留半个跨度：32~38℃ → 29~41℃', () {
      final (lo, hi) = tempAxisRange(<double>[32, 35, 38]);
      expect(lo, closeTo(29, 1e-9));
      expect(hi, closeTo(41, 1e-9));
      // 曲线只占中间一半高度，正好落在 1/4 ~ 3/4 处。
      expect((32 - lo) / (hi - lo), closeTo(0.25, 1e-9));
      expect((38 - lo) / (hi - lo), closeTo(0.75, 1e-9));
    });

    test('几乎恒温时保底跨度，不把 0.1℃ 放大成锯齿', () {
      final (lo, hi) = tempAxisRange(<double>[33.4, 33.5, 33.4]);
      // 保底跨度 1℃ 再上下各留半个跨度 → 总窗口 2℃。
      expect(hi - lo, closeTo(2, 1e-9));
      expect((lo + hi) / 2, closeTo(33.45, 1e-9));
      // 0.1℃ 的起伏只占 5% 高度，看起来是平的而不是锯齿。
      expect((33.5 - 33.4) / (hi - lo), closeTo(0.05, 1e-9));
    });

    test('没有数据时给 1℃ 窗口，不除零', () {
      final (lo, hi) = tempAxisRange(const <double>[]);
      expect(hi - lo, closeTo(1, 1e-9));
    });
  });
}
