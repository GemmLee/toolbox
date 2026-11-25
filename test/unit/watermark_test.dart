import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/watermark/watermark_engine.dart';
import 'package:toolbox/features/tools/watermark/watermark_page.dart';
import '../support/test_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  installCleanEnv();

  group('水印引擎 · 平铺落点', () {
    test('默认参数下能铺满整图', () {
      final positions = computeTilePositions(
        size: const Size(1000, 800),
        itemSize: const Size(120, 40),
        density: 1.0,
        angleDeg: -30,
      );
      expect(positions, isNotEmpty);
      // 覆盖四个角落附近：至少各有一个落点在边缘 150px 内。
      bool near(double px, double py, {double tol = 220}) => positions
          .any((p) => (p.dx - px).abs() < tol && (p.dy - py).abs() < tol);
      expect(near(0, 0), isTrue, reason: '左上角应有落点');
      expect(near(1000, 0), isTrue, reason: '右上角应有落点');
      expect(near(0, 800), isTrue, reason: '左下角应有落点');
      expect(near(1000, 800), isTrue, reason: '右下角应有落点');
    });

    test('密度越大落点越少', () {
      final dense = computeTilePositions(
        size: const Size(1000, 800),
        itemSize: const Size(120, 40),
        density: 0.4,
        angleDeg: -30,
      );
      final sparse = computeTilePositions(
        size: const Size(1000, 800),
        itemSize: const Size(120, 40),
        density: 2.5,
        angleDeg: -30,
      );
      expect(dense.length, greaterThan(sparse.length));
    });

    test('旋转 45° 与 -45° 落点数一致（对称）', () {
      final cw = computeTilePositions(
        size: const Size(600, 900),
        itemSize: const Size(100, 36),
        density: 1.0,
        angleDeg: 45,
      );
      final ccw = computeTilePositions(
        size: const Size(600, 900),
        itemSize: const Size(100, 36),
        density: 1.0,
        angleDeg: -45,
      );
      expect(cw.length, closeTo(ccw.length, 2),
          reason: '±45° 互为镜像，落点数应基本一致（浮点边界可有 ±1 差异）');
    });

    test('落点带边距约束：不会离图太远', () {
      final positions = computeTilePositions(
        size: const Size(800, 600),
        itemSize: const Size(100, 40),
        density: 1.2,
        angleDeg: 20,
      );
      // 引擎的边距 = itemSize 最长边 100。
      for (final p in positions) {
        expect(p.dx, inInclusiveRange(-100, 900));
        expect(p.dy, inInclusiveRange(-100, 700));
      }
    });
  });

  group('水印引擎 · 样式', () {
    test('copyWith 保留未修改字段', () {
      const s = WatermarkSettings(text: 'abc');
      final s2 = s.copyWith(opacity: 0.8, type: WatermarkType.corner);
      expect(s2.text, 'abc');
      expect(s2.opacity, 0.8);
      expect(s2.type, WatermarkType.corner);
      expect(s2.sizeFactor, s.sizeFactor);
      expect(s2.angleDeg, s.angleDeg);
      expect(s2.darkText, isFalse);
      expect(s2.fontFamily, isNull);

      final s3 = s.copyWith(fontFamily: 'wm_user_123');
      expect(s3.fontFamily, 'wm_user_123');
      expect(s3.text, 'abc');
    });

    test('copyWith 可更新多行字段、角落位置与描边', () {
      const s = WatermarkSettings(text: 'abc');
      final rows = <WatermarkRow>[
        const WatermarkRow(
          id: 'r1',
          items: <WatermarkItem>[
            WatermarkItem(field: WatermarkField.date),
            WatermarkItem(field: WatermarkField.time),
          ],
        ),
      ];
      final s2 = s.copyWith(
        rows: rows,
        corner: WatermarkCorner.topLeft,
        outline: true,
      );
      expect(s2.rows, hasLength(1));
      expect(s2.rows.first.items, hasLength(2));
      expect(s2.corner, WatermarkCorner.topLeft);
      expect(s2.outline, isTrue);
      expect(s.rows, isEmpty, reason: '原对象不被修改');
    });
  });

  group('水印引擎 · 实时字段', () {
    final snapshot = WatermarkSnapshot(
      dateTime: DateTime(2026, 11, 22, 9, 5),
      temperature: 23.46,
      altitude: 88.7,
      latitude: 30.27415,
      longitude: 120.15519,
    );

    test('各字段按快照解析为文本', () {
      expect(const WatermarkItem(field: WatermarkField.date).resolve(snapshot),
          '2026-11-22');
      expect(const WatermarkItem(field: WatermarkField.time).resolve(snapshot),
          '09:05');
      expect(
          const WatermarkItem(field: WatermarkField.temperature)
              .resolve(snapshot),
          '23.5°C');
      expect(
          const WatermarkItem(field: WatermarkField.altitude).resolve(snapshot),
          '海拔 89m');
      expect(const WatermarkItem(field: WatermarkField.geo).resolve(snapshot),
          '30.27415°N 120.15519°E');
      expect(
          const WatermarkItem(field: WatermarkField.custom, customText: ' 内部 ')
              .resolve(snapshot),
          '内部');
    });

    test('缺失数据字段解析为空串，渲染时跳过', () {
      const empty = WatermarkSnapshot();
      expect(
          const WatermarkItem(field: WatermarkField.date).resolve(empty), '');
      expect(
          const WatermarkItem(field: WatermarkField.temperature).resolve(empty),
          '');
    });

    test('一行内多个字段用竖线连接，缺失字段自动跳过', () {
      const row = WatermarkRow(
        id: 'r1',
        items: <WatermarkItem>[
          WatermarkItem(field: WatermarkField.date),
          WatermarkItem(field: WatermarkField.time),
        ],
      );
      expect(resolveWatermarkRow(row, snapshot), '2026-11-22 | 09:05');

      const withGeo = WatermarkRow(
        id: 'r2',
        items: <WatermarkItem>[
          WatermarkItem(field: WatermarkField.geo),
          WatermarkItem(field: WatermarkField.altitude),
        ],
      );
      expect(resolveWatermarkRow(withGeo, snapshot),
          '30.27415°N 120.15519°E | 海拔 89m');

      // 没取到定位时 geo 行被跳过，只剩海拔。
      expect(
          resolveWatermarkRow(
              withGeo,
              WatermarkSnapshot(
                dateTime: snapshot.dateTime,
                altitude: snapshot.altitude,
              )),
          '海拔 89m');
    });

    test('角落位置计算：四角各自的原点', () {
      const size = Size(1000, 800);
      const block = Size(200, 60);
      final tl = computeCornerOrigin(size, block, WatermarkCorner.topLeft);
      final br = computeCornerOrigin(size, block, WatermarkCorner.bottomRight);
      expect(tl.dx, lessThan(100));
      expect(tl.dy, lessThan(100));
      expect(br.dx, greaterThan(700));
      expect(br.dy, greaterThan(700));
    });
  });

  group('水印页面', () {
    testWidgets('未选图时提示选图，保存按钮不可用', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WatermarkPage()));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('wm-pick')), findsOneWidget);
      expect(find.text('先选择一张照片'), findsOneWidget);
      expect(find.byKey(const ValueKey('wm-font-import')), findsOneWidget);
      expect(find.byKey(const ValueKey('wm-font-default')), findsOneWidget);

      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('wm-save')),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('输入文字后可切换版式；角落版式没有密度滑块', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WatermarkPage()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('wm-text')), '测试水印');
      await tester.pumpAndSettle();

      // 默认平铺：有密度滑块。
      expect(find.byKey(const ValueKey('wm-density')), findsOneWidget);

      await tester.tap(find.text('角落'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('wm-density')), findsNothing);
      expect(find.byKey(const ValueKey('wm-size')), findsOneWidget);
      expect(find.byKey(const ValueKey('wm-angle')), findsOneWidget);
      expect(find.byKey(const ValueKey('wm-opacity')), findsOneWidget);
    });

    test('长按换位：字段按 3×2 模板顺序移动，空槽也可作为目标', () {
      final slots = <WatermarkItem?>[
        const WatermarkItem(field: WatermarkField.date, id: 'd'),
        const WatermarkItem(field: WatermarkField.time, id: 't'),
        null,
        null,
        null,
        null,
      ];
      final moved = reorderWatermarkSlot(slots, 0, 2);
      expect(moved[0]!.field, WatermarkField.time);
      expect(moved[1], isNull);
      expect(moved[2]!.field, WatermarkField.date);
      expect(slots[0]!.field, WatermarkField.date, reason: '原数组不被修改');
    });

    testWidgets('有拍照按钮；角落版式为默认三行两列，点击槽位选字段', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WatermarkPage()));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('wm-camera')), findsOneWidget);
      expect(find.text('拍照水印'), findsOneWidget);

      await tester.tap(find.text('角落'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('wm-field-list')), findsOneWidget);
      for (var i = 0; i < 6; i++) {
        expect(find.byKey(ValueKey('wm-slot-$i')), findsOneWidget);
      }

      Future<void> fillSlot(int index, String field) async {
        final cell = find.byKey(ValueKey('wm-slot-$index'));
        await tester.ensureVisible(cell);
        await tester.pumpAndSettle();
        await tester.tap(cell);
        await tester.pumpAndSettle();
        final option = find.byKey(ValueKey('wm-slot-$index-$field'));
        expect(option, findsOneWidget);
        await tester.tap(option);
        await tester.pumpAndSettle();
      }

      // 第一行：日期 | 时间；第二行：经纬度 | 海拔。
      await fillSlot(0, 'WatermarkField.date');
      await fillSlot(1, 'WatermarkField.time');
      await fillSlot(2, 'WatermarkField.geo');
      await fillSlot(3, 'WatermarkField.altitude');
      expect(find.text('日期'), findsOneWidget);
      expect(find.text('时间'), findsOneWidget);
      expect(find.text('经纬度'), findsOneWidget);
      expect(find.text('海拔'), findsOneWidget);

      // 自定义槽直接显示上方「水印文字」，不再单独输入。
      await tester.enterText(find.byKey(const ValueKey('wm-text')), '内部资料');
      await tester.pumpAndSettle();
      await fillSlot(4, 'WatermarkField.custom');
      expect(find.text('内部资料'), findsWidgets);

      // 已填槽位可清空。
      final cell = find.byKey(const ValueKey('wm-slot-0'));
      await tester.ensureVisible(cell);
      await tester.pumpAndSettle();
      await tester.tap(cell);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wm-slot-0-clear')));
      await tester.pumpAndSettle();
      expect(find.text('日期'), findsNothing);
      expect(find.byKey(const ValueKey('wm-slot-0')), findsOneWidget);
    });

    testWidgets('描边开关可切换', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WatermarkPage()));
      await tester.pumpAndSettle();

      const key = ValueKey('wm-outline');
      await tester.ensureVisible(find.byKey(key));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byKey(key)).value, isFalse);
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byKey(key)).value, isTrue);
    });
  });

  group('水印渲染', () {
    testWidgets('平铺渲染整图并导出 PNG 字节', (tester) async {
      ui.Image? source;
      ui.Image? rendered;
      await tester.runAsync(() async {
        // 造一张 200x120 的纯色底图。
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 200, 120),
          Paint()..color = const Color(0xFF336699),
        );
        source = await recorder.endRecording().toImage(200, 120);

        rendered = await renderWatermarked(
          source!,
          const WatermarkSettings(text: '水印', density: 0.6, sizeFactor: 0.08),
        );
      });

      expect(source, isNotNull);
      expect(rendered, isNotNull);
      expect(rendered!.width, 200);
      expect(rendered!.height, 120);

      final bytes = await tester.runAsync(
        () => rendered!.toByteData(format: ui.ImageByteFormat.png),
      );
      expect(bytes, isNotNull);
      expect(bytes!.lengthInBytes, greaterThan(1000));
    });

    testWidgets('开启描边后渲染结果不同于关闭', (tester) async {
      ui.Image? source;
      ui.Image? plain;
      ui.Image? outlined;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 300, 160),
          Paint()..color = const Color(0xFF808080),
        );
        source = await recorder.endRecording().toImage(300, 160);

        const settings = WatermarkSettings(
          text: '水印',
          type: WatermarkType.center,
          sizeFactor: 0.12,
          opacity: 1,
        );
        plain = await renderWatermarked(source!, settings);
        outlined =
            await renderWatermarked(source!, settings.copyWith(outline: true));
      });

      final a = await tester.runAsync(
        () => plain!.toByteData(format: ui.ImageByteFormat.png),
      );
      final b = await tester.runAsync(
        () => outlined!.toByteData(format: ui.ImageByteFormat.png),
      );
      expect(a, isNotNull);
      expect(b, isNotNull);
      Uint8List bytesOf(ByteData data) =>
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      expect(bytesOf(a!), isNot(bytesOf(b!)));
    });
  });
}
