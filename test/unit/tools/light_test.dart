import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/measure/light_meter.dart';
import 'package:toolbox/features/tools/measure/light_view.dart';
import 'package:toolbox/features/tools/measure/measure_page.dart';
import '../../support/test_env.dart';

/// 假光照传感器：手动推送 lux 值。
class _FakeLightSensor implements LightSensor {
  final controller = StreamController<double>.broadcast();

  @override
  Stream<double> luxStream() => controller.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  installCleanEnv();

  group('光照分析', () {
    test('首帧直接采用读数，之后上升快、下降慢', () {
      final analyzer = LightAnalyzer();
      expect(analyzer.process(100).lux, 100);
      // 突然变亮：一帧抬升一半以上（100 + 900×0.55 = 595）。
      final bright = analyzer.process(1000).lux;
      expect(bright, greaterThan(500));
      // 突然变暗：只回落一部分（595 + (100-595)×0.18 ≈ 506）。
      final dim = analyzer.process(100).lux;
      expect(dim, lessThan(bright));
      expect(dim, greaterThan(400));
    });

    test('记录最小 / 最大 / 平均（基于平滑后读数）', () {
      final analyzer = LightAnalyzer();
      analyzer.process(100);
      final s = analyzer.process(200);
      expect(s.min, 100);
      expect(s.max, closeTo(155, 1));
      expect(s.average, inInclusiveRange(100, 155));
    });

    test('读数限制在 0 ~ 200000', () {
      final analyzer = LightAnalyzer();
      expect(analyzer.process(-5).lux, 0);
      final s = analyzer.process(999999);
      expect(s.lux, lessThanOrEqualTo(200000));
    });

    test('光照分级阈值', () {
      expect(LightAnalyzer.zoneOf(0.5), LightZone.dark);
      expect(LightAnalyzer.zoneOf(5), LightZone.dim);
      expect(LightAnalyzer.zoneOf(50), LightZone.indoorDim);
      expect(LightAnalyzer.zoneOf(100), LightZone.indoor);
      expect(LightAnalyzer.zoneOf(1000), LightZone.bright);
      expect(LightAnalyzer.zoneOf(5000), LightZone.outdoor);
      expect(LightAnalyzer.zoneOf(50000), LightZone.direct);
    });

    test('对数电平：0.1 为 0，100000 为满格，100 为半格', () {
      expect(LightAnalyzer.levelOf(0.1), 0);
      expect(LightAnalyzer.levelOf(100000), 1);
      expect(LightAnalyzer.levelOf(100), closeTo(0.5, 1e-9));
      expect(LightAnalyzer.levelOf(0.01), 0);
    });

    test('读数格式化：小数 / 整数 / k 缩写', () {
      expect(LightAnalyzer.formatLux(3.21), '3.2');
      expect(LightAnalyzer.formatLux(123), '123');
      expect(LightAnalyzer.formatLux(1234), '1.23k');
      expect(LightAnalyzer.formatLux(12345), '12.3k');
    });
  });

  group('光强控制器', () {
    test('订阅传感器并推送读数', () async {
      final sensor = _FakeLightSensor();
      final controller = LightMeterController(sensor: sensor);
      expect(controller.running, isFalse);

      await controller.start();
      expect(controller.running, isTrue);
      sensor.controller.add(120);
      sensor.controller.add(130);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.sample, isNotNull);
      expect(controller.sample!.lux, greaterThan(100));
      expect(controller.error, isNull);

      await controller.stop();
      expect(controller.running, isFalse);
      controller.dispose();
    });

    test('传感器缺失（流报错）时给出提示且不崩溃', () async {
      final sensor = _FakeLightSensor();
      final controller = LightMeterController(sensor: sensor);
      await controller.start();
      sensor.controller.addError(StateError('no_sensor'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.running, isFalse);
      expect(controller.error, isNotNull);
      controller.dispose();
    });

    test('重复 start 只订阅一次', () async {
      final sensor = _FakeLightSensor();
      final controller = LightMeterController(sensor: sensor);
      await controller.start();
      await controller.start();
      expect(controller.running, isTrue);
      await controller.stop();
      controller.dispose();
    });
  });

  group('光强计页面', () {
    testWidgets('显示环境光照卡片并可开始测量', (tester) async {
      final sensor = _FakeLightSensor();
      final controller = LightMeterController(sensor: sensor);
      await tester.pumpWidget(MaterialApp(
        home: MeasurePage(
          initialPxPerCm: 63,
          lightController: controller,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('光强计'));
      await tester.pumpAndSettle();
      expect(find.text('环境光照'), findsOneWidget);
      expect(find.text('开始测量'), findsOneWidget);
      expect(find.text('常见光照参考'), findsOneWidget);

      await tester.tap(find.text('开始测量'));
      await tester.pump();
      sensor.controller.add(300);
      await tester.pump();
      await tester.pump();
      expect(find.text('300'), findsOneWidget);

      await tester.runAsync(() => controller.stop());
    });

    testWidgets('无传感器时显示错误提示', (tester) async {
      final sensor = _FakeLightSensor();
      final controller = LightMeterController(sensor: sensor);
      await tester.pumpWidget(MaterialApp(
        home: LightView(controller: controller),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('开始测量'));
      await tester.pump();
      sensor.controller.addError(StateError('no_sensor'));
      await tester.pump();
      await tester.pump();
      expect(find.text('当前设备没有环境光传感器，无法测量光照。'), findsOneWidget);
      await tester.runAsync(() => controller.stop());
    });
  });
}
