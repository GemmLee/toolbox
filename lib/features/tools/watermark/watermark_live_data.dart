import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'watermark_engine.dart';

/// 拍照水印的实时信息采集：经纬度/海拔走原生定位，气温走 open-meteo 公共接口
/// （无需 API key）。任一项失败都优雅返回 null，水印对应行自动跳过。
class WatermarkLiveData {
  WatermarkLiveData({http.Client? httpClient, MethodChannel? channel})
      : _http = httpClient ?? http.Client(),
        _channel = channel ?? const MethodChannel('toolbox/watermark_geo');

  final http.Client _http;
  final MethodChannel _channel;

  /// 采集一帧实时快照，用于拍照那一刻定格。
  ///
  /// [includeGeo] 控制是否请求定位；[includeTemperature] 控制是否联网取气温。
  Future<WatermarkSnapshot> collect({
    required bool includeGeo,
    required bool includeTemperature,
  }) async {
    double? lat;
    double? lng;
    double? altitude;

    if (includeGeo) {
      try {
        final raw =
            await _channel.invokeMethod<Map<dynamic, dynamic>>('getLocation');
        if (raw != null) {
          lat = (raw['latitude'] as num?)?.toDouble();
          lng = (raw['longitude'] as num?)?.toDouble();
          altitude = (raw['altitude'] as num?)?.toDouble();
        }
      } on PlatformException {
        // 定位不可用：经纬度行留空。
      } on MissingPluginException {
        // 测试/桌面环境没有原生通道。
      }
    }

    double? temperature;
    if (includeTemperature) {
      temperature = await _fetchTemperature(lat, lng);
    }

    return WatermarkSnapshot.now(
      temperature: temperature,
      altitude: altitude,
      latitude: lat,
      longitude: lng,
    );
  }

  /// open-meteo 当前气温（°C）。无经纬度时用接口默认的 IP 粗定位。
  Future<double?> _fetchTemperature(double? lat, double? lng) async {
    final query = StringBuffer('https://api.open-meteo.com/v1/forecast?'
        'current=temperature_2m');
    if (lat != null && lng != null) {
      query
        ..write('&latitude=${lat.toStringAsFixed(4)}')
        ..write('&longitude=${lng.toStringAsFixed(4)}');
    }
    try {
      final response = await _http.get(
        Uri.parse(query.toString()),
        headers: const {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final current = decoded['current'];
      if (current is Map && current['temperature_2m'] is num) {
        return (current['temperature_2m'] as num).toDouble();
      }
    } on Exception {
      // 无网络 / 超时：气温行留空。
    }
    return null;
  }
}
