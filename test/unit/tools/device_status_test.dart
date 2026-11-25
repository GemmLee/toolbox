import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/device_status/device_status_channel.dart';

void main() {
  test('coreUsage 按两次采样差值计算占用率', () {
    const prev = CoreSnapshot(
      index: 0,
      curFreq: 0,
      minFreq: 0,
      maxFreq: 0,
      ticks: [100, 0, 50, 850, 0, 0, 0, 0],
    );
    const cur = CoreSnapshot(
      index: 0,
      curFreq: 0,
      minFreq: 0,
      maxFreq: 0,
      ticks: [110, 0, 60, 940, 0, 0, 0, 0],
    );
    // 总增量 110，空闲增量 90 → 忙碌 20/110
    expect(coreUsage(prev, cur), closeTo(20 / 110, 0.0001));
  });

  test('首次采样或无增量时返回 -1（未知）', () {
    final empty = CoreSnapshot(
      index: 0,
      curFreq: 0,
      minFreq: 0,
      maxFreq: 0,
      ticks: List<int>.filled(8, 0),
    );
    expect(coreUsage(null, empty), -1);
    expect(coreUsage(empty, empty), -1);
  });

  test('占用率被钳制在 0~1（时钟回退等异常情况）', () {
    const prev = CoreSnapshot(
      index: 0,
      curFreq: 0,
      minFreq: 0,
      maxFreq: 0,
      ticks: [900, 0, 0, 100, 0, 0, 0, 0],
    );
    const cur = CoreSnapshot(
      index: 0,
      curFreq: 0,
      minFreq: 0,
      maxFreq: 0,
      ticks: [950, 0, 0, 100, 0, 0, 0, 0],
    );
    expect(coreUsage(prev, cur), 1);
  });

  test('电池详情解析设计容量 / 满充容量 / 循环次数，脏数据回退 0', () {
    final detail = BatteryDetail.fromMap(<String, dynamic>{
      'level': 82.0,
      'chargeFullDesignUah': 5000000,
      'chargeFullUah': 4500000,
      'cycleCount': 213,
      'powerNowMw': 1500,
      'chargeType': 'PD',
    });
    expect(detail.chargeFullDesignUah, 5000000);
    expect(detail.chargeFullUah, 4500000);
    expect(detail.cycleCount, 213);
    expect(detail.powerNowMw, 1500);
    expect(detail.chargeType, 'PD');
    // 与详情页一致的健康度口径：满充 / 设计容量。
    final health =
        (detail.chargeFullUah * 100 / detail.chargeFullDesignUah).clamp(0, 100);
    expect(health, 90);

    final missing = BatteryDetail.fromMap(<String, dynamic>{
      'chargeFullDesignUah': 'n/a',
      'chargeFullUah': null,
    });
    expect(missing.chargeFullDesignUah, 0);
    expect(missing.chargeFullUah, 0);
    expect(missing.cycleCount, 0);
  });
}
