import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:toolbox/features/tools/typhoon/typhoon_api.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_geo.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_map.dart';

void main() {
  group('projectLngLat', () {
    const rect = Rect.fromLTWH(10, 20, 200, 100);

    test('左上角（最小经度、最大纬度）', () {
      final o = projectLngLat(104, 42, rect);
      expect(o.dx, closeTo(rect.left, 0.001));
      expect(o.dy, closeTo(rect.top, 0.001));
    });

    test('右下角（最大经度、最小纬度）', () {
      final o = projectLngLat(140, 16, rect);
      expect(o.dx, closeTo(rect.right, 0.001));
      expect(o.dy, closeTo(rect.bottom, 0.001));
    });

    test('中心经纬度落在矩形中部', () {
      final o = projectLngLat(122, 29, rect);
      expect(o.dx, greaterThan(rect.left));
      expect(o.dx, lessThan(rect.right));
      expect(o.dy, greaterThan(rect.top));
      expect(o.dy, lessThan(rect.bottom));
    });
  });

  group('formatMonthDay', () {
    test('标准时间串取月/日', () {
      expect(formatMonthDay('2026-02-05 06:30:00'), '02/05');
      expect(formatMonthDay('2026-11-30 23:59:00'), '11/30');
    });

    test('空串与异常格式返回空', () {
      expect(formatMonthDay(''), isEmpty);
      expect(formatMonthDay('   '), isEmpty);
      expect(formatMonthDay('2026-02'), isEmpty);
    });
  });

  group('MapView 缩放视图', () {
    test('基准视图即完整范围', () {
      expect(MapView.base.minLng, 104);
      expect(MapView.base.maxLng, 140);
      expect(MapView.base.minLat, 16);
      expect(MapView.base.maxLat, 42);
    });

    test('放大后跨度变小', () {
      const zoomed = MapView(minLng: 117, maxLng: 127, minLat: 24, maxLat: 34);
      expect(
        zoomed.maxLng - zoomed.minLng,
        lessThan(MapView.base.maxLng - MapView.base.minLng),
      );
    });

    test('放大后同一经纬度投影结果不同', () {
      const rect = Rect.fromLTWH(0, 0, 200, 100);
      // 注意：该视图中心为 (120E, 31N)，与基准视图中心 (122E, 29N) 不同
      const zoomed = MapView(minLng: 115, maxLng: 125, minLat: 26, maxLat: 36);
      final a = MapView.base.project(122, 29, rect);
      final b = zoomed.project(122, 29, rect);
      expect(a, isNot(b));
      // 放大后该点（122E, 29N）仍落在画布内
      expect(b.dx, greaterThan(0));
      expect(b.dx, lessThan(200));
      expect(b.dy, greaterThan(0));
      expect(b.dy, lessThan(100));
    });
  });

  group('离线地理数据（生成于 typhoon_geo_data.dart）', () {
    /// 某个环的外接矩形是否完整覆盖给定范围。
    bool coversRange(
      List<List<double>> ring,
      double lng0,
      double lat0,
      double lng1,
      double lat1,
    ) {
      final xs = ring.map((p) => p[0]);
      final ys = ring.map((p) => p[1]);
      return xs.reduce(math.min) <= lng0 &&
          xs.reduce(math.max) >= lng1 &&
          ys.reduce(math.min) <= lat0 &&
          ys.reduce(math.max) >= lat1;
    }

    test('中国陆地环非空，且包含台湾与海南', () {
      expect(chinaLandRings, isNotEmpty);
      // 台湾（中国）与海南（中国）必须有环覆盖其范围
      expect(
        chinaLandRings.any((r) => coversRange(r, 120.2, 22.0, 121.8, 25.1)),
        isTrue,
        reason: '台湾岛缺失',
      );
      expect(
        chinaLandRings.any((r) => coversRange(r, 108.8, 18.3, 110.8, 20.0)),
        isTrue,
        reason: '海南岛缺失',
      );
    });

    test('周边国家环非空，且包含日本九州-本州区域', () {
      expect(neighborLandRings, isNotEmpty);
      final hasJapan = neighborLandRings
          .any((r) => coversRange(r, 131, 33.5, 139, 36));
      expect(hasJapan, isTrue, reason: '日本轮廓缺失');
    });

    test('省界折线数量充足且全部落在示意图范围内', () {
      // 34 个省级单位相邻边界应有大量折线段
      expect(chinaProvinceBorders.length, greaterThan(20));
      for (final pl in chinaProvinceBorders) {
        expect(pl.length, greaterThanOrEqualTo(2));
        for (final p in pl) {
          expect(p[0], inInclusiveRange(kMapMinLng - 0.01, kMapMaxLng + 0.01));
          expect(p[1], inInclusiveRange(kMapMinLat - 0.01, kMapMaxLat + 0.01));
        }
      }
    });

    test('陆地环与邻国环的顶点均落在示意图范围内', () {
      for (final rings in <List<List<List<double>>>>[
        chinaLandRings,
        neighborLandRings,
      ]) {
        for (final ring in rings) {
          for (final p in ring) {
            expect(
              p[0],
              inInclusiveRange(kMapMinLng - 0.01, kMapMaxLng + 0.01),
            );
            expect(
              p[1],
              inInclusiveRange(kMapMinLat - 0.01, kMapMaxLat + 0.01),
            );
          }
        }
      }
    });
  });

  group('入图判定（示意图范围 104–140°E / 16–42°N）', () {
    test('浙江近海点在图内', () {
      expect(pointInMap(121.4, 28.6), isTrue);
    });

    test('远洋点不在图内', () {
      expect(pointInMap(158, 20), isFalse);
      expect(pointInMap(120, 45), isFalse);
    });

    test('路径任一点入图即判为靠近', () {
      final pts = <TrackPoint>[
        const TrackPoint(time: '2026-01-01 08:00:00', lng: 158, lat: 20),
        const TrackPoint(time: '2026-01-02 08:00:00', lng: 128, lat: 22),
      ];
      expect(trackInMap(pts, const <Landing>[]), isTrue);
    });

    test('全程在图外则不判为靠近', () {
      final pts = <TrackPoint>[
        const TrackPoint(time: '2026-01-01 08:00:00', lng: 158, lat: 20),
        const TrackPoint(time: '2026-01-02 08:00:00', lng: 165, lat: 24),
      ];
      expect(trackInMap(pts, const <Landing>[]), isFalse);
    });

    test('登陆点在图内也算靠近', () {
      const land = <Landing>[
        Landing(
          address: '广东省阳江市沿海',
          time: '2026-01-01 08:00:00',
          lng: 111.8,
          lat: 21.8,
        ),
      ];
      expect(trackInMap(const <TrackPoint>[], land), isTrue);
    });

    test('仅当前中心在图内也算靠近', () {
      expect(
        trackInMap(const <TrackPoint>[], const <Landing>[],
            centerLng: 122, centerLat: 25),
        isTrue,
      );
    });

    test('空数据不判为靠近', () {
      expect(
        trackInMap(const <TrackPoint>[], const <Landing>[]),
        isFalse,
      );
    });
  });

  group('强度解析与配色', () {
    test('中文强度文本映射', () {
      expect(parseStrength('热带低压'), TyphoonStrength.tropicalDepression);
      expect(parseStrength('热带风暴'), TyphoonStrength.tropicalStorm);
      expect(parseStrength('强热带风暴'), TyphoonStrength.severeTropicalStorm);
      expect(parseStrength('台风'), TyphoonStrength.typhoon);
      expect(parseStrength('台风级'), TyphoonStrength.typhoon);
    });

    test('超强台风不被「台风」提前命中', () {
      expect(parseStrength('超强台风'), TyphoonStrength.superTyphoon);
      expect(parseStrength('强台风'), TyphoonStrength.severeTyphoon);
    });

    test('空值与未知文本归为未知强度', () {
      expect(parseStrength(null), TyphoonStrength.unknown);
      expect(parseStrength('  '), TyphoonStrength.unknown);
      expect(parseStrength('温带气旋'), TyphoonStrength.unknown);
    });

    test('各强度配色互不相同', () {
      final colors = <Color>{
        for (final s in kLegendStrengths) typhoonStrengthColor(s),
      };
      expect(colors.length, kLegendStrengths.length);
    });

    test('深色模式使用另一套配色', () {
      expect(
        typhoonStrengthColor(TyphoonStrength.typhoon, dark: true),
        isNot(typhoonStrengthColor(TyphoonStrength.typhoon)),
      );
    });
  });

  group('TyphoonMapPainter', () {
    final points = <TrackPoint>[
      const TrackPoint(time: '2026-02-01 08:00:00', lng: 130, lat: 20),
      const TrackPoint(time: '2026-02-02 08:00:00', lng: 125, lat: 24),
      const TrackPoint(time: '2026-02-03 08:00:00', lng: 121, lat: 28),
    ];
    final land = <Landing>[
      const Landing(
          address: '浙江', time: '2026-02-03 12:00:00', lng: 121.5, lat: 29),
    ];

    void expectPaint(TyphoonMapPainter painter) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      expect(
        () => painter.paint(canvas, const Size(300, 320)),
        returnsNormally,
      );
      recorder.endRecording().dispose();
    }

    test('绘制不抛异常（含路径/中心/登陆点）', () {
      expectPaint(TyphoonMapPainter(
        points: points,
        centerLng: 121,
        centerLat: 28,
        land: land,
      ));
    });

    test('无数据时不抛异常', () {
      expectPaint(TyphoonMapPainter(points: const <TrackPoint>[]));
    });

    // 已停编的台风没有当前中心，但路径仍要画出来
    test('停编台风：无中心但有路径时仍绘制', () {
      expectPaint(TyphoonMapPainter(points: points));
    });

    test('放大视图绘制不抛异常', () {
      expectPaint(TyphoonMapPainter(
        points: points,
        centerLng: 121.5,
        centerLat: 29,
        land: land,
        view: const MapView(minLng: 117, maxLng: 127, minLat: 24, maxLat: 34),
      ));
    });

    test('深色模式绘制不抛异常', () {
      expectPaint(TyphoonMapPainter(
        points: points,
        centerLng: 121,
        centerLat: 28,
        isDark: true,
      ));
    });

    test('按强度着色的多色路径绘制不抛异常', () {
      expectPaint(TyphoonMapPainter(
        points: <TrackPoint>[
          const TrackPoint(
              time: '2026-01-01 08:00:00', lng: 130, lat: 20, strong: '热带低压'),
          const TrackPoint(
              time: '2026-01-02 08:00:00', lng: 125, lat: 24, strong: '强热带风暴'),
          const TrackPoint(
              time: '2026-01-03 08:00:00', lng: 121, lat: 28, strong: '超强台风'),
          const TrackPoint(time: '2026-01-04 08:00:00', lng: 120, lat: 30),
        ],
      ));
    });
  });

  group('TyphoonMap widget', () {
    testWidgets('可构建并显示 CustomPaint', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: TyphoonMap(
                points: <TrackPoint>[
                  TrackPoint(time: '2026-02-01 08:00:00', lng: 128, lat: 22),
                  TrackPoint(time: '2026-02-02 08:00:00', lng: 122, lat: 27),
                ],
                centerLng: 122,
                centerLat: 27,
              ),
            ),
          ),
        ),
      );
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('缩放控件：默认 1.0×，放大后出现复位', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: TyphoonMap(
                points: <TrackPoint>[
                  TrackPoint(time: '2026-02-01 08:00:00', lng: 128, lat: 22),
                  TrackPoint(time: '2026-02-05 08:00:00', lng: 122, lat: 27),
                ],
                centerLng: 122,
                centerLat: 27,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1.0×'), findsOneWidget);
      expect(find.byKey(const ValueKey('typhoon-map-zoom-reset')),
          findsNothing);

      // 放大一档
      await tester.tap(find.byKey(const ValueKey('typhoon-map-zoom-in')));
      await tester.pumpAndSettle();
      expect(find.text('1.5×'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('typhoon-map-zoom-reset')), findsOneWidget);

      // 复位
      await tester.tap(find.byKey(const ValueKey('typhoon-map-zoom-reset')));
      await tester.pumpAndSettle();
      expect(find.text('1.0×'), findsOneWidget);
      expect(find.byKey(const ValueKey('typhoon-map-zoom-reset')),
          findsNothing);
    });

    testWidgets('放大后拖拽平移改变视图，复位恢复基准', (tester) async {
      MapView? last;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: TyphoonMap(
                points: const <TrackPoint>[
                  TrackPoint(time: '2026-02-01 08:00:00', lng: 128, lat: 22),
                  TrackPoint(time: '2026-02-05 08:00:00', lng: 122, lat: 27),
                ],
                centerLng: 122,
                centerLat: 27,
                onViewChanged: (v) => last = v,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 放大后才启用拖拽平移
      await tester.tap(find.byKey(const ValueKey('typhoon-map-zoom-in')));
      await tester.pumpAndSettle();
      final zoomed = last!;
      expect(zoomed.maxLng - zoomed.minLng, lessThan(36));

      await tester.drag(
          find.byKey(const ValueKey('typhoon-map-canvas')),
          const Offset(-60, 0));
      await tester.pumpAndSettle();
      expect(last!.minLng, isNot(closeTo(zoomed.minLng, 0.0001)));

      // 复位同时清除缩放与平移
      await tester.tap(find.byKey(const ValueKey('typhoon-map-zoom-reset')));
      await tester.pumpAndSettle();
      expect(last!.minLng, closeTo(MapView.base.minLng, 0.0001));
      expect(last!.maxLng, closeTo(MapView.base.maxLng, 0.0001));
    });

    testWidgets('双指捏合：张开放大、合拢缩小，以捏合中心为锚点', (tester) async {
      MapView? last;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: TyphoonMap(
                points: const <TrackPoint>[
                  TrackPoint(time: '2026-02-01 08:00:00', lng: 128, lat: 22),
                  TrackPoint(time: '2026-02-05 08:00:00', lng: 122, lat: 27),
                ],
                centerLng: 122,
                centerLat: 27,
                onViewChanged: (v) => last = v,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final canvas = find.byKey(const ValueKey('typhoon-map-canvas'));
      final center = tester.getCenter(canvas);
      final p1 = await tester.startGesture(center - const Offset(40, 0));
      final p2 = await tester.startGesture(center + const Offset(40, 0));
      await tester.pump();

      // 张开双指：跨度 80 → 140，缩放比例 > 1
      await p1.moveBy(const Offset(-30, 0));
      await p2.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(last, isNotNull);
      final zoomedSpan = last!.maxLng - last!.minLng;
      expect(zoomedSpan, lessThan(36));

      // 合拢双指：缩回基准视图
      await p1.moveBy(const Offset(30, 0));
      await p2.moveBy(const Offset(-30, 0));
      await tester.pump();
      expect(last!.maxLng - last!.minLng, greaterThan(zoomedSpan));

      await p1.up();
      await p2.up();
      await tester.pumpAndSettle();
    });

    testWidgets('地图内拖动被吃下，不会带动外层页面滚动', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: const <Widget>[
                TyphoonMap(
                  points: <TrackPoint>[
                    TrackPoint(time: '2026-02-01 08:00:00', lng: 128, lat: 22),
                    TrackPoint(time: '2026-02-05 08:00:00', lng: 122, lat: 27),
                  ],
                  centerLng: 122,
                  centerLat: 27,
                  height: 300,
                ),
                SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1× 视图下在地图内竖拖：手势停在地图上，页面不跟着滚
      await tester.drag(
        find.byKey(const ValueKey('typhoon-map-canvas')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);

      // 地图以外照常滚页面
      await tester.dragFrom(const Offset(200, 500), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
    });

    testWidgets('双指捏合时手指同向平移不会带动页面滚动', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: const <Widget>[
                TyphoonMap(
                  points: <TrackPoint>[
                    TrackPoint(time: '2026-02-01 08:00:00', lng: 128, lat: 22),
                    TrackPoint(time: '2026-02-05 08:00:00', lng: 122, lat: 27),
                  ],
                  centerLng: 122,
                  centerLat: 27,
                  height: 300,
                ),
                SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final canvas = find.byKey(const ValueKey('typhoon-map-canvas'));
      final center = tester.getCenter(canvas);
      final p1 = await tester.startGesture(center - const Offset(50, 0));
      final p2 = await tester.startGesture(center + const Offset(50, 0));
      await tester.pump();

      // 两根手指一起往上推：跨度不变（不缩放）但质心移动，
      // 旧实现在这里会把第二根手指的竞技场留给外层 ScrollView，
      // 页面被当成「上拉」跟着滚。
      await p1.moveBy(const Offset(0, -40));
      await p2.moveBy(const Offset(0, -40));
      await tester.pump();
      await p1.moveBy(const Offset(0, -70));
      await p2.moveBy(const Offset(0, -70));
      await tester.pump();

      await p1.up();
      await p2.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
    });
  });
}
