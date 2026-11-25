import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import 'typhoon_api.dart';
import 'typhoon_geo.dart';

/// 经纬度基准边界框：覆盖中国东部/东南部沿海、台湾、附近海域、日本局部
/// 以及朝鲜半岛、菲律宾北部、越南中北部。
const double _bboxMinLng = kMapMinLng;
const double _bboxMaxLng = kMapMaxLng;
const double _bboxMinLat = kMapMinLat;
const double _bboxMaxLat = kMapMaxLat;

/// 默认视图中心（缩放为 1× 时视图即基准范围）。
const double _defaultCenterLng = 122.0;
const double _defaultCenterLat = 29.0;

/// 可缩放/可平移的经纬度视图（等距圆柱投影，纬度上下翻转）。
class MapView {
  const MapView({
    required this.minLng,
    required this.maxLng,
    required this.minLat,
    required this.maxLat,
  });

  /// 基准视图（1×）。
  static const MapView base = MapView(
    minLng: _bboxMinLng,
    maxLng: _bboxMaxLng,
    minLat: _bboxMinLat,
    maxLat: _bboxMaxLat,
  );

  final double minLng;
  final double maxLng;
  final double minLat;
  final double maxLat;

  @override
  bool operator ==(Object other) =>
      other is MapView &&
      other.minLng == minLng &&
      other.maxLng == maxLng &&
      other.minLat == minLat &&
      other.maxLat == maxLat;

  @override
  int get hashCode => Object.hash(minLng, maxLng, minLat, maxLat);

  Offset project(double lng, double lat, Rect rect) {
    final x = (lng - minLng) / (maxLng - minLng) * rect.width + rect.left;
    final y = (maxLat - lat) / (maxLat - minLat) * rect.height + rect.top;
    return Offset(x, y);
  }
}

/// 基准视图（1×）到任意视图的画布仿射变换。
///
/// 底图轮廓按 [MapView.base] 投影成 Path 缓存一次，绘制时用
/// `canvas.translate + canvas.scale` 复用。投影是线性的，所以「先按基准投影、
/// 再整体缩放平移」与「逐帧重新投影」在数学上等价——前提是这两个轴的
/// 缩放系数与偏移量必须推导正确，否则底图会与经纬网、台风轨迹不同步。
class MapCanvasTransform {
  const MapCanvasTransform({
    required this.sx,
    required this.sy,
    required this.tx,
    required this.ty,
  });

  /// 由 [view] 与绘制区域 [rect] 推导变换参数。
  factory MapCanvasTransform.between(MapView view, Rect rect) {
    const base = MapView.base;
    final baseLngSpan = base.maxLng - base.minLng;
    final baseLatSpan = base.maxLat - base.minLat;
    final sx = baseLngSpan / (view.maxLng - view.minLng);
    final sy = baseLatSpan / (view.maxLat - view.minLat);
    final kLng = rect.width / baseLngSpan;
    final kLat = rect.height / baseLatSpan;
    // base: x0 = rect.left + (lng - base.minLng) * kLng
    // view: x1 = rect.left + (lng - view.minLng) * kLng * sx
    // 消去 lng 得 x1 = sx * x0 + rect.left * (1 - sx)
    //              + (base.minLng - view.minLng) * kLng * sx
    final tx =
        rect.left * (1 - sx) + (base.minLng - view.minLng) * kLng * sx;
    // base: y0 = rect.top + (base.maxLat - lat) * kLat
    // view: y1 = rect.top + (view.maxLat - lat) * kLat * sy
    // 纬度上下翻转，所以偏移项是 (view.maxLat - base.maxLat) 而非反过来的。
    final ty =
        rect.top * (1 - sy) + (view.maxLat - base.maxLat) * kLat * sy;
    return MapCanvasTransform(sx: sx, sy: sy, tx: tx, ty: ty);
  }

  final double sx;
  final double sy;
  final double tx;
  final double ty;

  Offset apply(Offset basePoint) =>
      Offset(basePoint.dx * sx + tx, basePoint.dy * sy + ty);

  /// 线宽补偿：画布被缩放后，1px 的线会变成 sx/sy 倍。
  double get strokeScale => (sx + sy) / 2;
}

/// 视图变化通知：只让画布重绘，不重建控件树。
///
/// 捏合时每帧都会变更视图，走 setState 会把整张卡片（Stack、缩放按钮、
/// 图例）一起重建一遍，这是缩放「发涩」的原因之一。
class _ViewRepaint extends ChangeNotifier {
  MapView _view = MapView.base;

  MapView get view => _view;

  void update(MapView value) {
    if (_view == value) return;
    _view = value;
    notifyListeners();
  }
}

/// 兼容旧调用：按基准视图投影。
Offset projectLngLat(double lng, double lat, Rect rect) =>
    MapView.base.project(lng, lat, rect);

/// 取「月/日」，如 2026-02-05 06:30:00 → 02/05。
String formatMonthDay(String time) {
  final s = time.trim();
  if (s.isEmpty) return '';
  final parts = s.split(' ').first.split('-');
  if (parts.length < 3) return '';
  return '${parts[1]}/${parts[2]}';
}

/// 城市标注点。
class _City {
  const _City(this.name, this.lng, this.lat, this.landfall, this.partOfChina);
  final String name;
  final double lng;
  final double lat;
  final bool landfall; // 台风常登陆城市
  final bool partOfChina; // 是否中国领土（含港澳台）
}

/// 主要城市（华东/华南沿海地级市与省会，以及台湾城市；日本为外国局部）。
const List<_City> _cities = <_City>[
  // 中国华东/华南
  _City('上海', 121.47, 31.23, true, true),
  _City('杭州', 120.15, 30.27, false, true),
  _City('宁波', 121.55, 29.87, true, true),
  _City('舟山', 122.20, 30.00, true, true),
  _City('台州', 121.43, 28.66, true, true),
  _City('温州', 120.65, 28.00, true, true),
  _City('福州', 119.30, 26.08, true, true),
  _City('厦门', 118.10, 24.46, true, true),
  _City('汕头', 116.68, 23.35, true, true),
  _City('深圳', 114.06, 22.55, false, true),
  _City('广州', 113.26, 23.13, false, true),
  _City('香港', 114.17, 22.32, true, true),
  _City('澳门', 113.55, 22.20, true, true),
  _City('海口', 110.20, 20.04, true, true),
  _City('三亚', 109.50, 18.25, true, true),
  _City('湛江', 110.36, 21.27, true, true),
  _City('青岛', 120.38, 36.07, true, true),
  _City('连云港', 119.16, 34.60, false, true),
  _City('南京', 118.80, 32.06, false, true),
  _City('合肥', 117.27, 31.86, false, true),
  _City('南昌', 115.86, 28.68, false, true),
  _City('武汉', 114.30, 30.60, false, true),
  _City('长沙', 112.94, 28.23, false, true),
  // 台湾（中国）
  _City('台北', 121.56, 25.03, true, true),
  _City('高雄', 120.30, 22.62, true, true),
  // 日本（外国，局部）
  _City('东京', 139.69, 35.69, false, false),
  _City('大阪', 135.50, 34.69, false, false),
  _City('福冈', 130.40, 33.59, false, false),
];

/// 省界虚线与陆地填充直接使用离线生成数据（../tools/geo/gen_typhoon_geo.py），
/// 数据本身已按视图范围裁剪并简化，无需运行时再细分。

class _TextMark {
  const _TextMark(this.name, this.lng, this.lat);
  final String name;
  final double lng;
  final double lat;
}

/// 海域文字标注（仅标注名称，不绘制任何争议性边界）。
const List<_TextMark> _seaLabels = <_TextMark>[
  _TextMark('黄海', 122.5, 37.5),
  _TextMark('东海', 126.5, 30.5),
  _TextMark('南海', 113.5, 18.6),
  _TextMark('太平洋', 135.5, 26.5),
];

/// 陆地区域文字标注：只标周边国家（省级行政区一律不标省名，含台湾、海南）。
///
/// 台湾、海南与大陆同色填充（中国领土），不再单独标注省名。
class _RegionLabel {
  const _RegionLabel(this.name, this.lng, this.lat, this.isChina);
  final String name;
  final double lng;
  final double lat;
  final bool isChina;
}

const List<_RegionLabel> _regionLabels = <_RegionLabel>[
  _RegionLabel('日本', 136.4, 36.5, false),
  _RegionLabel('朝鲜', 127.1, 40.2, false),
  _RegionLabel('韩国', 127.8, 36.6, false),
  _RegionLabel('菲律宾', 121.1, 17.2, false),
  _RegionLabel('越南', 105.6, 20.3, false),
];

const double _pad = 6.0;

/// 台风路径示意图：自绘底图 + API 返回的路径点与当前中心。
///
/// 支持双指捏合缩放（1×–4×，以捏合中心为锚点）与单指/双指拖拽平移；
/// 省界用虚线绘制且不标省名；路径按 API 返回的强度分级着色。
class TyphoonMap extends StatefulWidget {
  const TyphoonMap({
    super.key,
    required this.points,
    this.centerLng,
    this.centerLat,
    this.land = const <Landing>[],
    this.radius7,
    this.radius10,
    this.radius12,
    this.forecasts = const <ForecastTrack>[],
    this.predictedLandfall,
    this.height = 320,
    this.onViewChanged,
  });

  final List<TrackPoint> points;
  final double? centerLng;
  final double? centerLat;
  final List<Landing> land;

  /// 当前时刻 7 / 10 / 12 级风圈的四象限半径（km）。
  final WindRadii? radius7;
  final WindRadii? radius10;
  final WindRadii? radius12;

  /// 最近一个实况时刻的各机构预报路径。
  final List<ForecastTrack> forecasts;

  /// 预计登陆地点（无有效登陆/预报数据时为 null）。
  final PredictedLandfall? predictedLandfall;

  final double height;

  /// 视图变化回调（供测试/外部观察缩放与平移结果）。
  final ValueChanged<MapView>? onViewChanged;

  @override
  State<TyphoonMap> createState() => _TyphoonMapState();
}

class _TyphoonMapState extends State<TyphoonMap> {
  static const double minZoom = 1.0;
  static const double maxZoom = 4.0;
  static const double zoomStep = 0.5;

  double _zoom = minZoom;
  double _panLng = 0;
  double _panLat = 0;

  /// 画布重绘信号（不触发控件重建）。
  final _ViewRepaint _repaint = _ViewRepaint();

  @override
  void dispose() {
    _repaint.dispose();
    super.dispose();
  }

  /// 视图中心经度：优先台风当前中心，其次路径重心，最后默认中心。
  double get _targetLng {
    final c = widget.centerLng;
    if (c != null) return c;
    final pts =
        widget.points.where((p) => p.lng != null).toList(growable: false);
    if (pts.isEmpty) return _defaultCenterLng;
    return pts.map((p) => p.lng!).reduce((a, b) => a + b) / pts.length;
  }

  /// 视图中心纬度。
  double get _targetLat {
    final c = widget.centerLat;
    if (c != null) return c;
    final pts =
        widget.points.where((p) => p.lat != null).toList(growable: false);
    if (pts.isEmpty) return _defaultCenterLat;
    return pts.map((p) => p.lat!).reduce((a, b) => a + b) / pts.length;
  }

  double get _halfLng => (_bboxMaxLng - _bboxMinLng) / 2 / _zoom;
  double get _halfLat => (_bboxMaxLat - _bboxMinLat) / 2 / _zoom;

  /// 平移偏移的允许范围：保证视图中心落在基准范围内，不露出无底图数据区。
  double _clampPanLng(double v) => v.clamp(
        _bboxMinLng + _halfLng - _targetLng,
        _bboxMaxLng - _halfLng - _targetLng,
      );

  double _clampPanLat(double v) => v.clamp(
        _bboxMinLat + _halfLat - _targetLat,
        _bboxMaxLat - _halfLat - _targetLat,
      );

  double _halfLngAt(double zoom) => (_bboxMaxLng - _bboxMinLng) / 2 / zoom;
  double _halfLatAt(double zoom) => (_bboxMaxLat - _bboxMinLat) / 2 / zoom;

  /// 当前缩放/平移下的可视范围。
  MapView get _view {
    final cx = (_targetLng + _panLng)
        .clamp(_bboxMinLng + _halfLng, _bboxMaxLng - _halfLng);
    final cy = (_targetLat + _panLat)
        .clamp(_bboxMinLat + _halfLat, _bboxMaxLat - _halfLat);
    return MapView(
      minLng: cx - _halfLng,
      maxLng: cx + _halfLng,
      minLat: cy - _halfLat,
      maxLat: cy + _halfLat,
    );
  }

  /// 双指捏合缩放 / 单指平移的统一入口。
  ///
  /// [centroidDelta] 为手指中心的移动量，[scaleRatio] 为两次事件间的距离比
  /// （单指时恒为 1），[focal] 为捏合中心在画布内的局部坐标——缩放以该点为
  /// 锚点，保证手指捏住的地理位置不漂移。
  void _onGesture(
    Offset centroidDelta,
    double scaleRatio,
    Offset focal,
    double width,
    double height,
  ) {
    if (scaleRatio != 1.0) {
      final v = _view;
      final cx0 = (v.minLng + v.maxLng) / 2;
      final cy0 = (v.minLat + v.maxLat) / 2;
      final hLng0 = _halfLng;
      final hLat0 = _halfLat;
      final t = (focal.dx / width).clamp(0.0, 1.0);
      final u = (focal.dy / height).clamp(0.0, 1.0);
      // 捏合中心对应的经纬度（缩放前后保持不动）
      final lngF = cx0 - hLng0 + 2 * hLng0 * t;
      final latF = cy0 + hLat0 - 2 * hLat0 * u;
      final z1 = (_zoom * scaleRatio).clamp(minZoom, maxZoom);
      final hLng1 = _halfLngAt(z1);
      final hLat1 = _halfLatAt(z1);
      final cx1 = (lngF - (2 * t - 1) * hLng1)
          .clamp(_bboxMinLng + hLng1, _bboxMaxLng - hLng1);
      final cy1 = (latF + (2 * u - 1) * hLat1)
          .clamp(_bboxMinLat + hLat1, _bboxMaxLat - hLat1);
      _zoom = z1;
      _panLng = cx1 - _targetLng;
      _panLat = cy1 - _targetLat;
    }
    final hLng = _halfLng;
    final hLat = _halfLat;
    // 平移后立即夹紧，避免视图已到边界时偏移量仍在累积，
    // 反向拖动需要「先抵消累积量」才动。
    _panLng = _clampPanLng(_panLng - centroidDelta.dx / width * 2 * hLng);
    _panLat = _clampPanLat(_panLat + centroidDelta.dy / height * 2 * hLat);
    _emit();
  }

  /// 推送视图变化：重绘画布 + 通知外部。
  void _emit() {
    _repaint.update(_view);
    widget.onViewChanged?.call(_view);
  }

  void _setZoom(double v) {
    _zoom = v.clamp(minZoom, maxZoom);
    _panLng = _clampPanLng(_panLng);
    _panLat = _clampPanLat(_panLat);
    _emit();
  }

  void _reset() {
    _zoom = minZoom;
    _panLng = 0;
    _panLat = 0;
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = widget.height;
          Widget map = RepaintBoundary(
            child: CustomPaint(
              key: const ValueKey('typhoon-map-canvas'),
              size: Size(width, height),
              painter: TyphoonMapPainter(
                points: widget.points,
                centerLng: widget.centerLng,
                centerLat: widget.centerLat,
                land: widget.land,
                radius7: widget.radius7,
                radius10: widget.radius10,
                radius12: widget.radius12,
                forecasts: widget.forecasts,
                predictedLandfall: widget.predictedLandfall,
                isDark: theme.brightness == Brightness.dark,
                view: _repaint.view,
                viewOf: () => _repaint.view,
                repaint: _repaint,
              ),
            ),
          );
          // 地图是手势封闭区：手指一落到画布上就接管，捏合缩放与单指平移
          // 都在这里消化，页面不会跟着上下滚动（1× 时没有平移余量，拖动
          // 就地停住，不会穿透到外层列表）。要滚动页面请在画布以外拖动。
          map = RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactory>{
              _MapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<_MapGestureRecognizer>(
                _MapGestureRecognizer.new,
                (instance) {
                  instance.onUpdate = (d, scale, focal) =>
                      _onGesture(d, scale, focal, width, height);
                },
              ),
            },
            child: map,
          );
          return Stack(
            children: <Widget>[
              map,
              Positioned(
                right: 6,
                bottom: 6,
                child: AnimatedBuilder(
                  animation: _repaint,
                  builder: (context, _) => _zoomControls(theme),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _zoomControls(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withOpacity(0.9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.35)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _ZoomButton(
            key: const ValueKey('typhoon-map-zoom-in'),
            icon: Icons.add,
            tooltip: tr('放大'),
            enabled: _zoom < maxZoom,
            onTap: () => _setZoom(_zoom + zoomStep),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(
              '${_zoom.toStringAsFixed(1)}×',
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
            ),
          ),
          _ZoomButton(
            key: const ValueKey('typhoon-map-zoom-out'),
            icon: Icons.remove,
            tooltip: tr('缩小'),
            enabled: _zoom > minZoom,
            onTap: () => _setZoom(_zoom - zoomStep),
          ),
          if (_zoom > minZoom)
            _ZoomButton(
              key: const ValueKey('typhoon-map-zoom-reset'),
              icon: Icons.refresh,
              tooltip: tr('复位'),
              enabled: true,
              onTap: _reset,
            ),
        ],
      ),
    );
  }
}

/// 支持单指平移 + 双指捏合缩放的即时识别器（无 slop，按下即接管）。
///
/// 地图是手势封闭区：任何一根手指落到画布上都会立刻赢下自己那一场
/// 竞技场，外层 ListView / RefreshIndicator 因此拿不到这个指针。
class _MapGestureRecognizer extends OneSequenceGestureRecognizer {
  /// 回调参数：中心移动量、距离比（单指恒为 1）、捏合中心（局部坐标）。
  void Function(Offset centroidDelta, double scaleRatio, Offset focal)?
      onUpdate;

  final Map<int, Offset> _pointers = <int, Offset>{};
  Offset? _lastCentroid;
  double? _lastSpan;

  Offset _centroid() {
    var x = 0.0;
    var y = 0.0;
    for (final p in _pointers.values) {
      x += p.dx;
      y += p.dy;
    }
    return Offset(x / _pointers.length, y / _pointers.length);
  }

  double _span() {
    final pts = _pointers.values.toList(growable: false);
    var max = 0.0;
    for (int i = 0; i < pts.length; i++) {
      for (int j = i + 1; j < pts.length; j++) {
        final d = (pts[i] - pts[j]).distance;
        if (d > max) max = d;
      }
    }
    return max;
  }

  void _resetRef() {
    if (_pointers.isEmpty) {
      _lastCentroid = null;
      _lastSpan = null;
      return;
    }
    _lastCentroid = _centroid();
    _lastSpan = _pointers.length >= 2 ? _span() : null;
  }

  @override
  void addPointer(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    startTrackingPointer(event.pointer, event.transform);
    // 每一根手指都要各自赢下竞技场。
    //
    // 只在「第一根手指」时 resolve 是有 bug 的：第二根手指的竞技场会一直
    // 悬空，双指同时上下移动超过 touch slop 后，外层 ScrollView 的那个
    // 指针成员就会被判胜，于是页面被拉着上下跑（表现为下拉刷新或上滑）。
    resolve(GestureDisposition.accepted);
    // 新手指加入后重算基准：否则质心会从上一帧的位置瞬间跳变，
    // 双指按下的瞬间画面会「跳一下」。
    _resetRef();
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && _pointers.containsKey(event.pointer)) {
      _pointers[event.pointer] = event.localPosition;
      final c = _centroid();
      if (_pointers.length >= 2) {
        final span = _span();
        final ratio =
            (_lastSpan != null && _lastSpan! > 0) ? span / _lastSpan! : 1.0;
        onUpdate?.call(
          _lastCentroid == null ? Offset.zero : c - _lastCentroid!,
          ratio,
          c,
        );
        _lastSpan = span;
      } else {
        onUpdate?.call(
          _lastCentroid == null ? Offset.zero : c - _lastCentroid!,
          1.0,
          c,
        );
        _lastSpan = null;
      }
      _lastCentroid = c;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointers.remove(event.pointer);
      stopTrackingPointer(event.pointer);
      _resetRef();
    }
  }

  @override
  void rejectGesture(int pointer) {
    // 手势竞技场判负（理论上不会发生，因为按下即 accepted）：清理状态。
    _pointers.remove(pointer);
    stopTrackingPointer(pointer);
    _resetRef();
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  void dispose() {
    _pointers.clear();
    super.dispose();
  }

  @override
  String get debugDescription => 'map pan & pinch';
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 36,
        height: 34,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 20,
          tooltip: tooltip,
          onPressed: enabled ? onTap : null,
          icon: Icon(icon),
        ),
      );
}

/// 强度配色：热带低压 → 超强台风由冷到暖。
Color typhoonStrengthColor(TyphoonStrength s, {bool dark = false}) {
  if (dark) {
    return switch (s) {
      TyphoonStrength.tropicalDepression => const Color(0xFF4FC3F7),
      TyphoonStrength.tropicalStorm => const Color(0xFF81C784),
      TyphoonStrength.severeTropicalStorm => const Color(0xFFFFCA28),
      TyphoonStrength.typhoon => const Color(0xFFFFA726),
      TyphoonStrength.severeTyphoon => const Color(0xFFEF5350),
      TyphoonStrength.superTyphoon => const Color(0xFFF06292),
      TyphoonStrength.unknown => const Color(0xFF90A4AE),
    };
  }
  return switch (s) {
    TyphoonStrength.tropicalDepression => const Color(0xFF29B6F6),
    TyphoonStrength.tropicalStorm => const Color(0xFF43A047),
    TyphoonStrength.severeTropicalStorm => const Color(0xFFF9A825),
    TyphoonStrength.typhoon => const Color(0xFFEF6C00),
    TyphoonStrength.severeTyphoon => const Color(0xFFD32F2F),
    TyphoonStrength.superTyphoon => const Color(0xFFAD1457),
    TyphoonStrength.unknown => const Color(0xFF78909C),
  };
}

/// 图例中展示的强度顺序（由弱到强）。
const List<TyphoonStrength> kLegendStrengths = <TyphoonStrength>[
  TyphoonStrength.tropicalDepression,
  TyphoonStrength.tropicalStorm,
  TyphoonStrength.severeTropicalStorm,
  TyphoonStrength.typhoon,
  TyphoonStrength.severeTyphoon,
  TyphoonStrength.superTyphoon,
];

/// 底图几何缓存：经纬度轮廓只在 [Size] 变化时投影一次。
///
/// 平移/缩放时用「画布变换」复用这些 Path——投影是线性的，先按基准视图
/// 建一次 Path，再整体缩放平移，像素结果与逐帧重投影完全一致。这样每帧
/// 的工作量从「近 2000 个顶点投影 + 数百次 drawLine」降到十几次 drawPath，
/// 是双指缩放不再发涩的关键。
class _MapGeometry {
  _MapGeometry._(this.china, this.foreign, this.province);

  final List<Path> china;
  final List<Path> foreign;

  /// 省界虚线（已按基准像素切好段，缩放时随画布等比放大）。
  final Path province;

  static Size? _cachedSize;
  static _MapGeometry? _cached;

  static _MapGeometry of(Size size) {
    final cached = _cached;
    if (cached != null && _cachedSize == size) return cached;
    final rect = Rect.fromLTWH(
      _pad,
      _pad,
      size.width - _pad * 2,
      size.height - _pad * 2,
    );
    List<Path> rings(List<List<List<double>>> source) => <Path>[
          for (final ring in source)
            () {
              final path = Path();
              for (var i = 0; i < ring.length; i++) {
                final o = MapView.base.project(ring[i][0], ring[i][1], rect);
                if (i == 0) {
                  path.moveTo(o.dx, o.dy);
                } else {
                  path.lineTo(o.dx, o.dy);
                }
              }
              return path..close();
            }(),
        ];
    final province = Path();
    for (final seg in chinaProvinceBorders) {
      final pts = <Offset>[
        for (final p in seg) MapView.base.project(p[0], p[1], rect),
      ];
      _appendDashed(province, pts, 6, 4);
    }
    final geometry = _MapGeometry._(
      rings(chinaLandRings),
      rings(neighborLandRings),
      province,
    );
    _cachedSize = size;
    _cached = geometry;
    return geometry;
  }

  /// 把折线按 [dash]/[gap] 切成虚线追加到 [target]（一次性，非每帧）。
  static void _appendDashed(
    Path target,
    List<Offset> pts,
    double dash,
    double gap,
  ) {
    for (var i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final delta = pts[i + 1] - a;
      final dist = delta.distance;
      if (dist < 0.001) continue;
      final dir = delta / dist;
      var s = 0.0;
      while (s < dist) {
        final e = (s + dash).clamp(0.0, dist).toDouble();
        final p0 = a + dir * s;
        final p1 = a + dir * e;
        target.moveTo(p0.dx, p0.dy);
        target.lineTo(p1.dx, p1.dy);
        s += dash + gap;
      }
    }
  }
}

class TyphoonMapPainter extends CustomPainter {
  TyphoonMapPainter({
    required this.points,
    this.centerLng,
    this.centerLat,
    this.land = const <Landing>[],
    this.radius7,
    this.radius10,
    this.radius12,
    this.forecasts = const <ForecastTrack>[],
    this.predictedLandfall,
    this.isDark = false,
    this.view = MapView.base,
    this.viewOf,
    super.repaint,
  });

  final List<TrackPoint> points;
  final double? centerLng;
  final double? centerLat;
  final List<Landing> land;
  final WindRadii? radius7;
  final WindRadii? radius10;
  final WindRadii? radius12;
  final List<ForecastTrack> forecasts;
  final PredictedLandfall? predictedLandfall;
  final bool isDark;

  /// 当前视图。捏合时由 [viewOf] 每帧取最新值（不重建 widget）。
  MapView view;

  final MapView Function()? viewOf;

  /// 文字排版缓存：每帧为几十个标注重新 layout 一次是另一处主要开销。
  static final Map<String, TextPainter> _labelCache = <String, TextPainter>{};

  /// 强度配色：热带低压→超强台风由冷到暖。
  Color strengthColor(TyphoonStrength s) =>
      typhoonStrengthColor(s, dark: isDark);

  @override
  void paint(Canvas canvas, Size size) {
    final latest = viewOf?.call();
    if (latest != null) view = latest;
    final rect = Rect.fromLTWH(
      _pad,
      _pad,
      size.width - _pad * 2,
      size.height - _pad * 2,
    );

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));

    // 海域背景
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()
        ..color = isDark ? const Color(0xFF0E2233) : const Color(0xFFD6E7F2),
    );

    _drawGraticule(canvas, rect);
    _drawLand(canvas, rect, size);
    _drawMarks(canvas, rect, _seaLabels, Colors.blueGrey, 12, 0.6);
    _drawRegionLabels(canvas, rect);
    _drawCities(canvas, rect);
    _drawWindRadii(canvas, rect);
    _drawForecastTracks(canvas, rect);
    _drawTrack(canvas, rect);
    _drawLandfalls(canvas, rect);
    _drawPredictedLandfall(canvas, rect);
    _drawCenter(canvas, rect);

    canvas.restore();
  }

  /// 陆地填充 + 海岸线 + 省界：一次画布变换复用缓存 Path。
  void _drawLand(Canvas canvas, Rect rect, Size size) {
    final geometry = _MapGeometry.of(size);
    final t = MapCanvasTransform.between(view, rect);

    canvas.save();
    canvas.translate(t.tx, t.ty);
    canvas.scale(t.sx, t.sy);

    final chinaFill = Paint()
      ..color = isDark ? const Color(0xFF2C3A28) : const Color(0xFFD9E8C6);
    final foreignFill = Paint()
      ..color = isDark ? const Color(0xFF36312A) : const Color(0xFFE7E0D2);
    for (final path in geometry.foreign) {
      canvas.drawPath(path, foreignFill);
    }
    for (final path in geometry.china) {
      canvas.drawPath(path, chinaFill);
    }

    // 线宽跟着画布缩放走，除一下还原成屏幕像素宽度。
    final stroke = t.strokeScale;
    final coast = Paint()
      ..color = isDark
          ? Colors.white.withOpacity(0.28)
          : Colors.black.withOpacity(0.22)
      ..strokeWidth = 1 / stroke
      ..style = PaintingStyle.stroke;
    for (final path in geometry.foreign) {
      canvas.drawPath(path, coast);
    }
    for (final path in geometry.china) {
      canvas.drawPath(path, coast);
    }

    canvas.drawPath(
      geometry.province,
      Paint()
        ..color = isDark
            ? Colors.white.withOpacity(0.32)
            : Colors.brown.shade400.withOpacity(0.9)
        ..strokeWidth = 1.2 / stroke
        ..style = PaintingStyle.stroke,
    );

    canvas.restore();
  }

  void _drawGraticule(Canvas canvas, Rect rect) {
    final lngSpan = view.maxLng - view.minLng;
    final step = lngSpan < 15 ? 2.0 : 5.0;
    final line = Paint()
      ..color = (isDark ? Colors.white : Colors.black).withOpacity(0.08)
      ..strokeWidth = 1;
    for (double lng = (view.minLng / step).ceil() * step;
        lng <= view.maxLng;
        lng += step) {
      final a = view.project(lng, view.maxLat, rect);
      final b = view.project(lng, view.minLat, rect);
      canvas.drawLine(a, b, line);
    }
    for (double lat = (view.minLat / step).ceil() * step;
        lat <= view.maxLat;
        lat += step) {
      final a = view.project(view.minLng, lat, rect);
      final b = view.project(view.maxLng, lat, rect);
      canvas.drawLine(a, b, line);
    }
  }

  void _drawMarks(
    Canvas canvas,
    Rect rect,
    List<_TextMark> marks,
    Color base,
    double fontSize,
    double opacity,
  ) {
    for (final m in marks) {
      final o = view.project(m.lng, m.lat, rect);
      _drawLabel(canvas, o, m.name, base.withOpacity(opacity), fontSize);
    }
  }

  void _drawRegionLabels(Canvas canvas, Rect rect) {
    for (final r in _regionLabels) {
      final o = view.project(r.lng, r.lat, rect);
      final color = r.isChina
          ? (isDark ? Colors.white70 : Colors.black54)
          : (isDark ? Colors.white38 : Colors.brown.shade400);
      _drawLabel(canvas, o, r.name, color, 11);
    }
  }

  void _drawCities(Canvas canvas, Rect rect) {
    final landfall = Paint()..color = Colors.redAccent;
    final normal = Paint()
      ..color = isDark ? Colors.lightBlue.shade200 : Colors.blueGrey;
    final labelColor = isDark ? Colors.white70 : Colors.black87;
    for (final c in _cities) {
      final o = view.project(c.lng, c.lat, rect);
      if (c.landfall) {
        canvas.drawCircle(
          o,
          5.5,
          Paint()..color = Colors.redAccent.withOpacity(0.22),
        );
        canvas.drawCircle(o, 3.2, landfall);
      } else {
        canvas.drawCircle(o, 2.2, normal);
      }
      final rightAlign = o.dx > rect.right - 34;
      _drawLabel(
        canvas,
        o,
        c.name,
        labelColor,
        c.landfall ? 10 : 9,
        rightAlign: rightAlign,
      );
    }
  }

  /// 主台风路径：每一段与每个路径点按 API 返回的强度着色。
  void _drawTrack(Canvas canvas, Rect rect) {
    final valid = points
        .where((p) => p.lng != null && p.lat != null)
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    if (valid.isEmpty) return;
    for (int i = 0; i < valid.length - 1; i++) {
      final a = view.project(valid[i].lng!, valid[i].lat!, rect);
      final b = view.project(valid[i + 1].lng!, valid[i + 1].lat!, rect);
      // 线段取后一个点的强度，与「该时刻已达到的强度」一致。
      final color = strengthColor(parseStrength(valid[i + 1].strong));
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = color
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
    }
    for (final p in valid) {
      final o = view.project(p.lng!, p.lat!, rect);
      final s = parseStrength(p.strong);
      canvas.drawCircle(o, 2.8, Paint()..color = strengthColor(s));
    }
    // 终点：最后一次更新的位置，标注月/日
    final last = valid.last;
    final lo = view.project(last.lng!, last.lat!, rect);
    canvas.drawCircle(
      lo,
      5.5,
      Paint()
        ..color = Colors.deepPurple
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final md = formatMonthDay(last.time);
    if (md.isNotEmpty) {
      _drawLabel(
        canvas,
        lo,
        md,
        isDark ? Colors.purple.shade200 : Colors.deepPurple,
        10,
        rightAlign: lo.dx > rect.right - 40,
      );
    }
  }

  /// 风圈：7 / 10 / 12 级四象限半径，浅色扇形打底 + 彩色弧形描边。
  ///
  /// 半径是 km，按当前纬度换算成经纬度再投影；Flutter 画布 y 轴向下，
  /// 所以东北象限是 -90°→0°、东南 0°→90°、西南 90°→180°、西北 180°→270°。
  void _drawWindRadii(Canvas canvas, Rect rect) {
    final lng = centerLng;
    final lat = centerLat;
    if (lng == null || lat == null) return;
    if (radius7 == null && radius10 == null && radius12 == null) return;

    final o = view.project(lng, lat, rect);
    final pxPerLng = (view.project(lng + 1, lat, rect).dx - o.dx).abs();
    final pxPerLat = (view.project(lng, lat + 1, rect).dy - o.dy).abs();
    final kmPerLng = 111.32 * math.cos(lat * math.pi / 180);
    if (kmPerLng <= 0) return;
    double rx(double km) => km / kmPerLng * pxPerLng;
    double ry(double km) => km / 110.57 * pxPerLat;

    final levels = <(WindRadii? radii, Color fill, Color stroke, bool fillIt)>[
      (
        radius7,
        isDark ? const Color(0x1A64B5F6) : const Color(0x1442A5F5),
        isDark ? const Color(0x6682B1FF) : const Color(0x665B9BD5),
        true,
      ),
      (
        radius10,
        Colors.transparent,
        isDark ? const Color(0x77FFB74D) : const Color(0x88F09A3B),
        false,
      ),
      (
        radius12,
        Colors.transparent,
        isDark ? const Color(0x88EF9A9A) : const Color(0x99E05252),
        false,
      ),
    ];

    for (final level in levels) {
      final r = level.$1;
      if (r == null) continue;
      final fillPaint = Paint()..color = level.$2;
      final arcPaint = Paint()
        ..color = level.$3
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      final quadrants = <(double radius, double start)>[
        (r.ne, -math.pi / 2),
        (r.se, 0.0),
        (r.sw, math.pi / 2),
        (r.nw, math.pi),
      ];
      for (final q in quadrants) {
        if (q.$1 <= 0) continue;
        final bounds = Rect.fromCenter(
          center: o,
          width: 2 * rx(q.$1),
          height: 2 * ry(q.$1),
        );
        if (level.$4) {
          final wedge = Path()
            ..moveTo(o.dx, o.dy)
            ..arcTo(bounds, q.$2, math.pi / 2, false)
            ..close();
          canvas.drawPath(wedge, fillPaint);
        }
        canvas.drawArc(bounds, q.$2, math.pi / 2, false, arcPaint);
      }
    }
  }

  /// 预报路径：虚线。中国气象局为主路径（较粗、带预报节点），
  /// 其余机构用浅色细虚线示意分歧，画在主路径之前避免盖住它。
  void _drawForecastTracks(Canvas canvas, Rect rect) {
    if (forecasts.isEmpty) return;
    final ordered = List<ForecastTrack>.from(forecasts)
      ..sort((a, b) => (a.isChina ? 1 : 0).compareTo(b.isChina ? 1 : 0));
    for (final f in ordered) {
      final pts = f.validPoints;
      if (pts.length < 2) continue;
      final offsets = <Offset>[
        for (final p in pts) view.project(p.lng!, p.lat!, rect),
      ];
      final dashed = Path();
      _MapGeometry._appendDashed(dashed, offsets, 6, 5);
      final main = f.isChina;
      final color = main
          ? (isDark ? Colors.tealAccent.shade100 : Colors.teal.shade700)
          : (isDark ? Colors.white38 : Colors.blueGrey.withOpacity(0.45));
      canvas.drawPath(
        dashed,
        Paint()
          ..color = color
          ..strokeWidth = main ? 2.2 : 1.2
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
      if (main) {
        final dot = Paint()..color = color;
        for (final off in offsets.skip(1)) {
          canvas.drawCircle(off, 2.2, dot);
        }
      }
    }
  }

  /// 预计登陆地点：橙色圆环 + 文字标注，与历史登陆点的三角标记区分。
  void _drawPredictedLandfall(Canvas canvas, Rect rect) {
    final p = predictedLandfall;
    if (p == null) return;
    final o = view.project(p.lng, p.lat, rect);
    final color = isDark ? Colors.orange.shade200 : Colors.orange.shade800;
    canvas.drawCircle(o, 10, Paint()..color = color.withOpacity(0.18));
    canvas.drawCircle(
      o,
      6,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _drawLabel(
      canvas,
      o,
      tr('预计登陆点'),
      color,
      10,
      rightAlign: o.dx > rect.right - 68,
    );
  }

  void _drawLandfalls(Canvas canvas, Rect rect) {
    for (final l in land) {
      if (l.lng == null || l.lat == null) continue;
      final o = view.project(l.lng!, l.lat!, rect);
      final paint = Paint()..color = Colors.deepOrange;
      final path = Path();
      path.moveTo(o.dx, o.dy - 6);
      path.lineTo(o.dx + 5, o.dy - 3);
      path.lineTo(o.dx, o.dy);
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  void _drawCenter(Canvas canvas, Rect rect) {
    if (centerLng == null || centerLat == null) return;
    final o = view.project(centerLng!, centerLat!, rect);
    canvas.drawCircle(o, 11, Paint()..color = Colors.red.withOpacity(0.18));
    canvas.drawCircle(o, 7, Paint()..color = Colors.red);
    canvas.drawCircle(
      o,
      7,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _drawLabel(canvas, o, '台', Colors.white, 11, centered: true);
  }

  void _drawLabel(
    Canvas canvas,
    Offset o,
    String text,
    Color color,
    double fontSize, {
    bool centered = false,
    bool rightAlign = false,
  }) {
    final tp = _label(text, color, fontSize, centered: centered);
    double dx = o.dx + 4;
    double dy = o.dy - fontSize - 2;
    if (centered) {
      dx = o.dx - tp.width / 2;
      dy = o.dy - tp.height / 2;
    } else if (rightAlign) {
      dx = o.dx - tp.width - 4;
    }
    tp.paint(canvas, Offset(dx, dy));
  }

  /// 取（或首次排版）一个标注的 TextPainter。
  ///
  /// 标注文字与字号在一张图里是固定集合，逐帧 `layout()` 纯属浪费——
  /// 捏合时一帧要排几十段文字，缓存后只做绘制。
  static TextPainter _label(
    String text,
    Color color,
    double fontSize, {
    required bool centered,
  }) {
    final key = '$text|$fontSize|${color.value}|$centered';
    final cached = _labelCache[key];
    if (cached != null) return cached;
    if (_labelCache.length > 400) _labelCache.clear();
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: centered ? TextAlign.center : TextAlign.left,
    )..layout();
    _labelCache[key] = painter;
    return painter;
  }

  @override
  bool shouldRepaint(covariant TyphoonMapPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.centerLng != centerLng ||
      oldDelegate.centerLat != centerLat ||
      oldDelegate.land != land ||
      oldDelegate.radius7 != radius7 ||
      oldDelegate.radius10 != radius10 ||
      oldDelegate.radius12 != radius12 ||
      oldDelegate.forecasts != forecasts ||
      oldDelegate.predictedLandfall != predictedLandfall ||
      oldDelegate.isDark != isDark ||
      oldDelegate.view != view;
}
