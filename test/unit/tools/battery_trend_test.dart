import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/device_status/battery_history.dart';

BatterySample _s(int minutes, double level) => BatterySample(
      time: DateTime(2026, 11, 4, 12).add(Duration(minutes: minutes)),
      level: level,
      temp: 30,
      currentUa: -500000,
    );

void main() {
  group('BatteryTrend', () {
    test('放电：按加权斜率算 %/h 与剩余时间', () {
      // 60 分钟掉 10%，即 10%/h → 剩 80% 约 8 小时
      final trend = BatteryTrend.fromSamples(<BatterySample>[
        _s(0, 90),
        _s(30, 85),
        _s(60, 80),
      ]);
      expect(trend, isNotNull);
      expect(trend!.percentPerHour, closeTo(-10, 0.001));
      expect(trend.charging, isFalse);
      expect(trend.remaining, isNotNull);
      expect(trend.remaining!.inMinutes, closeTo(480, 1));
    });

    test('充电：剩余时间按充满所需百分比算', () {
      // 60 分钟涨 20% → 20%/h，从 50% 充满还需 2.5 小时
      final trend = BatteryTrend.fromSamples(<BatterySample>[
        _s(0, 30),
        _s(60, 50),
      ]);
      expect(trend!.charging, isTrue);
      expect(trend.percentPerHour, closeTo(20, 0.001));
      expect(trend.remaining!.inMinutes, closeTo(150, 1));
    });

    test('样点不足或跨度过小时返回 null', () {
      expect(BatteryTrend.fromSamples(const <BatterySample>[]), isNull);
      expect(BatteryTrend.fromSamples(<BatterySample>[_s(0, 50)]), isNull);
      // 只有 1 秒的两个点
      final a = BatterySample(
        time: DateTime(2026, 11, 4, 12),
        level: 50,
        temp: 30,
        currentUa: 0,
      );
      final b = BatterySample(
        time: a.time.add(const Duration(seconds: 1)),
        level: 50,
        temp: 30,
        currentUa: 0,
      );
      final trend = BatteryTrend.fromSamples(<BatterySample>[a, b]);
      // 跨度为 0 小时时无法计算速率
      expect(trend == null || trend.percentPerHour.isNaN || trend.percentPerHour == 0,
          isTrue);
    });

    test('异常跳变（插拔）不参与斜率', () {
      final trend = BatteryTrend.fromSamples(<BatterySample>[
        _s(0, 80),
        _s(30, 78),
        // 突然跳到 5% 再回来，属于异常段
        _s(31, 5),
        _s(32, 78),
        _s(62, 76),
      ]);
      expect(trend, isNotNull);
      // 只保留两段正常的 -2%
      expect(trend!.percentPerHour, closeTo(-4, 0.5));
    });

    test('速率过小时不给剩余时间', () {
      final trend = BatteryTrend.fromSamples(<BatterySample>[
        _s(0, 50),
        _s(60, 50),
      ]);
      expect(trend!.percentPerHour, 0);
      expect(trend.remaining, isNull);
    });

    test('只看最近 1 小时的采样', () {
      final trend = BatteryTrend.fromSamples(<BatterySample>[
        _s(0, 100),
        _s(120, 60),
        _s(150, 55),
        _s(180, 50),
      ]);
      // 只取 120~180 分钟段：-10% / 1h
      expect(trend!.percentPerHour, closeTo(-10, 0.001));
      expect(trend.span.inMinutes, 60);
    });
  });
}
