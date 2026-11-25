import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';

/// 上下行多点测速折线图：两条线共用同一纵轴刻度，便于直接比较速率。
///
/// 采样点按序号均分横轴（每次采样耗时不同，不按真实时间定位，避免慢点把
/// 曲线拉长）；纵轴上限取全部点的最大值再留 15% 余量。
class SpeedChart extends StatelessWidget {
  const SpeedChart({
    super.key,
    required this.down,
    required this.up,
  });

  final List<double> down;
  final List<double> up;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final downColor = scheme.primary;
    const upColor = Color(0xFFF0A22E);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: 118,
          child: CustomPaint(
            size: Size.infinite,
            painter: _SpeedChartPainter(
              down: down,
              up: up,
              downColor: downColor,
              upColor: upColor,
              gridColor: scheme.outlineVariant.withOpacity(0.55),
              labelColor: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            _legend(downColor, tr('下行速率')),
            const SizedBox(width: 16),
            _legend(upColor, tr('上行速率')),
          ],
        ),
      ],
    );
  }

  Widget _legend(Color color, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 12,
            height: 3,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      );
}

class _SpeedChartPainter extends CustomPainter {
  const _SpeedChartPainter({
    required this.down,
    required this.up,
    required this.downColor,
    required this.upColor,
    required this.gridColor,
    required this.labelColor,
  });

  final List<double> down;
  final List<double> up;
  final Color downColor;
  final Color upColor;
  final Color gridColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    const padLeft = 4.0;
    const padRight = 4.0;
    const padTop = 16.0;
    const padBottom = 4.0;
    final w = size.width - padLeft - padRight;
    final h = size.height - padTop - padBottom;
    if (w <= 0 || h <= 0) return;

    var peak = 0.0;
    for (final v in <double>[...down, ...up]) {
      if (v > peak) peak = v;
    }
    final double maxV =
        (peak * 1.15).clamp(1.0, double.infinity).toDouble();

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final f in <double>[0, 0.5, 1]) {
      final y = padTop + h * f;
      canvas.drawLine(Offset(padLeft, y), Offset(size.width - padRight, y), grid);
    }

    final label = TextPainter(
      text: TextSpan(
        text: '${maxV.toStringAsFixed(1)} Mbps',
        style: TextStyle(color: labelColor, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, const Offset(padLeft, 1));

    double xOf(int i, int n) =>
        padLeft + (n <= 1 ? w / 2 : w * i / (n - 1));
    double yOf(double v) => padTop + h - (v / maxV) * h;

    void drawSeries(List<double> values, Color color, bool fill) {
      if (values.isEmpty) return;
      final path = Path()
        ..moveTo(xOf(0, values.length), yOf(values.first));
      for (var i = 1; i < values.length; i++) {
        path.lineTo(xOf(i, values.length), yOf(values[i]));
      }
      if (fill && values.length > 1) {
        final area = Path.from(path)
          ..lineTo(xOf(values.length - 1, values.length), padTop + h)
          ..lineTo(xOf(0, values.length), padTop + h)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                color.withOpacity(0.26),
                color.withOpacity(0.02),
              ],
            ).createShader(Offset.zero & size),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = fill ? 2.2 : 1.8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      final dots = Paint()..color = color;
      for (var i = 0; i < values.length; i++) {
        canvas.drawCircle(
          Offset(xOf(i, values.length), yOf(values[i])),
          2.2,
          dots,
        );
      }
    }

    drawSeries(down, downColor, true);
    drawSeries(up, upColor, false);
  }

  @override
  bool shouldRepaint(covariant _SpeedChartPainter old) =>
      !_same(old.down, down) ||
      !_same(old.up, up) ||
      old.downColor != downColor ||
      old.upColor != upColor ||
      old.gridColor != gridColor ||
      old.labelColor != labelColor;

  static bool _same(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
