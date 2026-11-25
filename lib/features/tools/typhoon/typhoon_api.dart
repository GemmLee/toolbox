import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// 台风数据模型与浙江省水利厅台风路径服务。
///
/// 数据来源：浙江省水利厅台风路径系统
///   https://typhoon.slt.zj.gov.cn/Api/TyphoonList/{year}
///   https://typhoon.slt.zj.gov.cn/Api/TyphoonInfo/{tfid}
/// 接口返回标准 JSON（非 JSONP），无需鉴权。

/// 台风摘要（列表项）。
class TyphoonSummary {
  const TyphoonSummary({
    required this.tfid,
    required this.name,
    required this.enname,
    required this.isActive,
    required this.startTime,
    required this.endTime,
    required this.warnLevel,
  });

  final String tfid;
  final String name;
  final String enname;
  final bool isActive;
  final String startTime;
  final String endTime;
  final String warnLevel;

  /// 是否仍在进行中（"1" 表示活跃）。
  static bool _parseActive(dynamic v) =>
      v == 1 || v == '1' || v == true;

  factory TyphoonSummary.fromJson(Map<String, dynamic> j) => TyphoonSummary(
        tfid: (j['tfid'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        enname: (j['enname'] ?? '').toString(),
        isActive: _parseActive(j['isactive']),
        startTime: (j['starttime'] ?? '').toString(),
        endTime: (j['endtime'] ?? '').toString(),
        warnLevel: (j['warnlevel'] ?? '').toString(),
      );
}

/// 登陆记录。
class Landing {
  const Landing({
    required this.address,
    required this.time,
    this.lng,
    this.lat,
    this.info,
    this.strong,
  });

  final String address;
  final String time;
  final double? lng;
  final double? lat;
  final String? info;
  final String? strong;

  /// 是否在中国大陆（不含台湾、香港、澳门）。
  bool get isMainland {
    final a = address;
    return !a.contains('台湾') &&
        !a.contains('香港') &&
        !a.contains('澳门');
  }

  factory Landing.fromJson(Map<String, dynamic> j) => Landing(
        address: (j['landaddress'] ?? '').toString(),
        time: (j['landtime'] ?? '').toString(),
        lng: _toDouble(j['lng']),
        lat: _toDouble(j['lat']),
        info: (j['info'] as String?)?.isEmpty == true
            ? null
            : (j['info'] as String?),
        strong: (j['strong'] as String?)?.isEmpty == true
            ? null
            : (j['strong'] as String?),
      );
}

/// 风圈半径：按四个象限给出的大风半径（单位 km）。
///
/// 浙江省水利厅接口字段 `radius7 / radius10 / radius12` 分别是 7 / 10 / 12
/// 级风圈，字符串按「东北 | 东南 | 西南 | 西北」顺序给出四个象限的半径，
/// 与中央气象台「分东北、东南、西南、西北四象限确定大风半径」的口径一致。
class WindRadii {
  const WindRadii({
    required this.ne,
    required this.se,
    required this.sw,
    required this.nw,
  });

  /// 东北 / 东南 / 西南 / 西北象限半径（km）。
  final double ne;
  final double se;
  final double sw;
  final double nw;

  bool get hasData => ne > 0 || se > 0 || sw > 0 || nw > 0;

  /// 解析 `"200|150|250|150"`；空串、全 0 或格式不合法返回 null。
  /// 字段不足时用第一个有效值补齐（部分源只给单一半径）。
  static WindRadii? parse(dynamic v) {
    if (v == null) return null;
    final parts = v.toString().trim().split('|');
    if (parts.isEmpty) return null;
    final first = double.tryParse(parts[0].trim());
    if (first == null) return null;
    double at(int i) => i < parts.length
        ? (double.tryParse(parts[i].trim()) ?? first)
        : first;
    final radii = WindRadii(ne: first, se: at(1), sw: at(2), nw: at(3));
    return radii.hasData ? radii : null;
  }
}

/// 预报路径点（各预报机构给出）。
class ForecastPoint {
  const ForecastPoint({
    required this.time,
    this.lng,
    this.lat,
    this.strong,
    this.power,
    this.pressure,
  });

  final String time;
  final double? lng;
  final double? lat;
  final String? strong;
  final String? power;
  final String? pressure;

  bool get hasCoord => lng != null && lat != null;

  factory ForecastPoint.fromJson(Map<String, dynamic> j) => ForecastPoint(
        time: (j['time'] ?? '').toString(),
        lng: _toDouble(j['lng']),
        lat: _toDouble(j['lat']),
        strong: _nullIfEmpty(j['strong']),
        power: _nullIfEmpty(j['power']),
        pressure: _nullIfEmpty(j['pressure']),
      );
}

/// 某个预报机构的一条预报路径。
class ForecastTrack {
  const ForecastTrack({required this.agency, required this.points});

  final String agency;
  final List<ForecastPoint> points;

  /// 中国气象局（中央气象台）官方预报，地图里作为主预报路径。
  bool get isChina => agency.trim() == '中国';

  List<ForecastPoint> get validPoints =>
      points.where((p) => p.hasCoord).toList(growable: false);

  factory ForecastTrack.fromJson(Map<String, dynamic> j) {
    final raw = j['forecastpoints'];
    return ForecastTrack(
      agency: (j['tm'] ?? '').toString(),
      points: raw is List
          ? raw
              .whereType<Map>()
              .map((e) =>
                  ForecastPoint.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false)
          : const <ForecastPoint>[],
    );
  }
}

/// 路径点（实测 + 各国预报）。
class TrackPoint {
  const TrackPoint({
    required this.time,
    this.lng,
    this.lat,
    this.strong,
    this.power,
    this.speed,
    this.pressure,
    this.moveSpeed,
    this.moveDirection,
    this.radius7,
    this.radius10,
    this.radius12,
    this.forecasts = const <ForecastTrack>[],
  });

  final String time;
  final double? lng;
  final double? lat;
  final String? strong;
  final String? power;
  final String? speed;
  final String? pressure;
  final String? moveSpeed;
  final String? moveDirection;

  /// 7 / 10 / 12 级风圈的四象限半径（km）。
  final WindRadii? radius7;
  final WindRadii? radius10;
  final WindRadii? radius12;

  /// 该实况时刻各机构的预报路径。
  final List<ForecastTrack> forecasts;

  factory TrackPoint.fromJson(Map<String, dynamic> j) => TrackPoint(
        time: (j['time'] ?? '').toString(),
        lng: _toDouble(j['lng']),
        lat: _toDouble(j['lat']),
        strong: _nullIfEmpty(j['strong']),
        power: _nullIfEmpty(j['power']),
        speed: _nullIfEmpty(j['speed']),
        pressure: _nullIfEmpty(j['pressure']),
        moveSpeed: _nullIfEmpty(j['movespeed']),
        moveDirection: _nullIfEmpty(j['movedirection']),
        radius7: WindRadii.parse(j['radius7']),
        radius10: WindRadii.parse(j['radius10']),
        radius12: WindRadii.parse(j['radius12']),
        forecasts: j['forecast'] is List
            ? (j['forecast'] as List)
                .whereType<Map>()
                .map((e) => ForecastTrack.fromJson(
                    Map<String, dynamic>.from(e)))
                .toList(growable: false)
            : const <ForecastTrack>[],
      );
}

/// 活跃台风顶层中心相对最新实况点的最大可信偏移（km）。
/// 超出即视为残留/异常值，地图改用路径末点。
const double kMaxCenterDriftKm = 300.0;

/// 等距圆柱近似的两点距离，只用于判断坐标是否离谱，不需要大圆精度。
double _approxKm(double lng1, double lat1, double lng2, double lat2) {
  final midRad = (lat1 + lat2) * math.pi / 360;
  final dx = (lng1 - lng2) * 111.32 * math.cos(midRad);
  final dy = (lat1 - lat2) * 110.57;
  return math.sqrt(dx * dx + dy * dy);
}

/// 台风详情。
class TyphoonDetail {
  const TyphoonDetail({
    required this.tfid,
    required this.name,
    required this.enname,
    required this.isActive,
    required this.centerLng,
    required this.centerLat,
    required this.land,
    required this.points,
  });

  final String tfid;
  final String name;
  final String enname;
  final bool isActive;
  final double? centerLng;
  final double? centerLat;
  final List<Landing> land;
  final List<TrackPoint> points;

  /// 在大陆的登陆记录（按时间升序）。
  List<Landing> get mainlandLandings =>
      land.where((l) => l.isMainland).toList()
        ..sort((a, b) => a.time.compareTo(b.time));

  /// 是否已登陆：登陆记录的时间不晚于当前时刻即算已登陆。
  /// 时间为空或无法解析时按「已发生的登陆记录」处理；只有明确晚于现在
  /// 的 landtime 才视为尚未实现的预报登陆。
  bool get hasLanded {
    final now = DateTime.now();
    return land.any((l) {
      final t = DateTime.tryParse(l.time.trim().replaceAll(RegExp(r'\s+'), 'T'));
      return t == null || !t.isAfter(now);
    });
  }

  /// 是否已结束（停编）。
  bool get hasEnded => !isActive;

  /// 预计登陆地点只对「进行中且尚未登陆」的台风展示：已登陆看实际
  /// 登陆点（地图三角标记），已结束则预测已失效。
  bool get showPredictedLandfall => !hasEnded && !hasLanded;

  /// 预测路径只对进行中的台风展示；结束后保留实况路径即可。
  bool get showForecastTracks => !hasEnded;

  /// 时间最新的实况点（API 的 points 不保证有序，按 time 取最大而非取末项）。
  TrackPoint? get latestPoint {
    TrackPoint? best;
    for (final p in points) {
      if (p.lng == null || p.lat == null) continue;
      if (best == null || p.time.compareTo(best.time) >= 0) best = p;
    }
    return best;
  }

  /// 地图「台」标记与视图中心使用的坐标。
  ///
  /// API 顶层的 `centerlng/centerlat` 对**已停编台风**常是残留值（实测某历史
  /// 台风为 152.55°E，而路径末点只有 140.40°E，偏差 12° 经度），直接拿来画
  /// 会让红色中心标记与整张地图都飘离路径。因此以路径最新实况点为基准；
  /// 只有活跃台风、且顶层中心距该点不超过 300 km 时才采用更实时的顶层值。
  ({double? lng, double? lat}) _displayCenter() {
    final latest = latestPoint;
    final lLng = latest?.lng;
    final lLat = latest?.lat;
    if (lLng == null || lLat == null) {
      return (lng: centerLng, lat: centerLat);
    }
    final cLng = centerLng;
    final cLat = centerLat;
    if (isActive &&
        cLng != null &&
        cLat != null &&
        _approxKm(cLng, cLat, lLng, lLat) <= kMaxCenterDriftKm) {
      return (lng: cLng, lat: cLat);
    }
    return (lng: lLng, lat: lLat);
  }

  double? get displayCenterLng => _displayCenter().lng;
  double? get displayCenterLat => _displayCenter().lat;

  /// 最近一个带风圈半径的实况点；三个级别必须来自同一时刻，避免混用。
  TrackPoint? get windCirclePoint {
    for (var i = points.length - 1; i >= 0; i--) {
      final p = points[i];
      if (p.radius7 != null || p.radius10 != null || p.radius12 != null) {
        return p;
      }
    }
    return null;
  }

  /// 最近一个带预报的实况时刻对应的所有机构预报路径。
  List<ForecastTrack> get latestForecasts {
    for (var i = points.length - 1; i >= 0; i--) {
      if (points[i].forecasts.isNotEmpty) return points[i].forecasts;
    }
    return const <ForecastTrack>[];
  }

  /// 主预报路径：优先中国气象局，否则取预报点最多的机构。
  ForecastTrack? get primaryForecast {
    ForecastTrack? best;
    for (final f in latestForecasts) {
      if (f.validPoints.length < 2) continue;
      if (f.isChina) return f;
      if (best == null || f.validPoints.length > best.validPoints.length) {
        best = f;
      }
    }
    return best;
  }

  factory TyphoonDetail.fromJson(Map<String, dynamic> j) {
    final landRaw = j['land'];
    final pointsRaw = j['points'];
    return TyphoonDetail(
      tfid: (j['tfid'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      enname: (j['enname'] ?? '').toString(),
      isActive: TyphoonSummary._parseActive(j['isactive']),
      centerLng: _toDouble(j['centerlng']),
      centerLat: _toDouble(j['centerlat']),
      land: landRaw is List
          ? landRaw
              .map((e) => Landing.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false)
          : const <Landing>[],
      points: pointsRaw is List
          ? pointsRaw
              .map((e) => TrackPoint.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false)
          : const <TrackPoint>[],
    );
  }
}

/// 台风服务异常（消息可直接展示）。
class TyphoonException implements Exception {
  const TyphoonException(this.message);

  final String message;

  @override
  String toString() => message;
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  return double.tryParse(s);
}

String? _nullIfEmpty(dynamic v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

/// 浙江省水利厅台风路径服务。
class TyphoonApi {
  TyphoonApi({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.baseUrl = 'https://typhoon.slt.zj.gov.cn/Api',
  }) : _client = client ?? http.Client();

  static const String defaultBaseUrl = 'https://typhoon.slt.zj.gov.cn/Api';

  final http.Client _client;
  final Duration timeout;
  final String baseUrl;

  /// 获取某一年度的台风列表。
  ///
  /// 无名称的热带低压（未命名/未编号）不纳入列表。
  Future<List<TyphoonSummary>> list(int year) async {
    final uri = Uri.parse('$baseUrl/TyphoonList/$year');
    final resp = await _getJson(uri);
    if (resp is! List) {
      throw const TyphoonException('返回数据格式异常');
    }
    return resp
        .map((e) => TyphoonSummary.fromJson(Map<String, dynamic>.from(e)))
        .where(_isNamedTyphoon)
        .toList(growable: false);
  }

  /// 是否为有名称的台风（过滤掉无名称的热带低压记录）。
  static bool _isNamedTyphoon(TyphoonSummary s) {
    final n = s.name.trim();
    if (n.isEmpty) return false;
    const unnamed = <String>{'热带低压', '熱帶低壓', '无名称', '無名稱', 'TD', 'td'};
    return !unnamed.contains(n);
  }

  /// 获取单个台风的详细信息（含登陆与路径）。
  Future<TyphoonDetail> info(String tfid) async {
    final uri = Uri.parse('$baseUrl/TyphoonInfo/$tfid');
    final resp = await _getJson(uri);
    if (resp is! Map) throw const TyphoonException('返回数据格式异常');
    return TyphoonDetail.fromJson(Map<String, dynamic>.from(resp));
  }

  /// 并发拉取多个台风的详情（用于列表页识别「预警台风」）。
  ///
  /// 单个台风失败时结果记为 null，不中断其余请求；[onProgress] 报告进度。
  Future<Map<String, TyphoonDetail?>> details(
    Iterable<String> tfids, {
    int concurrency = 6,
    void Function(int done, int total)? onProgress,
  }) async {
    final ids = tfids.toList(growable: false);
    final result = <String, TyphoonDetail?>{};
    var cursor = 0;
    var done = 0;
    Future<void> worker() async {
      while (true) {
        final i = cursor;
        if (i >= ids.length) return;
        cursor = i + 1;
        try {
          result[ids[i]] = await info(ids[i]);
        } catch (_) {
          result[ids[i]] = null;
        }
        done++;
        onProgress?.call(done, ids.length);
      }
    }

    final workers = math.min(concurrency, ids.length);
    if (workers > 0) {
      await Future.wait<void>(
        List<Future<void>>.generate(workers, (_) => worker()),
      );
    }
    return result;
  }

  Future<Object?> _getJson(Uri uri) async {
    http.Response resp;
    try {
      resp = await _client
          .get(uri, headers: const <String, String>{
            'Accept': 'application/json',
            'User-Agent': 'Mozilla/5.0',
          })
          .timeout(timeout);
    } on TimeoutException {
      throw const TyphoonException('请求超时，请检查网络后重试');
    } catch (e) {
      throw TyphoonException('网络请求失败：$e');
    }
    if (resp.statusCode != 200) {
      throw TyphoonException('服务返回 HTTP ${resp.statusCode}');
    }
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const TyphoonException('返回内容不是有效的 JSON');
    }
  }

  void dispose() => _client.close();
}
