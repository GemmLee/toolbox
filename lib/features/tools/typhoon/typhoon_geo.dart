import 'dart:math' as math;

import 'typhoon_api.dart';

export 'typhoon_geo_data.dart';

/// 台风示意图的离线地理数据访问层。
///
/// 几何数据由 `../tools/geo/gen_typhoon_geo.py` 生成（来源：阿里云 DataV.GeoAtlas
/// 中国省级行政区/国界轮廓 + Natural Earth 1:50m 周边国家轮廓），见
/// [typhoon_geo_data.dart]。本文件只保留示意图的常量与业务判定逻辑。
///
/// 合规说明：台湾、海南等均为中国领土，与大陆同色填充；周边国家单独着色；
/// 不绘制任何争议性界线（如南海断续线）。全部数据离线内置。

/// 示意图边界框（经度 104–140°E，纬度 16–42°N）。
const double kMapMinLng = 104.0;
const double kMapMaxLng = 140.0;
const double kMapMinLat = 16.0;
const double kMapMaxLat = 42.0;

/// 经纬度是否落在示意图边界框内。
bool pointInMap(double lng, double lat) =>
    lng >= kMapMinLng &&
    lng <= kMapMaxLng &&
    lat >= kMapMinLat &&
    lat <= kMapMaxLat;

/// 台风是否在示意图范围内出现：路径点、登陆点或当前中心任一坐标落在框内。
///
/// [trackInMap] 只描述「是否进入本图」，不再作为列表页分组条件；
/// 分组改由 [isWarningTyphoon] 按预计登陆地点判定。
bool trackInMap(
  Iterable<TrackPoint> points,
  Iterable<Landing> land, {
  double? centerLng,
  double? centerLat,
}) {
  if (centerLng != null &&
      centerLat != null &&
      pointInMap(centerLng, centerLat)) {
    return true;
  }
  for (final p in points) {
    final lng = p.lng;
    final lat = p.lat;
    if (lng != null && lat != null && pointInMap(lng, lat)) return true;
  }
  for (final l in land) {
    final lng = l.lng;
    final lat = l.lat;
    if (lng != null && lat != null && pointInMap(lng, lat)) return true;
  }
  return false;
}

/// 台风强度分级（由 API 返回的 `strong` 文本解析）。
enum TyphoonStrength {
  unknown,
  tropicalDepression,
  tropicalStorm,
  severeTropicalStorm,
  typhoon,
  severeTyphoon,
  superTyphoon,
}

/// 台风整个生命周期（路径点 + 登陆记录）中达到过的最大强度。
TyphoonStrength maxStrengthOf(
  Iterable<TrackPoint> points,
  Iterable<Landing> land,
) {
  var max = TyphoonStrength.unknown;
  for (final p in points) {
    final s = parseStrength(p.strong);
    if (s.index > max.index) max = s;
  }
  for (final l in land) {
    final s = parseStrength(l.strong);
    if (s.index > max.index) max = s;
  }
  return max;
}

/// 解析强度文本，如「强热带风暴」「台风级」「超强台风」。
TyphoonStrength parseStrength(String? strong) {
  final s = (strong ?? '').trim();
  if (s.isEmpty) return TyphoonStrength.unknown;
  // 顺序重要：先长后短，避免「超强台风」被「台风」提前命中。
  if (s.contains('超强')) return TyphoonStrength.superTyphoon;
  if (s.contains('强台风')) return TyphoonStrength.severeTyphoon;
  if (s.contains('强热带')) return TyphoonStrength.severeTropicalStorm;
  if (s.contains('热带低压')) return TyphoonStrength.tropicalDepression;
  if (s.contains('热带风暴')) return TyphoonStrength.tropicalStorm;
  if (s.contains('台风')) return TyphoonStrength.typhoon;
  return TyphoonStrength.unknown;
}

/// 强度的中文名称（同时作为 i18n key）。
String strengthLabel(TyphoonStrength s) => switch (s) {
      TyphoonStrength.tropicalDepression => '热带低压',
      TyphoonStrength.tropicalStorm => '热带风暴',
      TyphoonStrength.severeTropicalStorm => '强热带风暴',
      TyphoonStrength.typhoon => '台风',
      TyphoonStrength.severeTyphoon => '强台风',
      TyphoonStrength.superTyphoon => '超强台风',
      TyphoonStrength.unknown => '未知强度',
    };

/// 中国海岸参考点（含台湾、海南、香港、澳门，均为中国领土）。
///
/// 用「到最近海岸参考点的距离」近似判断某点是否位于中国海域或邻近海域，
/// 避免用矩形把整个西北太平洋都算进来。坐标为沿岸主要城市的近似经纬度。
const List<List<double>> kChinaCoastRefs = <List<double>>[
  <double>[124.4, 40.1], // 丹东
  <double>[121.6, 38.9], // 大连
  <double>[117.7, 39.0], // 天津
  <double>[120.4, 36.1], // 青岛
  <double>[121.5, 31.2], // 上海
  <double>[121.6, 29.9], // 宁波
  <double>[120.7, 28.0], // 温州
  <double>[119.3, 26.1], // 福州
  <double>[118.1, 24.5], // 厦门
  <double>[116.7, 23.4], // 汕头
  <double>[114.2, 22.3], // 香港
  <double>[113.5, 22.2], // 澳门
  <double>[110.4, 21.2], // 湛江
  <double>[109.1, 21.5], // 北海
  <double>[110.3, 20.0], // 海口
  <double>[109.5, 18.3], // 三亚
  <double>[121.5, 25.0], // 台北
  <double>[121.6, 24.0], // 花莲
  <double>[120.3, 22.6], // 高雄
];

/// 「中国海域或近中国海域」阈值：距最近中国海岸参考点 500 km 以内。
const double kChinaNearSeaKm = 500.0;

/// 估算经纬度点到最近中国海岸参考点的距离（km，等距圆柱近似）。
double distanceToChinaCoastKm(double lng, double lat) {
  var best = double.infinity;
  for (final ref in kChinaCoastRefs) {
    final midRad = (lat + ref[1]) * math.pi / 360;
    final dx = (lng - ref[0]) * 111.32 * math.cos(midRad);
    final dy = (lat - ref[1]) * 110.57;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d < best) best = d;
  }
  return best;
}

/// 预计登陆地点：优先取登陆（预报/实况）记录，否则取预报路径上
/// 距中国海岸最近的点；地图也用它在对应位置画标记。
class PredictedLandfall {
  const PredictedLandfall({
    required this.lng,
    required this.lat,
    required this.distanceKm,
    this.address,
    this.time,
  });

  final double lng;
  final double lat;
  final double distanceKm;

  /// 有明确登陆记录时带地名；由预报路径推导时为 null。
  final String? address;
  final String? time;

  bool get inChinaNearSea => distanceKm <= kChinaNearSeaKm;
}

/// 从详情数据推导预计登陆地点；没有任何登陆/预报坐标时返回 null。
PredictedLandfall? predictedLandfallOf(TyphoonDetail d) {
  PredictedLandfall? best;
  void consider(double lng, double lat, String? address, String? time) {
    final dist = distanceToChinaCoastKm(lng, lat);
    final current = best;
    if (current == null || dist < current.distanceKm) {
      best = PredictedLandfall(
        lng: lng,
        lat: lat,
        distanceKm: dist,
        address: address,
        time: time,
      );
    }
  }

  for (final l in d.land) {
    if (l.lng != null && l.lat != null) {
      consider(l.lng!, l.lat!, l.address, l.time);
    }
  }
  for (final f in d.latestForecasts) {
    for (final p in f.validPoints) {
      consider(p.lng!, p.lat!, null, p.time);
    }
  }
  return best;
}

/// 「预警台风」分组条件：预计登陆地点在中国海域或近中国海域。
///
/// 其余判定（活跃优先、最大强度标注、预警等级徽章、拉取失败按预警处理、
/// 其它台风默认折叠）保持原有逻辑不变。
bool isWarningTyphoon(TyphoonDetail d) =>
    predictedLandfallOf(d)?.inChinaNearSea ?? false;
