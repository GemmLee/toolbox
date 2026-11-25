import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/measure/decibel_meter.dart';
import 'package:toolbox/features/tools/measure/measure_geometry.dart';
import 'package:toolbox/features/tools/measure/measure_page.dart';
import '../../support/test_env.dart';

/// 假采集：不碰麦克风插件，按时推送构造好的 PCM16 数据。
class _FakeCapture implements AudioCapture {
  _FakeCapture({this.granted = true});

  final bool granted;
  final List<Uint8List> chunks = <Uint8List>[];
  bool started = false;
  bool stopped = false;

  @override
  Future<bool> ensurePermission() async => granted;

  @override
  Future<Stream<Uint8List>> startStream() async {
    started = true;
    return Stream<Uint8List>.fromIterable(chunks);
  }

  @override
  Future<void> stop() async => stopped = true;

  @override
  Future<void> dispose() async {}
}

Uint8List _pcm(int samples, double amplitude) {
  final data = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    data.setInt16(i * 2, (amplitude * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  installCleanEnv();

  group('尺子校准', () {
    test('未校准时使用名义值 63 像素/厘米', () async {
      expect(await MeasureGeometry.loadPxPerCm(),
          closeTo(MeasureGeometry.nominalPxPerCm, 1e-9));
      expect(MeasureGeometry.nominalPxPerCm, closeTo(62.99, 0.01));
    });

    test('保存后读回，并限制在合理区间', () async {
      await MeasureGeometry.savePxPerCm(58.4);
      expect(await MeasureGeometry.loadPxPerCm(), closeTo(58.4, 1e-9));

      await MeasureGeometry.savePxPerCm(10);
      expect(await MeasureGeometry.loadPxPerCm(),
          MeasureGeometry.minPxPerCm);
      await MeasureGeometry.savePxPerCm(500);
      expect(await MeasureGeometry.loadPxPerCm(),
          MeasureGeometry.maxPxPerCm);
    });

    test('像素与厘米互换对称', () {
      const pxPerCm = 60.0;
      expect(MeasureGeometry.cmToPx(2.5, pxPerCm), 150);
      expect(MeasureGeometry.pxToCm(150, pxPerCm), 2.5);
      expect(MeasureGeometry.visibleWidthCm(420, pxPerCm), 7);
    });

    test('长度格式化：10cm 以内保留两位', () {
      expect(MeasureGeometry.formatCm(3.456), '3.46');
      expect(MeasureGeometry.formatCm(12.34), '12.3');
      expect(MeasureGeometry.formatMm(3.46), '35');
      expect(MeasureGeometry.formatCm(-1), '0.00');
    });
  });

  group('量角器角度', () {
    const pivot = Offset(100, 100);

    test('右侧为 0°、正上为 90°、左侧为 180°', () {
      expect(MeasureGeometry.angleFromPoint(pivot, const Offset(200, 100)),
          closeTo(0, 1e-9));
      expect(MeasureGeometry.angleFromPoint(pivot, const Offset(100, 0)),
          closeTo(90, 1e-9));
      expect(MeasureGeometry.angleFromPoint(pivot, const Offset(0, 100)),
          closeTo(180, 1e-9));
    });

    test('半圆下方的点按边界值处理', () {
      expect(MeasureGeometry.angleFromPoint(pivot, const Offset(200, 200)), 0);
      expect(MeasureGeometry.angleFromPoint(pivot, const Offset(0, 200)), 180);
      expect(MeasureGeometry.angleFromPoint(pivot, pivot), 0);
    });

    test('吸附到 0.5°', () {
      expect(MeasureGeometry.snapAngle(44.7), 44.5);
      expect(MeasureGeometry.snapAngle(44.8), 45.0);
      expect(MeasureGeometry.snapAngle(-0.2), 0);
    });
  });

  group('分贝分析', () {
    test('静音为 -100dB，满量程为 0dB', () {
      expect(DecibelAnalyzer.dbfsFromRms(0), -100);
      expect(DecibelAnalyzer.dbfsFromRms(32768), closeTo(0, 1e-9));
      expect(DecibelAnalyzer.dbfsFromRms(3276.8), closeTo(-20, 1e-3));
    });

    test('PCM16 均方根按幅值换算', () {
      final silence = _pcm(64, 0);
      expect(DecibelAnalyzer.rmsOfPcm16(silence), 0);

      final loud = _pcm(64, 0.5);
      expect(DecibelAnalyzer.rmsOfPcm16(loud), closeTo(16384, 2));
    });

    test('处理短于 2 个采样的数据返回 null', () {
      expect(DecibelAnalyzer().process(Uint8List(2)), isNull);
    });

    test('偏移决定估算声压级，并记录峰值/平均', () {
      final analyzer = DecibelAnalyzer(offsetDb: 94);
      final frame = analyzer.process(_pcm(256, 0.5));
      expect(frame, isNotNull);
      // 0.5 幅值 → RMS ≈ 0.5 → dBFS ≈ -6dB → 估算约 88dB
      expect(frame!.spl, closeTo(88, 1));
      expect(frame.peak, closeTo(frame.spl, 1));
      expect(frame.average, closeTo(frame.spl, 1));
      expect(frame.level, inInclusiveRange(0, 1));
    });

    test('变响时上升快、变轻时下降慢（平滑）', () {
      final analyzer = DecibelAnalyzer(offsetDb: 94);
      final first = analyzer.process(_pcm(64, 0.01))!;
      final loud = analyzer.process(_pcm(64, 0.8))!;
      final quiet = analyzer.process(_pcm(64, 0.0001))!;
      // 突然变响：一帧就抬高 15dB 以上；突然变轻：只回落一部分，仍高于最初。
      expect(loud.spl, greaterThan(first.spl + 15));
      expect(quiet.spl, greaterThan(first.spl));
      expect(quiet.spl, lessThan(loud.spl));
    });

    test('音量分级阈值', () {
      expect(DecibelAnalyzer.zoneOf(30), DecibelZone.quiet);
      expect(DecibelAnalyzer.zoneOf(50), DecibelZone.normal);
      expect(DecibelAnalyzer.zoneOf(70), DecibelZone.loud);
      expect(DecibelAnalyzer.zoneOf(80), DecibelZone.noisy);
      expect(DecibelAnalyzer.zoneOf(95), DecibelZone.dangerous);
    });
  });

  group('分贝控制器', () {
    test('采集到数据后推送读数', () async {
      final capture = _FakeCapture()
        ..chunks.addAll(<Uint8List>[
          _pcm(128, 0.3),
          _pcm(128, 0.6),
        ]);
      final controller = DecibelController(capture: capture);
      expect(controller.running, isFalse);

      await controller.start();
      expect(capture.started, isTrue);
      expect(controller.running, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.frame, isNotNull);
      expect(controller.frame!.spl, greaterThan(60));

      await controller.stop();
      expect(capture.stopped, isTrue);
      expect(controller.running, isFalse);
      controller.dispose();
    });

    test('未授权时给出 permission 标记', () async {
      final controller = DecibelController(capture: _FakeCapture(granted: false));
      await controller.start();
      expect(controller.running, isFalse);
      expect(controller.error, 'permission');
      controller.dispose();
    });

    test('插件缺失（抛异常）也不会崩溃', () async {
      final controller = DecibelController(capture: _ThrowingCapture());
      await controller.start();
      expect(controller.running, isFalse);
      expect(controller.error, isNotNull);
      controller.dispose();
    });
  });

  group('测量工具页面', () {
    testWidgets('四个分页都在，尺子页显示 A→B 读数', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MeasurePage(
          initialPxPerCm: 63,
          decibelController: DecibelController(capture: _FakeCapture()),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('尺子'), findsOneWidget);
      expect(find.text('量角器'), findsOneWidget);
      expect(find.text('分贝仪'), findsOneWidget);
      expect(find.text('光强计'), findsOneWidget);
      expect(find.text('A → B 距离'), findsOneWidget);
      // 默认 A=0.5cm、B=4.0cm → 3.5cm
      expect(find.text('3.50'), findsOneWidget);
      expect(find.text('35 mm'), findsOneWidget);
    });

    testWidgets('切到量角器可预设 90°', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MeasurePage(
          initialPxPerCm: 63,
          decibelController: DecibelController(capture: _FakeCapture()),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('量角器'));
      await tester.pumpAndSettle();
      expect(find.text('45.0'), findsOneWidget);
      await tester.tap(find.text('90°').first);
      await tester.pumpAndSettle();
      expect(find.text('90.0'), findsOneWidget);
      expect(find.textContaining('补角'), findsOneWidget);
    });

    testWidgets('切到分贝仪显示环境音量并可开始测量', (tester) async {
      final capture = _FakeCapture()..chunks.add(_pcm(128, 0.4));
      final controller = DecibelController(capture: capture);
      await tester.pumpWidget(MaterialApp(
        home: MeasurePage(
          initialPxPerCm: 63,
          decibelController: controller,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('分贝仪'));
      await tester.pumpAndSettle();
      expect(find.text('环境音量'), findsOneWidget);
      expect(find.text('开始测量'), findsOneWidget);

      await tester.tap(find.text('开始测量'));
      await tester.pump();
      await tester.pump();
      expect(capture.started, isTrue);
      // fake-async 下 cancel 的 Future 不会自己完成，必须放到真实事件循环里等。
      await tester.runAsync(() => controller.stop());
    });
  });

  group('量角器拖动', () {
    RenderBox canvasBoxOf(WidgetTester tester) =>
        tester.renderObject<RenderBox>(
            find.byKey(const ValueKey('protractor-canvas')));

    Text? angleTextOf(WidgetTester tester) {
      final matches = tester
          .widgetList<Text>(find.byWidgetPredicate((w) =>
              w is Text &&
              RegExp(r'^\d+\.\d$').hasMatch(w.data ?? '')))
          .toList();
      return matches.isEmpty ? null : matches.first;
    }

    testWidgets('按下即跟随：极小位移也会更新角度（无启动阈值）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MeasurePage(
          initialPxPerCm: 63,
          decibelController: DecibelController(capture: _FakeCapture()),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('量角器'));
      await tester.pumpAndSettle();

      final canvas = canvasBoxOf(tester);
      final size = canvas.size;
      final pivot = Offset(size.width / 2, size.height - 48);
      final radius = (size.width / 2 - 12).clamp(0.0, pivot.dy - 12);
      // 从 0° 一侧（基线右段）起拖，纵向移动 6px。
      final startGlobal =
          canvas.localToGlobal(pivot + Offset(radius * 0.6, 0));
      final gesture = await tester.startGesture(startGlobal);
      await gesture.moveBy(const Offset(0, -6));
      await tester.pump();

      final text1 = angleTextOf(tester);
      expect(text1, isNotNull);
      expect(text1!.data, isNot('45.0'), reason: '6px 位移就应改变角度');

      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      final text2 = angleTextOf(tester)!;
      expect(text2.data, isNot(text1.data), reason: '继续拖动角度持续跟随');
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('全屏模式', () {
    testWidgets('尺子进入全屏：隐藏标题栏，出现退出按钮，退出后恢复', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MeasurePage(
          initialPxPerCm: 63,
          decibelController: DecibelController(capture: _FakeCapture()),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('测量工具'), findsOneWidget);

      // 尺子卡片行里的全屏按钮。
      await tester.tap(find.byKey(const ValueKey('ruler-fullscreen-btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('measure-exit-fullscreen')), findsOneWidget);
      expect(find.byKey(const ValueKey('ruler-fullscreen-cm')), findsOneWidget);
      expect(find.text('测量工具'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('measure-exit-fullscreen')));
      await tester.pumpAndSettle();
      expect(find.text('测量工具'), findsOneWidget);
      expect(find.text('A → B 距离'), findsOneWidget);
    });

    testWidgets('量角器进入全屏并显示角度读数', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MeasurePage(
          initialPxPerCm: 63,
          decibelController: DecibelController(capture: _FakeCapture()),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('量角器'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('protractor-fullscreen-btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('measure-exit-fullscreen')), findsOneWidget);
      expect(find.textContaining('补角'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('measure-exit-fullscreen')));
      await tester.pumpAndSettle();
      expect(find.text('测量工具'), findsOneWidget);
    });
  });
}

class _ThrowingCapture implements AudioCapture {
  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<Stream<Uint8List>> startStream() async =>
      throw StateError('MissingPluginException');

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
