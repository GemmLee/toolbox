import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import 'measure_geometry.dart';

/// 屏幕量角器：半圆刻度 + 可拖动的指针臂，直接读出 0~180°。
class ProtractorView extends StatefulWidget {
  const ProtractorView({
    super.key,
    this.fullscreen = false,
    this.onExitFullscreen,
    this.onFullscreen,
  });

  /// 全屏模式：隐藏说明卡片，悬浮显示读数。
  final bool fullscreen;

  /// 全屏时由页面提供的退出按钮。
  final Widget? onExitFullscreen;

  /// 普通模式下的「进入全屏」回调；为空时不显示全屏按钮。
  final VoidCallback? onFullscreen;

  @override
  State<ProtractorView> createState() => _ProtractorViewState();
}

/// 半圆顶边与上方内容的最小间距。
const double _topGap = 22;

/// 基线下方保留的余量（手指拖到 0°/180° 附近时不至于贴死底边）。
const double _bottomGap = 20;

/// 量角器在画布里的位置与半径。
class _ProtractorGeometry {
  const _ProtractorGeometry(this.pivot, this.radius);

  final Offset pivot;
  final double radius;

  /// 圆心与半径：半径受宽度与可用高度双重限制；
  /// 普通模式贴着上方卡片放下（竖屏时不再沉到屏幕底部、与卡片之间空出一大块），
  /// 全屏模式上下居中，接近实体量角器的使用姿态。
  static _ProtractorGeometry of(Size size, {bool fullscreen = false}) {
    final byWidth = size.width / 2 - 12;
    final byHeight = size.height - _topGap - _bottomGap;
    final radius = math.min(byWidth, byHeight);
    if (radius <= 0) return const _ProtractorGeometry(Offset.zero, 0);
    final pivotY =
        fullscreen ? (size.height + radius) / 2 : _topGap + radius;
    return _ProtractorGeometry(Offset(size.width / 2, pivotY), radius);
  }

  @override
  bool operator ==(Object other) =>
      other is _ProtractorGeometry &&
      other.pivot == pivot &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(pivot, radius);
}

class _ProtractorViewState extends State<ProtractorView> {
  double _angle = 45;

  void _setFromOffset(Offset canvasPoint, _ProtractorGeometry geometry) {
    final raw =
        MeasureGeometry.angleFromPoint(geometry.pivot, canvasPoint);
    setState(() => _angle = MeasureGeometry.snapAngle(raw));
  }

  /// 量角器本体的包围盒：拖动 / 点按只在半圆附近生效，
  /// 包围盒外仍可左右滑动切换分页，互不冲突。
  Widget _gestureRegion(BoxConstraints constraints, ThemeData theme) {
    final size = Size(constraints.maxWidth, constraints.maxHeight);
    final geometry =
        _ProtractorGeometry.of(size, fullscreen: widget.fullscreen);
    final radius = geometry.radius;
    if (radius <= 10) {
      return _canvas(theme, size, geometry);
    }
    // 手势盒的左上角在画布坐标系里的位置。
    final origin = Offset(
      size.width / 2 - radius - 20,
      geometry.pivot.dy - radius - 20,
    );
    return Stack(
      key: const ValueKey('protractor-canvas'),
      fit: StackFit.expand,
      children: [
        _canvas(theme, size, geometry),
        // 手势区比半圆大一圈，覆盖手柄。
        //
        // 手势识别不能用 GestureDetector 的 onPan*（36px 启动阈值，
        // 横向拖动会被 TabBarView 的 18px 抢走），也不能拆成横向 +
        // 纵向两个识别器（一个方向赢下竞技场后另一方向就不再更新，
        // 沿弧线拖到 0°/180° 附近会有明显阻力）。这里用自定义的
        // 「零延迟全向」识别器：按下立即接管，任意方向的移动都
        // 持续更新角度，拖动跟手且量角器附近翻页手势被隔离。
        Positioned(
          left: origin.dx,
          top: origin.dy,
          width: radius * 2 + 40,
          height: size.height - origin.dy,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactoryWithHandlers<
                _InstantPanGestureRecognizer>>{
              _InstantPanGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                      _InstantPanGestureRecognizer>(
                () => _InstantPanGestureRecognizer(),
                (_InstantPanGestureRecognizer instance) {
                  instance.onStart = (details) =>
                      _setFromOffset(details.localPosition + origin, geometry);
                  instance.onUpdate = (details) =>
                      _setFromOffset(details.localPosition + origin, geometry);
                },
              ),
            },
          ),
        ),
      ],
    );
  }

  Widget _canvas(ThemeData theme, Size size, _ProtractorGeometry geometry) {
    return CustomPaint(
      size: size,
      painter: _ProtractorPainter(
        geometry: geometry,
        angle: _angle,
        scheme: theme.colorScheme,
        labelStyle: theme.textTheme.labelSmall ?? const TextStyle(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (widget.fullscreen) {
      return LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            _gestureRegion(constraints, theme),
            Align(
              alignment: AlignmentDirectional.topStart,
              child: Padding(
                padding: const EdgeInsets.only(left: 14, top: 14),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: scheme.surface.withOpacity(0.82),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_angle.toStringAsFixed(1)}° · '
                    '${tr('补角')} ${(180 - _angle).toStringAsFixed(1)}°',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (widget.onExitFullscreen != null)
              Align(
                alignment: AlignmentDirectional.topEnd,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10, top: 10),
                  child: widget.onExitFullscreen!,
                ),
              ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _angle.toStringAsFixed(1),
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8, left: 2),
                      child: Text(
                        '°',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: scheme.primary,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${tr('补角')} ${(180 - _angle).toStringAsFixed(1)}°',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _zoneLabel(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    if (widget.onFullscreen != null) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        key: const ValueKey('protractor-fullscreen-btn'),
                        onPressed: widget.onFullscreen,
                        icon: const Icon(Icons.fullscreen, size: 20),
                        tooltip: tr('全屏'),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                // 预设角度：小号 chip 固定单行，空间不足时可横向滚动，
                // 不再折成两行占用纵向空间。
                SizedBox(
                  height: 34,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        for (final preset in MeasureGeometry.presetAngles)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: ChoiceChip(
                              label: Text('$preset°'),
                              labelPadding: const EdgeInsets.symmetric(
                                  horizontal: 7),
                              labelStyle: theme.textTheme.labelSmall,
                              selected: (_angle - preset).abs() < 0.26,
                              visualDensity: const VisualDensity(
                                  horizontal: -4, vertical: -4),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onSelected: (_) => setState(
                                  () => _angle = preset.toDouble()),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SmallHint(
                  text: tr('拖动指针臂量角；把被测角的一边贴住量角器基线、顶点对准圆心。'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) =>
                _gestureRegion(constraints, theme),
          ),
        ),
      ],
    );
  }

  String _zoneLabel() {
    if (_angle < 0.5) return tr('重合');
    if ((_angle - 90).abs() < 0.5) return tr('直角');
    if (_angle < 90) return tr('锐角');
    if ((_angle - 180).abs() < 0.5) return tr('平角');
    return tr('钝角');
  }
}

class _ProtractorPainter extends CustomPainter {
  _ProtractorPainter({
    required this.geometry,
    required this.angle,
    required this.scheme,
    required this.labelStyle,
  });

  final _ProtractorGeometry geometry;
  final double angle;
  final ColorScheme scheme;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final pivot = geometry.pivot;
    final radius = geometry.radius;
    if (radius <= 10) return;

    // 半圆底
    final body = Path()
      ..moveTo(pivot.dx - radius, pivot.dy)
      ..arcTo(
        Rect.fromCircle(center: pivot, radius: radius),
        math.pi,
        math.pi,
        false,
      )
      ..close();
    canvas.drawPath(
      body,
      Paint()..color = scheme.surfaceContainerHighest.withOpacity(0.35),
    );
    canvas.drawArc(
      Rect.fromCircle(center: pivot, radius: radius),
      math.pi,
      math.pi,
      false,
      Paint()
        ..color = scheme.outline.withOpacity(0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    // 直边基线
    canvas.drawLine(
      Offset(pivot.dx - radius, pivot.dy),
      Offset(pivot.dx + radius, pivot.dy),
      Paint()
        ..color = scheme.outline.withOpacity(0.35)
        ..strokeWidth = 1,
    );

    for (var deg = 0; deg <= 180; deg++) {
      final rad = MeasureGeometry.degreesToRadians(deg.toDouble());
      final dir = Offset(math.cos(rad), -math.sin(rad));
      final isTen = deg % 10 == 0;
      final isFive = deg % 5 == 0;
      final len = isTen ? 16.0 : (isFive ? 10.0 : 5.0);
      canvas.drawLine(
        pivot + dir * radius,
        pivot + dir * (radius - len),
        Paint()
          ..color = scheme.onSurface.withOpacity(isTen ? 0.75 : 0.35)
          ..strokeWidth = isTen ? 1.3 : 0.9,
      );
      if (isTen) {
        final tp = TextPainter(
          text: TextSpan(
            text: '$deg',
            style: labelStyle.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 10,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final pos = pivot + dir * (radius - 30);
        tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
      }
    }

    // 指针臂
    final rad = MeasureGeometry.degreesToRadians(angle);
    final dir = Offset(math.cos(rad), -math.sin(rad));
    canvas.drawLine(
      pivot,
      pivot + dir * (radius - 6),
      Paint()
        ..color = scheme.primary
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    // 角度指示弧：从 0° 基线沿逆时针方向画到指针臂，
    // 直观显示当前量到的角（屏幕坐标 y 向下，向上是负角方向）。
    canvas.drawArc(
      Rect.fromCircle(center: pivot, radius: radius * 0.42),
      -rad,
      rad,
      false,
      Paint()
        ..color = scheme.primary.withOpacity(0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // 圆心 + 拖动手柄
    canvas.drawCircle(pivot, 5, Paint()..color = scheme.primary);
    canvas.drawCircle(
      pivot + dir * (radius - 6),
      9,
      Paint()..color = scheme.primary,
    );
    canvas.drawCircle(
      pivot + dir * (radius - 6),
      4,
      Paint()..color = scheme.surface,
    );
  }

  @override
  bool shouldRepaint(covariant _ProtractorPainter old) =>
      old.angle != angle ||
      old.scheme != scheme ||
      old.geometry != geometry;
}

/// 「零延迟全向」拖动识别器：指针按下立即接管手势竞技场，
/// 之后任意方向的移动都持续回调（没有启动阈值，也没有方向偏好）。
///
/// 用于量角器：指针臂的拖动方向随角度变化（0°/180° 附近以纵向为主，
/// 90° 附近以横向为主），任何带 slop / 方向判断的识别器都会在某个
/// 区间出现「拖不动」或被翻页抢走。
class _InstantPanGestureRecognizer extends OneSequenceGestureRecognizer {
  _InstantPanGestureRecognizer();

  GestureDragStartCallback? onStart;
  GestureDragUpdateCallback? onUpdate;

  final Set<int> _pointers = <int>{};

  @override
  void addPointer(PointerDownEvent event) {
    _pointers.add(event.pointer);
    startTrackingPointer(event.pointer, event.transform);
    // 按下即赢下竞技场：没有 slop，量角器区域内的翻页手势同时被隔离。
    resolve(GestureDisposition.accepted);
    onStart?.call(DragStartDetails(
      globalPosition: event.position,
      localPosition: event.localPosition,
    ));
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && _pointers.contains(event.pointer)) {
      onUpdate?.call(DragUpdateDetails(
        globalPosition: event.position,
        localPosition: event.localPosition,
        delta: event.delta,
      ));
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _release(event.pointer);
    }
  }

  void _release(int pointer) {
    _pointers.remove(pointer);
    stopTrackingPointer(pointer);
    if (_pointers.isEmpty) {
      // 竞技场早已关闭（本识别器已胜出），此调用是安全的收尾。
      resolve(GestureDisposition.rejected);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  void dispose() {
    _pointers.clear();
    super.dispose();
  }

  @override
  String get debugDescription => 'instant pan';
}
