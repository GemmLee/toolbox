import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import 'measure_geometry.dart';

/// 屏幕尺子：按校准后的「逻辑像素 / 厘米」绘制真实厘米刻度，
/// 并带两个可拖动的测量标记（A / B）读出两点距离。
class RulerView extends StatefulWidget {
  const RulerView({
    super.key,
    required this.pxPerCm,
    required this.onCalibrate,
    required this.onReset,
    this.fullscreen = false,
    this.onExitFullscreen,
    this.onFullscreen,
  });

  final double pxPerCm;
  final VoidCallback onCalibrate;
  final VoidCallback onReset;

  /// 普通模式下的「进入全屏」回调；为空时不显示全屏按钮。

  /// 全屏模式：隐藏说明卡片，刻度带垂直居中，并悬浮显示读数。
  final bool fullscreen;

  /// 全屏时由页面提供的退出按钮（浮在视图之上）。
  final Widget? onExitFullscreen;

  /// 普通模式下的「进入全屏」回调；为空时不显示全屏按钮。
  final VoidCallback? onFullscreen;

  @override
  State<RulerView> createState() => _RulerViewState();
}

class _RulerViewState extends State<RulerView> {
  static const double _bandHeight = 132;

  /// A / B 标记的位置（厘米）。
  double _a = 0.5;
  double _b = 4.0;
  bool _draggingA = true;

  double get _lengthCm => (_b - _a).abs();

  void _moveTo(Offset local, double maxCm) {
    var cm = MeasureGeometry.pxToCm(local.dx, widget.pxPerCm);
    cm = cm.clamp(0.0, maxCm);
    setState(() {
      if (_draggingA) {
        _a = cm;
      } else {
        _b = cm;
      }
    });
  }

  void _pickNearest(Offset local, double aCm, double bCm) {
    final positions = <double>[
      MeasureGeometry.cmToPx(aCm, widget.pxPerCm),
      MeasureGeometry.cmToPx(bCm, widget.pxPerCm),
    ];
    _draggingA = (local.dx - positions[0]).abs() <=
        (local.dx - positions[1]).abs();
  }

  /// 读数悬浮条（全屏模式用）。
  Widget _readoutChip(ColorScheme scheme, TextTheme textTheme) {
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, top: 14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surface.withOpacity(0.82),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                MeasureGeometry.formatCm(_lengthCm),
                key: const ValueKey('ruler-fullscreen-cm'),
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 2),
                child: Text(
                  'cm',
                  style: textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${MeasureGeometry.formatMm(_lengthCm)} mm',
                style: textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // 普通模式：说明卡片 + 刻度区。
    if (!widget.fullscreen) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            tr('A → B 距离'),
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        InfoHint(
                          text: tr('拖动 A / B 两条竖线量取长度；0 刻度从屏幕左边缘起算，把物体紧贴手机左边缘即可。'),
                        ),
                        TextButton.icon(
                          onPressed: widget.onCalibrate,
                          icon: const Icon(Icons.straighten, size: 16),
                          label: Text(tr('校准')),
                        ),
                        IconButton(
                          onPressed: widget.onReset,
                          icon: const Icon(Icons.restart_alt, size: 18),
                          tooltip: tr('重置校准'),
                          visualDensity: VisualDensity.compact,
                        ),
                        if (widget.onFullscreen != null)
                          IconButton(
                            key: const ValueKey('ruler-fullscreen-btn'),
                            onPressed: widget.onFullscreen,
                            icon: const Icon(Icons.fullscreen, size: 20),
                            tooltip: tr('全屏'),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          MeasureGeometry.formatCm(_lengthCm),
                          key: const ValueKey('ruler-length-cm'),
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.primary,
                            height: 1.1,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4, left: 2),
                          child: Text(
                            'cm',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: Text(
                            '${MeasureGeometry.formatMm(_lengthCm)} mm',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _buildCanvas(context, theme),
          ),
        ],
      );
    }

    // 全屏模式：整屏都是刻度区 + 悬浮读数 / 退出按钮。
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildCanvas(context, theme),
        _readoutChip(scheme, theme.textTheme),
        if (widget.onExitFullscreen != null)
          Align(
            alignment: AlignmentDirectional.topEnd,
            child: Padding(
              padding: const EdgeInsets.only(right: 10, top: 10),
              child: widget.onExitFullscreen!,
            ),
          ),
      ],
    );
  }

  /// 刻度画布。拖动手势只覆盖刻度带附近，避免整屏都是拖动区。
  Widget _buildCanvas(BuildContext context, ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight;
        // 全屏时刻度带垂直居中，普通模式贴上方。
        final bandTop =
            widget.fullscreen ? (maxHeight - _bandHeight) / 2 : 34.0;
        final maxCm = MeasureGeometry.visibleWidthCm(
            constraints.maxWidth, widget.pxPerCm);
        // 屏幕变窄时把标记收回可视范围。
        final a = _a.clamp(0.0, maxCm);
        final b = _b.clamp(0.0, maxCm);
        return Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _RulerPainter(
                pxPerCm: widget.pxPerCm,
                aCm: a,
                bCm: b,
                scheme: theme.colorScheme,
                textStyle: theme.textTheme.labelSmall ?? const TextStyle(),
                labelStyle: theme.textTheme.bodySmall ?? const TextStyle(),
                bandHeight: _bandHeight,
                bandTop: bandTop,
              ),
            ),
            // 拖动区：只覆盖刻度带上下各一小段，其余区域留给页面滑动。
            Positioned(
              left: 0,
              right: 0,
              top: (bandTop - 54).clamp(0.0, maxHeight),
              height: _bandHeight + 110,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  _pickNearest(details.localPosition, a, b);
                  _moveTo(details.localPosition, maxCm);
                },
                onHorizontalDragStart: (details) =>
                    _pickNearest(details.localPosition, a, b),
                onHorizontalDragUpdate: (details) =>
                    _moveTo(details.localPosition, maxCm),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.pxPerCm,
    required this.aCm,
    required this.bCm,
    required this.scheme,
    required this.textStyle,
    required this.labelStyle,
    required this.bandHeight,
    required this.bandTop,
  });

  final double pxPerCm;
  final double aCm;
  final double bCm;
  final ColorScheme scheme;
  final TextStyle textStyle;
  final TextStyle labelStyle;
  final double bandHeight;
  final double bandTop;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = bandTop + bandHeight - 26;
    final band = Rect.fromLTRB(0, bandTop, size.width, bandTop + bandHeight);

    final bg = Paint()
      ..color = scheme.surfaceContainerHighest.withOpacity(0.45);
    canvas.drawRRect(
      RRect.fromRectAndRadius(band, const Radius.circular(14)),
      bg,
    );
    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      Paint()
        ..color = scheme.outlineVariant
        ..strokeWidth = 1.2,
    );

    final tickPaint = Paint()
      ..color = scheme.onSurface.withOpacity(0.72)
      ..strokeWidth = 1;

    final maxCm = size.width / pxPerCm;
    // 每 0.1cm 一个小刻度；分辨率过低时稀疏成 0.2cm，避免糊成一片。
    final step = pxPerCm * 0.1 < 4.0 ? 0.2 : 0.1;
    for (var cm = 0.0; cm <= maxCm + 1e-6; cm += step) {
      final x = cm * pxPerCm;
      if (x > size.width) break;
      final isCm = (cm * 10).round() % 10 == 0;
      final isHalf = !isCm && (cm * 10).round() % 5 == 0;
      final len = isCm ? 30.0 : (isHalf ? 20.0 : 11.0);
      canvas.drawLine(
        Offset(x, baseline),
        Offset(x, baseline - len),
        tickPaint
          ..strokeWidth = isCm ? 1.4 : 1
          ..color = isCm
              ? scheme.onSurface.withOpacity(0.85)
              : scheme.onSurface.withOpacity(0.5),
      );
      if (isCm) {
        final tp = TextPainter(
          text: TextSpan(
            text: cm.toInt().toString(),
            style: textStyle.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x + 3, baseline + 4));
      }
    }

    void marker(double cm, String label, Color color) {
      final x = cm * pxPerCm;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 2;
      canvas.drawLine(Offset(x, bandTop - 2), Offset(x, baseline + 22), paint);
      // 手柄
      canvas.drawCircle(
          Offset(x, bandTop - 12), 11, paint..style = PaintingStyle.fill);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: labelStyle.copyWith(
            color: AppTheme.readableOn(color),
            fontWeight: FontWeight.w700,
            fontSize: 11,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, bandTop - 12 - tp.height / 2));
    }

    // 两点之间的区间高亮
    final left = (aCm < bCm ? aCm : bCm) * pxPerCm;
    final right = (aCm < bCm ? bCm : aCm) * pxPerCm;
    canvas.drawRect(
      Rect.fromLTRB(
          left, bandTop + bandHeight - 20, right, bandTop + bandHeight - 14),
      Paint()..color = scheme.primary.withOpacity(0.30),
    );

    marker(aCm, 'A', scheme.primary);
    marker(bCm, 'B', scheme.tertiary);
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.pxPerCm != pxPerCm ||
      old.aCm != aCm ||
      old.bCm != bCm ||
      old.bandTop != bandTop ||
      old.scheme != scheme;
}
