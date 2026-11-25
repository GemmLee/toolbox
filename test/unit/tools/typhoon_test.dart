import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:toolbox/core/settings/tool_texts.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_api.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_geo.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_page.dart';

const String _listJson = '''
[
  {"tfid":"202601","name":"洛鞍","enname":"NOKAEN","starttime":"2026-01-14 08:00:00","endtime":"2026-01-21 05:00:00","warnlevel":"white","isactive":"0"},
  {"tfid":"202602","name":"玛瑙","enname":"AGATE","starttime":"2026-02-01 08:00:00","endtime":"","warnlevel":"red","isactive":"1"}
]''';

const String _infoJson = '''
{
  "tfid":"202602",
  "name":"玛瑙",
  "enname":"AGATE",
  "isactive":"1",
  "starttime":"2026-02-01 08:00:00",
  "endtime":"",
  "warnlevel":"red",
  "centerlng":"121.50",
  "centerlat":"18.20",
  "land":[
    {"landaddress":"广东省阳江市沿海","landtime":"2026-02-05 06:30:00","lng":"111.80","lat":"21.80","info":"台风玛瑙已于2月5日6点30分前后在广东阳江沿海登陆","strong":"台风级"},
    {"landaddress":"台湾省花莲县沿海","landtime":"2026-02-04 12:00:00","lng":"121.60","lat":"23.90","info":"此前在台湾花莲登陆","strong":"强热带风暴"}
  ],
  "points":[
    {"time":"2026-02-01 08:00:00","lng":"118.80","lat":"19.90","strong":"热带低压","power":"7","speed":"15","pressure":"1002","movespeed":"28","movedirection":"北东"}
  ]
}''';

/// 远洋台风：全程在示意图范围（104–140°E / 16–42°N）之外。
const String _farInfoJson = '''
{
  "tfid":"202601",
  "name":"洛鞍",
  "enname":"NOKAEN",
  "isactive":"0",
  "starttime":"2026-01-14 08:00:00",
  "endtime":"2026-01-21 05:00:00",
  "warnlevel":"white",
  "centerlng":"158.00",
  "centerlat":"18.00",
  "land":[],
  "points":[
    {"time":"2026-01-14 08:00:00","lng":"155.00","lat":"15.00","strong":"台风","power":"12","speed":"33","pressure":"970"},
    {"time":"2026-01-16 08:00:00","lng":"158.00","lat":"18.00","strong":"强台风","power":"14","speed":"42","pressure":"950"}
  ]
}''';

MockClient _routingClient() => MockClient((req) async {
      final u = req.url.toString();
      final body = u.contains('TyphoonList')
          ? _listJson
          : (u.contains('202601') ? _farInfoJson : _infoJson);
      return http.Response.bytes(
          Uint8List.fromList(utf8.encode(body)), 200);
    });

void main() {
  group('台风中心点修正', () {
    TyphoonDetail parse(String isActive, String centerLng, String centerLat,
            String lastLng, String lastLat) =>
        TyphoonDetail.fromJson(jsonDecode('''
{
  "tfid":"9","name":"测试","enname":"TEST","isactive":$isActive,
  "centerlng":"$centerLng","centerlat":"$centerLat","land":[],
  "points":[
    {"time":"2026-01-01 08:00:00","lng":"$lastLng","lat":"$lastLat"}
  ]
}''') as Map<String, dynamic>);

    test('已停编台风的顶层中心是残留值，改用路径最新实况点', () {
      // 实测样本：历史台风 centerlng=152.55E，路径末点只有 140.40E。
      final d = parse('0', '152.55', '24.50', '140.40', '28.80');
      expect(d.displayCenterLng, 140.40);
      expect(d.displayCenterLat, 28.80);
    });

    test('活跃台风的顶层中心在可信范围内时仍采用更实时的值', () {
      final d = parse('1', '121.50', '24.00', '120.00', '23.00');
      expect(d.displayCenterLng, 121.50);
      expect(d.displayCenterLat, 24.00);
    });

    test('活跃台风的顶层中心异常离谱时同样回退路径末点', () {
      final d = parse('1', '158.00', '18.00', '120.00', '23.00');
      expect(d.displayCenterLng, 120.00);
    });

    test('没有路径点时保留顶层中心', () {
      final d = TyphoonDetail.fromJson(jsonDecode(
              '{"tfid":"9","name":"x","enname":"X","isactive":1,"centerlng":120.5,"centerlat":22.1,"land":[],"points":[]}')
          as Map<String, dynamic>);
      expect(d.displayCenterLng, 120.5);
      expect(d.displayCenterLat, 22.1);
    });
  });

  group('台风数据解析', () {
    test('列表解析：字段映射与活跃标记', () {
      final list =
          (jsonDecode(_listJson) as List).map((e) => TyphoonSummary.fromJson(e)).toList();
      expect(list.length, 2);
      expect(list[0].tfid, '202601');
      expect(list[0].isActive, isFalse);
      expect(list[1].tfid, '202602');
      expect(list[1].isActive, isTrue);
      expect(list[0].warnLevel, 'white');
    });

    test('详情解析：登陆地点/时间、大陆判定', () {
      final d = TyphoonDetail.fromJson(
          jsonDecode(_infoJson) as Map<String, dynamic>);
      expect(d.name, '玛瑙');
      expect(d.isActive, isTrue);
      expect(d.centerLat, 18.2);
      expect(d.land.length, 2);
      // 大陆登陆只含广东那条
      expect(d.mainlandLandings.length, 1);
      expect(d.mainlandLandings.first.address, contains('广东'));
      expect(d.points.first.speed, '15');
      expect(d.points.first.moveDirection, '北东');
    });

    test('非字符串数字字段也能解析', () {
      const raw =
          '{"tfid":"1","name":"x","enname":"X","isactive":1,"centerlng":120.5,"centerlat":22.1,"land":[],"points":[]}';
      final d = TyphoonDetail.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(d.isActive, isTrue);
      expect(d.centerLng, 120.5);
    });
  });

  group('风圈半径与预报路径解析', () {
    test('四象限顺序为东北 / 东南 / 西南 / 西北，空值返回 null', () {
      final r = WindRadii.parse('200|150|250|150')!;
      expect(r.ne, 200);
      expect(r.se, 150);
      expect(r.sw, 250);
      expect(r.nw, 150);
      expect(WindRadii.parse(''), isNull);
      expect(WindRadii.parse('0|0|0|0'), isNull);
      expect(WindRadii.parse(null), isNull);
      final single = WindRadii.parse('80')!;
      expect(<double>[single.ne, single.se, single.sw, single.nw],
          <double>[80, 80, 80, 80]);
    });

    test('详情解析风圈与多机构预报路径，主预报优先中国', () {
      const raw = '''
{
  "tfid":"9","name":"测试","enname":"TEST","isactive":1,
  "centerlng":"121.50","centerlat":"24.00","land":[],
  "points":[
    {"time":"2026-01-01 08:00:00","lng":"121.5","lat":"24.0","strong":"台风",
     "radius7":"200|150|250|150","radius10":"80|80|80|80","radius12":"",
     "forecast":[
       {"tm":"中国","forecastpoints":[
         {"time":"2026-01-01 08:00:00","lng":"121.5","lat":"24.0"},
         {"time":"2026-01-02 08:00:00","lng":"119.0","lat":"25.0"}]},
       {"tm":"日本","forecastpoints":[
         {"time":"2026-01-01 08:00:00","lng":"121.5","lat":"24.0"},
         {"time":"2026-01-02 08:00:00","lng":"124.0","lat":"26.0"}]}
     ]}
  ]
}''';
      final d = TyphoonDetail.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
      final circle = d.windCirclePoint!;
      expect(circle.radius7!.ne, 200);
      expect(circle.radius10!.sw, 80);
      expect(circle.radius12, isNull);
      expect(d.latestForecasts.length, 2);
      expect(d.primaryForecast!.agency, '中国');
      expect(d.primaryForecast!.validPoints.length, 2);
    });

    test('预警台风：预计登陆点在中国海域判为预警，远洋不判预警', () {
      TyphoonDetail detail(
        List<Map<String, dynamic>> land,
        List<Map<String, dynamic>> points,
      ) =>
          TyphoonDetail.fromJson(<String, dynamic>{
            'tfid': '1',
            'name': '测试',
            'enname': 'TEST',
            'isactive': 1,
            'centerlng': '121.5',
            'centerlat': '24.0',
            'land': land,
            'points': points,
          });

      final coastal = detail(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'landaddress': '浙江省玉环市沿海',
            'landtime': '2026-07-11 23:20:00',
            'lng': '121.29',
            'lat': '28.10',
          }
        ],
        <Map<String, dynamic>>[],
      );
      expect(predictedLandfallOf(coastal)!.inChinaNearSea, isTrue);
      expect(isWarningTyphoon(coastal), isTrue);
      expect(predictedLandfallOf(coastal)!.address, contains('浙江'));

      // 没有登陆记录时，用预报路径上距中国海岸最近的点判定。
      final forecastOnly = detail(
        <Map<String, dynamic>>[],
        <Map<String, dynamic>>[
          <String, dynamic>{
            'time': '2026-01-01 08:00:00',
            'lng': '121.5',
            'lat': '24.0',
            'forecast': <Map<String, dynamic>>[
              <String, dynamic>{
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
              },
            ],
          },
        ],
      );
      expect(isWarningTyphoon(forecastOnly), isTrue);

      final far = detail(
        <Map<String, dynamic>>[],
        <Map<String, dynamic>>[
          <String, dynamic>{
            'time': '2026-01-01 08:00:00',
            'lng': '158.0',
            'lat': '18.0',
            'forecast': <Map<String, dynamic>>[
              <String, dynamic>{
                'tm': '中国',
                'forecastpoints': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'time': '2026-01-01 08:00:00',
                    'lng': '158.0',
                    'lat': '18.0'
                  },
                  <String, dynamic>{
                    'time': '2026-01-02 08:00:00',
                    'lng': '162.0',
                    'lat': '20.0'
                  },
                ],
              },
            ],
          },
        ],
      );
      expect(isWarningTyphoon(far), isFalse);
      expect(distanceToChinaCoastKm(121.5, 25.0), lessThan(500));
      expect(distanceToChinaCoastKm(158.0, 18.0), greaterThan(500));
    });
  });

  group('无名称热带低压过滤', () {
    test('list 过滤无名称与「热带低压」记录', () async {
      const raw = '''
[
  {"tfid":"1","name":"","enname":"","starttime":"2026-01-01 08:00:00","endtime":"","warnlevel":"","isactive":"0"},
  {"tfid":"2","name":"热带低压","enname":"","starttime":"2026-01-02 08:00:00","endtime":"","warnlevel":"","isactive":"0"},
  {"tfid":"3","name":"海鸥","enname":"KALMAEGI","starttime":"2026-01-03 08:00:00","endtime":"","warnlevel":"blue","isactive":"1"}
]''';
      final client = MockClient((req) async =>
          http.Response.bytes(Uint8List.fromList(utf8.encode(raw)), 200));
      final api = TyphoonApi(client: client);
      final list = await api.list(2026);
      expect(list.length, 1);
      expect(list.single.name, '海鸥');
      api.dispose();
    });
  });

  group('台风 API 网络层', () {
    test('list 成功返回', () async {
      final client = MockClient((req) async =>
          http.Response.bytes(Uint8List.fromList(utf8.encode(_listJson)), 200));
      final api = TyphoonApi(client: client);
      final list = await api.list(2026);
      expect(list.length, 2);
      api.dispose();
    });

    test('info 成功返回', () async {
      final client = MockClient((req) async =>
          http.Response.bytes(Uint8List.fromList(utf8.encode(_infoJson)), 200));
      final api = TyphoonApi(client: client);
      final d = await api.info('202602');
      expect(d.name, '玛瑙');
      expect(d.mainlandLandings.first.address, contains('广东'));
      api.dispose();
    });

    test('非 200 抛异常', () async {
      final client = MockClient((req) async =>
          http.Response.bytes(Uint8List.fromList(utf8.encode('err')), 500));
      final api = TyphoonApi(client: client);
      expect(() => api.list(2026), throwsA(isA<TyphoonException>()));
      api.dispose();
    });

    test('details 批量拉取详情并上报进度', () async {
      final api = TyphoonApi(client: _routingClient());
      var done = 0;
      final map = await api.details(
        <String>['202601', '202602'],
        onProgress: (d, total) {
          done = d;
          expect(total, 2);
        },
      );
      expect(map.length, 2);
      expect(map['202601']!.centerLng, 158.0);
      expect(map['202602']!.name, '玛瑙');
      expect(done, 2);
      api.dispose();
    });

    test('details 单个详情失败记为 null 且不中断其余', () async {
      final client = MockClient((req) async {
        if (req.url.toString().contains('202601')) {
          return http.Response.bytes(
              Uint8List.fromList(utf8.encode('err')), 500);
        }
        return http.Response.bytes(
            Uint8List.fromList(utf8.encode(_infoJson)), 200);
      });
      final api = TyphoonApi(client: client);
      final map = await api.details(<String>['202601', '202602']);
      expect(map['202601'], isNull);
      expect(map['202602']!.name, '玛瑙');
      api.dispose();
    });
  });

  group('台风播报页面', () {
    testWidgets('列表页渲染标题与刷新按钮', (tester) async {
      final client = MockClient((req) async =>
          http.Response.bytes(Uint8List.fromList(utf8.encode(_listJson)), 200));
      await tester.pumpWidget(MaterialApp(
        home: TyphoonPage(api: TyphoonApi(client: client)),
      ));
      await tester.pumpAndSettle();
      expect(find.text(tr('台风播报')), findsOneWidget);
      expect(find.byKey(const ValueKey('typhoon-refresh')), findsOneWidget);
      // 两条台风都列出
      expect(find.text('玛瑙'), findsOneWidget);
      expect(find.text('洛鞍'), findsOneWidget);
      // 活跃台风(玛瑙)显示「进行中」标记；时间行以「进行中」替代「结束」
      expect(find.text(tr('进行中')), findsOneWidget);
      expect(find.textContaining(' · ${tr('进行中')}'), findsOneWidget);
    });

    testWidgets('详情页展示登陆预报与大陆标记', (tester) async {
      final client = MockClient((req) async =>
          http.Response.bytes(Uint8List.fromList(utf8.encode(_infoJson)), 200));
      await tester.pumpWidget(MaterialApp(
        home: TyphoonDetailPage(tfid: '202602', api: TyphoonApi(client: client)),
      ));
      await tester.pumpAndSettle();
      // 地图卡片较高，下方登陆/路径卡片需滚动后才构建。
      // 地图是手势封闭区，滚动要从卡片上方的空白/头部卡片起手，不能从地图中间拖。
      final list = find.byType(ListView).first;
      await tester.dragFrom(
        tester.getTopLeft(list) + const Offset(180, 24),
        const Offset(0, -1000),
      );
      await tester.pumpAndSettle();
      expect(find.text(tr('登陆预报')), findsOneWidget);
      expect(find.text(tr('大陆')), findsOneWidget);
      // 大陆登陆地点（数据，语言无关）
      expect(find.text('广东省阳江市沿海'), findsOneWidget);
      expect(find.text(tr('路径时间线')), findsOneWidget);
    });

    testWidgets('列表页：预警台风常显、其他台风默认折叠可展开', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TyphoonPage(api: TyphoonApi(client: _routingClient())),
      ));
      await tester.pumpAndSettle();

      // 「预警台风」分组：预计登陆地点在中国海域或近中国海域的台风常显。
      // 玛瑙有广东/台湾登陆记录 → 预警；洛鞍远洋 → 折叠。
      expect(find.text(tr('预警台风')), findsOneWidget);
      expect(find.text('玛瑙'), findsOneWidget);
      expect(find.text(tr('靠近')), findsNothing);
      // 玛瑙最大强度为「台风」，不显示最大强度徽章
      expect(find.text(tr('强台风')), findsNothing);
      // 进行中的玛瑙时间行不出现「结束」字样（洛鞍已折叠，其「结束」不可见）
      expect(find.textContaining(tr('结束')), findsNothing);

      // 远洋台风归入「其他台风」，默认折叠
      expect(find.text(tr('其他台风')), findsOneWidget);
      expect(find.text('洛鞍'), findsNothing);
      expect(find.text(tr('显示其他台风')), findsOneWidget);

      // 展开
      await tester.tap(find.byKey(const ValueKey('typhoon-list-others-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('洛鞍'), findsOneWidget);
      expect(find.text(tr('折叠其他台风')), findsOneWidget);
      // 洛鞍路径中出现过「强台风」，标注最大强度徽章
      expect(find.text(tr('强台风')), findsOneWidget);

      // 再折叠
      await tester.tap(find.byKey(const ValueKey('typhoon-list-others-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('洛鞍'), findsNothing);
    });

    testWidgets('详情页显示强度图例，折叠入口只在列表页', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TyphoonDetailPage(
            tfid: '202602', api: TyphoonApi(client: _routingClient())),
      ));
      await tester.pumpAndSettle();
      expect(find.text(tr('台风路径示意图')), findsOneWidget);
      expect(find.byKey(const ValueKey('typhoon-others-toggle')), findsNothing);

      // 强度图例在地图下方，需滚动后才构建（同样避开地图区域起手）
      final list = find.byType(ListView).first;
      await tester.dragFrom(
        tester.getTopLeft(list) + const Offset(180, 24),
        const Offset(0, -260),
      );
      await tester.pumpAndSettle();
      expect(find.text(tr('路径按强度着色')), findsOneWidget);
      expect(find.text(tr('热带低压')), findsWidgets);
      expect(find.text(tr('超强台风')), findsWidgets);
    });
  });
}
