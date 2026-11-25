import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_api.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_geo.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_map.dart';

/// 台风地图图层金图：风圈浅色弧形 / 预报虚线路径 / 预计登陆地点标记。
Future<void> loadCjkFont() async {
  final bytes = File('C:/Windows/Fonts/NotoSansSC-VF.ttf').readAsBytesSync();
  final loader = FontLoader('Roboto')
    ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

void main() {
  setUpAll(loadCjkFont);

  testWidgets('preview: typhoon map layers', (tester) async {
    tester.view.physicalSize = const Size(760, 760);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final points = <TrackPoint>[
      for (var i = 0; i < 6; i++)
        TrackPoint(
          time: '2026-11-0${i + 1} 08:00:00',
          lng: 132.0 - i * 1.3,
          lat: 21.0 + i * 0.8,
          strong: i < 2 ? '热带风暴' : '台风',
        ),
    ];
    final forecasts = <ForecastTrack>[
      ForecastTrack(
        agency: '中国',
        points: <ForecastPoint>[
          for (var i = 0; i < 5; i++)
            ForecastPoint(
              time: '2026-11-1$i 08:00:00',
              lng: 125.5 - i * 1.6,
              lat: 25.0 + i * 0.7,
            ),
        ],
      ),
      ForecastTrack(
        agency: '日本',
        points: <ForecastPoint>[
          for (var i = 0; i < 4; i++)
            ForecastPoint(
              time: '2026-11-1$i 08:00:00',
              lng: 125.5 - i * 1.2,
              lat: 25.0 + i * 1.5,
            ),
        ],
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: TyphoonMap(
              points: points,
              centerLng: 125.5,
              centerLat: 25.0,
              radius7: WindRadii.parse('300|240|330|260'),
              radius10: WindRadii.parse('120|100|130|100'),
              radius12: WindRadii.parse('60|60|60|60'),
              forecasts: forecasts,
              predictedLandfall: const PredictedLandfall(
                lng: 119.1,
                lat: 27.8,
                distanceKm: 120,
              ),
              height: 340,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/06-typhoon-map.png'),
    );
  });
}
