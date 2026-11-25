import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/typhoon/typhoon_map.dart';

import '../../support/test_env.dart';

/// 底图用「基准投影 + 画布变换」复用缓存 Path，必须与逐帧重投影的
/// [MapView.project] 完全一致。这里直接比对数学结果：只要两个轴的
/// 缩放系数或偏移量有一项写反，底图就会与经纬网、台风轨迹反向漂移。
void main() {
  installCleanEnv();

  const rect = Rect.fromLTWH(24, 18, 320, 280);

  final views = <String, MapView>{
    '基准': MapView.base,
    '放大 2×': _zoom(MapView.base, 2),
    '放大 4×': _zoom(MapView.base, 4),
    '偏北': _shift(MapView.base, dLng: 0, dLat: 4),
    '偏南偏东': _shift(MapView.base, dLng: 3, dLat: -3),
    '放大 3× 且偏西南': _shift(_zoom(MapView.base, 3), dLng: -6, dLat: -5),
    '缩小 0.8×': _zoom(MapView.base, 0.8),
  };

  const samples = <List<double>>[
    [120.0, 22.0],
    [122.0, 29.0],
    [131.5, 35.5],
    [108.0, 18.0],
    [140.0, 41.0],
  ];

  for (final entry in views.entries) {
    test('底图变换与逐帧投影一致：${entry.key}', () {
      final view = entry.value;
      final t = MapCanvasTransform.between(view, rect);
      for (final p in samples) {
        final expected = view.project(p[0], p[1], rect);
        final actual = t.apply(MapView.base.project(p[0], p[1], rect));
        expect(actual.dx, closeTo(expected.dx, 1e-9),
            reason: '经度 ${p[0]} 横向偏移');
        expect(actual.dy, closeTo(expected.dy, 1e-9),
            reason: '纬度 ${p[1]} 纵向偏移');
      }
    });
  }

  test('平移只改偏移量，缩放只改系数', () {
    final baseT = MapCanvasTransform.between(MapView.base, rect);
    expect(baseT.sx, closeTo(1, 1e-12));
    expect(baseT.sy, closeTo(1, 1e-12));
    expect(baseT.tx, closeTo(0, 1e-12));
    expect(baseT.ty, closeTo(0, 1e-12));

    // 视图向北移动 → 底图整体向下移动（纬度轴翻转）。
    final north = MapCanvasTransform.between(
      _shift(MapView.base, dLng: 0, dLat: 4),
      rect,
    );
    expect(north.ty, greaterThan(0));
    expect(north.tx, closeTo(0, 1e-9));

    // 视图向东移动 → 底图整体向左移动。
    final east = MapCanvasTransform.between(
      _shift(MapView.base, dLng: 3, dLat: 0),
      rect,
    );
    expect(east.tx, lessThan(0));
    expect(east.ty, closeTo(0, 1e-9));
  });
}

MapView _zoom(MapView v, double z) {
  final cx = (v.minLng + v.maxLng) / 2;
  final cy = (v.minLat + v.maxLat) / 2;
  final hLng = (v.maxLng - v.minLng) / 2 / z;
  final hLat = (v.maxLat - v.minLat) / 2 / z;
  return MapView(
    minLng: cx - hLng,
    maxLng: cx + hLng,
    minLat: cy - hLat,
    maxLat: cy + hLat,
  );
}

MapView _shift(MapView v, {required double dLng, required double dLat}) =>
    MapView(
      minLng: v.minLng + dLng,
      maxLng: v.maxLng + dLng,
      minLat: v.minLat + dLat,
      maxLat: v.maxLat + dLat,
    );
