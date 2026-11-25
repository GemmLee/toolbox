import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:toolbox/core/settings/tool_texts.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_api.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_geo.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_page.dart';

String _stamp(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')} '
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

Map<String, dynamic> _landing(String time) => <String, dynamic>{
      'landaddress': '浙江省玉环市沿海',
      'landtime': time,
      'lng': '121.29',
      'lat': '28.10',
    };

Map<String, dynamic> _forecast() => <String, dynamic>{
      'tm': '中国',
      'forecastpoints': <Map<String, dynamic>>[
        <String, dynamic>{
          'time': '2026-01-01 08:00:00',
          'lng': '121.5',
          'lat': '24.0'
        },
        <String, dynamic>{
          'time': '2026-01-02 08:00:00',
          'lng': '119.0',
          'lat': '25.0'
        },
      ],
    };

Map<String, dynamic> _infoMap({
  required String isActive,
  List<Map<String, dynamic>> land = const <Map<String, dynamic>>[],
  bool forecast = true,
}) =>
    <String, dynamic>{
      'tfid': '9',
      'name': '状态测试',
      'enname': 'STATUS',
      'isactive': isActive,
      'centerlng': '121.5',
      'centerlat': '24.0',
      'land': land,
      'points': <Map<String, dynamic>>[
        <String, dynamic>{
          'time': '2026-01-01 08:00:00',
          'lng': '121.5',
          'lat': '24.0',
          'strong': '台风',
          if (forecast) 'forecast': <Map<String, dynamic>>[_forecast()],
        },
      ],
    };

void main() {
  group('台风状态决定是否展示预测图层', () {
    TyphoonDetail detail({
      required String isActive,
      List<Map<String, dynamic>> land = const <Map<String, dynamic>>[],
      bool forecast = true,
    }) =>
        TyphoonDetail.fromJson(
            _infoMap(isActive: isActive, land: land, forecast: forecast));

    test('进行中且未登陆：预计登陆地点与预测路径都展示', () {
      final d = detail(isActive: '1');
      expect(d.hasLanded, isFalse);
      expect(d.hasEnded, isFalse);
      expect(d.showPredictedLandfall, isTrue);
      expect(d.showForecastTracks, isTrue);
      expect(predictedLandfallOf(d), isNotNull);
      expect(d.latestForecasts, isNotEmpty);
    });

    test('已登陆：不展示预计登陆地点，仍展示预测路径', () {
      final d = detail(
        isActive: '1',
        land: <Map<String, dynamic>>[
          _landing(_stamp(DateTime.now().subtract(const Duration(days: 2)))),
        ],
      );
      expect(d.hasLanded, isTrue);
      expect(d.showPredictedLandfall, isFalse);
      expect(d.showForecastTracks, isTrue);
    });

    test('只有未来预报登陆记录时不算已登陆', () {
      final d = detail(
        isActive: '1',
        land: <Map<String, dynamic>>[
          _landing(_stamp(DateTime.now().add(const Duration(days: 2)))),
        ],
      );
      expect(d.hasLanded, isFalse);
      expect(d.showPredictedLandfall, isTrue);
    });

    test('登陆时间无法解析时按已登陆处理', () {
      final d = detail(
        isActive: '1',
        land: <Map<String, dynamic>>[_landing('')],
      );
      expect(d.hasLanded, isTrue);
      expect(d.showPredictedLandfall, isFalse);
    });

    test('已结束：不展示预测路径，也不展示预计登陆地点', () {
      final d = detail(isActive: '0');
      expect(d.hasEnded, isTrue);
      expect(d.showForecastTracks, isFalse);
      expect(d.showPredictedLandfall, isFalse);
      // 分组判定不受展示开关影响，避免历史台风被误折叠。
      expect(isWarningTyphoon(d), isTrue);
    });
  });

  group('台风详情页图例随状态隐藏', () {
    Future<void> pumpDetail(WidgetTester tester, Map<String, dynamic> info) async {
      final body = jsonEncode(info);
      final client = MockClient((req) async => http.Response.bytes(
          Uint8List.fromList(utf8.encode(body)), 200));
      await tester.pumpWidget(MaterialApp(
        home: TyphoonDetailPage(tfid: '9', api: TyphoonApi(client: client)),
      ));
      await tester.pumpAndSettle();
      // 图例在地图下方，滚动后才构建；从头部卡片起手避开地图手势区。
      final list = find.byType(ListView).first;
      await tester.dragFrom(
        tester.getTopLeft(list) + const Offset(180, 24),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('进行中未登陆：预计登陆地点与预计路径图例都在', (tester) async {
      await pumpDetail(tester, _infoMap(isActive: '1'));
      expect(find.text(tr('预计登陆地点')), findsOneWidget);
      expect(find.text(tr('预计路径')), findsOneWidget);
    });

    testWidgets('已登陆：隐藏预计登陆地点，保留预计路径', (tester) async {
      await pumpDetail(
        tester,
        _infoMap(
          isActive: '1',
          land: <Map<String, dynamic>>[
            _landing(_stamp(DateTime.now().subtract(const Duration(days: 2)))),
          ],
        ),
      );
      expect(find.text(tr('预计登陆地点')), findsNothing);
      expect(find.text(tr('预计路径')), findsOneWidget);
      // 实际登陆记录仍在「登陆预报」卡片里展示。
      expect(find.text('浙江省玉环市沿海'), findsOneWidget);
    });

    testWidgets('已结束：隐藏预计路径，且不再推导预计登陆地点', (tester) async {
      await pumpDetail(tester, _infoMap(isActive: '0'));
      expect(find.text(tr('预计路径')), findsNothing);
      expect(find.text(tr('预计登陆地点')), findsNothing);
      expect(find.text(tr('暂无登陆预报记录')), findsOneWidget);
    });
  });
}
