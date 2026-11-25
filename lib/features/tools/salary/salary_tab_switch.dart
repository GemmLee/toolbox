import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';

/// 顶部切换条的一项。
class SalaryTabItem {
  const SalaryTabItem({required this.icon, required this.label});

  final IconData icon;

  /// 简体中文源文案，展示时由外层过 tr()。
  final String label;
}

/// 三段式页签：选中的展开成「图标 + 名字」的胶囊，其余缩成圆球。
///
/// 切换时不是各自独立拉长/缩短，而是用一条连续的位置值驱动三颗胶囊：
/// 相邻两颗按权重此消彼长，权重之和恒为 1，所以整条总宽度全程不变，
/// 视觉上像选中态从旧位置「分裂」，再粘到新位置。
/// 点击切页与滑动切页共用同一个动画状态。
class SalaryTabSwitch extends StatefulWidget {
  const SalaryTabSwitch({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
    this.height = 38,
    this.collapsedWidth = 38,
    this.minExpandedWidth = 150,
  });

  final List<SalaryTabItem> items;
  final int index;
  final ValueChanged<int> onChanged;

  /// 胶囊高度；未选中时宽度与高度相等，就是一个圆球。
  final double height;
  final double collapsedWidth;

  /// 展开胶囊的最小宽度；文案更长时按文字宽度自动加宽。
  final double minExpandedWidth;

  static const double _iconSize = 18;
  static const double _gap = 7;
  static const double _spacing = 4;
  static const double _sidePadding = 24;
  static const Duration _duration = Duration(milliseconds: 300);

  @override
  State<SalaryTabSwitch> createState() => _SalaryTabSwitchState();
}

class _SalaryTabSwitchState extends State<SalaryTabSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: SalaryTabSwitch._duration,
    reverseDuration: SalaryTabSwitch._duration,
    // 单一控制器直接表示「当前位置」，上限要能覆盖最后一个页签。
    upperBound: math.max(1, widget.items.length - 1).toDouble(),
    value: widget.index.toDouble(),
  );

  @override
  void didUpdateWidget(SalaryTabSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == oldWidget.index) return;
    _controller.animateTo(
      widget.index.toDouble().clamp(0.0, (widget.items.length - 1).toDouble()),
      duration: SalaryTabSwitch._duration,
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      height: 1.2,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final labels = <String>[for (final item in widget.items) tr(item.label)];
    final labelWidths = <double>[
      for (final label in labels) _measure(label, style, scaler),
    ];

    // 三颗胶囊共用同一个展开宽度，总宽才不会在切换过程中变化。
    // 取最宽文案为准，短文案在胶囊内居中；上限防止超大字号挤出屏幕。
    final expanded = math.min(
      math.max(
        widget.minExpandedWidth,
        labelWidths
            .map((w) =>
                w +
                SalaryTabSwitch._iconSize +
                SalaryTabSwitch._gap +
                SalaryTabSwitch._sidePadding * 2)
            .reduce(math.max),
      ),
      200.0,
    );
    const outerGap = SalaryTabSwitch._spacing * 2;
    final totalWidth = widget.collapsedWidth * labels.length +
        (expanded - widget.collapsedWidth) +
        outerGap * labels.length;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        // 连续位置：两个整数之间时，相邻两颗权重相加恒为 1。
        // 这就是「分裂 — 粘合」——旧胶囊让出的宽度正好被新胶囊接住。
        final position = _controller.value;
        final weights = <double>[
          for (var i = 0; i < labels.length; i++)
            (1 - (position - i).abs()).clamp(0.0, 1.0),
        ];
        final widths = <double>[
          for (final w in weights)
            widget.collapsedWidth + (expanded - widget.collapsedWidth) * w,
        ];

        final lefts = <double>[];
        var cursor = 0.0;
        for (final width in widths) {
          lefts.add(cursor + SalaryTabSwitch._spacing);
          cursor += width + outerGap;
        }

        // 切换中相邻两颗都占有一半权重时，在它们之间画一条「液桥」：
        // 腰部随融合强度收放，营出两团液体先粘连、再拉开的手感。
        final bridges = <_LiquidBridge>[];
        for (var i = 0; i + 1 < weights.length; i++) {
          final fusion = 4 * weights[i] * weights[i + 1];
          if (fusion > 0.01) {
            bridges.add(_LiquidBridge(
              left: lefts[i] + widths[i],
              right: lefts[i + 1],
              fusion: fusion,
            ));
          }
        }
        // 胶囊是半透明的，液桥收腰曲线会轻微侵入两端胶囊。若直接画在下层，
        // 灰色胶囊上会透出上下两道主题色带；把胶囊轮廓从液桥里挖掉即可。
        final capsuleRects = <Rect>[
          for (var i = 0; i < labels.length; i++)
            Rect.fromLTWH(lefts[i], 0, widths[i], widget.height),
        ];

        return SizedBox(
          height: widget.height + 8,
          child: Center(
            child: SizedBox(
              width: totalWidth,
              height: widget.height,
              child: Stack(
                children: <Widget>[
                  if (bridges.isNotEmpty)
                    Positioned.fill(
                      child: CustomPaint(
                        key: const ValueKey('salary-liquid-bridge'),
                        painter: _LiquidBridgePainter(
                          bridges: bridges,
                          capsuleRects: capsuleRects,
                          height: widget.height,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  for (var i = 0; i < labels.length; i++)
                    Positioned(
                      left: lefts[i],
                      top: 0,
                      width: widths[i],
                      height: widget.height,
                      child: _buildPill(
                        scheme: scheme,
                        label: labels[i],
                        labelWidth: labelWidths[i],
                        weight: weights[i],
                        width: widths[i],
                        style: style,
                        index: i,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPill({
    required ColorScheme scheme,
    required String label,
    required double labelWidth,
    required double weight,
    required double width,
    required TextStyle style,
    required int index,
  }) {
    const icon = SalaryTabSwitch._iconSize;
    const gap = SalaryTabSwitch._gap;
    final contentWidth = icon + gap + labelWidth;
    // 收成圆球时图标居中；展开后整段「图标 + 文字」居中。
    final iconLeft = _lerp(
      (width - icon) / 2,
      (width - contentWidth) / 2,
      weight,
    );
    // 后半程才让文字出场，避免胶囊还没让出位置就被裁切。
    final labelT = ((weight - 0.5) / 0.5).clamp(0.0, 1.0);
    final foreground =
        Color.lerp(scheme.onSurfaceVariant, scheme.onPrimary, weight)!;

    return Material(
      color: Color.lerp(
          scheme.onSurface.withOpacity(0.07), scheme.primary, weight),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('salary-tab-$index'),
        onTap: () => widget.onChanged(index),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            Positioned(
              left: iconLeft,
              top: (widget.height - icon) / 2,
              width: icon,
              height: icon,
              child:
                  Icon(widget.items[index].icon, size: icon, color: foreground),
            ),
            if (labelT > 0)
              Positioned(
                left: iconLeft + icon + gap,
                top: 0,
                bottom: 0,
                child: Opacity(
                  opacity: labelT,
                  child: Transform.translate(
                    offset: Offset(-6 * (1 - labelT), 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: style.copyWith(color: foreground),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static double _measure(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    return painter.width;
  }
}

/// 相邻两颗胶囊之间的一段液桥。[fusion] 0→1 表示从刚粘上到完全融合。
class _LiquidBridge {
  const _LiquidBridge({
    required this.left,
    required this.right,
    required this.fusion,
  });

  final double left;
  final double right;
  final double fusion;
}

/// 把液桥画成两端带圆弧、中间收腰的连通带。
///
/// 两端圆弧的圆心/半径与相邻胶囊的半圆端完全一致：胶囊是 StadiumBorder，
/// 端部是半径 height/2 的半圆，圆心落在 [left]/[right] 往里一个半径处。
/// 最后把胶囊轮廓从液桥中挖掉：液桥只在两胶囊之间可见，既保持圆弧融合的
/// 外形，又不会隔着半透明胶囊透出主题色带。
class _LiquidBridgePainter extends CustomPainter {
  const _LiquidBridgePainter({
    required this.bridges,
    required this.capsuleRects,
    required this.height,
    required this.color,
  });

  final List<_LiquidBridge> bridges;
  final List<Rect> capsuleRects;
  final double height;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    const stadium = StadiumBorder();
    final capsules = Path();
    for (final rect in capsuleRects) {
      capsules.addPath(stadium.getOuterPath(rect), Offset.zero);
    }
    final r = height / 2;
    const minWaist = 1.5;

    for (final bridge in bridges) {
      // 左/右圆心分别与左胶囊右半圆、右胶囊左半圆重合。
      final leftCx = bridge.left - r;
      final rightCx = bridge.right + r;
      final mid = (leftCx + rightCx) / 2;
      // 腰线内缩：完全融合时几乎拉平，刚粘上时收成细丝。
      final waist = minWaist + (height * 0.30 - minWaist) * (1 - bridge.fusion);
      final path = Path()
        ..moveTo(leftCx, 0)
        // 上缘：两端贴着胶囊顶边，中间向下收腰（控制点与旧实现一致）。
        ..quadraticBezierTo(mid, waist, rightCx, 0)
        // 右端圆弧：顶 → 最左 → 底（逆时针），与右胶囊左端半圆重合。
        ..arcTo(
          Rect.fromLTWH(rightCx - r, 0, height, height),
          -90,
          -180,
          false,
        )
        // 下缘：两端贴着胶囊底边，中间向上收腰。
        ..quadraticBezierTo(mid, height - waist, leftCx, height)
        // 左端圆弧：底 → 最右 → 顶（逆时针），与左胶囊右端半圆重合。
        ..arcTo(
          Rect.fromLTWH(leftCx - r, 0, height, height),
          90,
          -180,
          false,
        )
        ..close();
      // 挖掉胶囊覆盖区：只留两胶囊之间的液桥，不污染半透明胶囊。
      canvas.drawPath(
        Path.combine(PathOperation.difference, path, capsules),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LiquidBridgePainter old) =>
      old.bridges != bridges ||
      old.capsuleRects != capsuleRects ||
      old.height != height ||
      old.color != color;
}
