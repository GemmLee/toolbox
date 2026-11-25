import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../core/settings/tool_texts.dart';
import 'salary_stats.dart';

/// 图上的额外曲线：房贷月供、扣掉房贷后的剩余工资等。
///
/// [values] 与横轴点一一对应，元素为 null 表示该点没有值（断开而不连直线）。
class SalaryChartLine {
  const SalaryChartLine({
    required this.label,
    required this.values,
    required this.color,
    this.dashed = true,
    this.showLegend = true,
  });

  final String label;
  final List<double?> values;
  final Color color;
  final bool dashed;
  final bool showLegend;
}

/// 工资 / 社保余额折线图：自绘，无第三方图表依赖。
///
/// 纵轴默认从 0 起，也可用 [zeroBased] = false 切到「自适应」：按数据
/// (min - 半跨度, max + 半跨度) 取范围，让小幅波动看得清楚。
/// [movingAverage] 非空时叠加一条 12 个月均线（图例写作 MA12），长度不足
/// 时该线不画、图例显示「/」；[extraLines] 再叠加任意条辅助曲线。
class SalaryTrendChart extends StatelessWidget {
  const SalaryTrendChart({
    super.key,
    required this.points,
    required this.color,
    required this.legend,
    this.zeroBased = true,
    this.movingAverage,
    this.movingAverageColor = const Color(0xFFE8912D),
    this.extraLines = const <SalaryChartLine>[],
  });

  final List<SalaryPoint> points;
  final Color color;
  final String legend;
  final bool zeroBased;

  /// 与 [points] 等长的 12 月均线；元素为 null 表示该点还没有值。
  /// 整体传 null 表示当前口径不画均线（也不占图例）。
  final List<double?>? movingAverage;

  final Color movingAverageColor;

  /// 额外曲线，按顺序画在填充之上、主曲线之下。
  final List<SalaryChartLine> extraLines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ma = movingAverage;
    final latestMa = ma?.lastWhere((v) => v != null, orElse: () => null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: 176,
          child: CustomPaint(
            size: Size.infinite,
            painter: _SalaryTrendPainter(
              points: points,
              color: color,
              gridColor: scheme.outlineVariant.withOpacity(0.55),
              labelColor: scheme.onSurfaceVariant,
              fontFamily: Theme.of(context).textTheme.bodySmall?.fontFamily,
              emptyText: tr('暂无数据'),
              zeroBased: zeroBased,
              movingAverage: ma,
              movingAverageColor: movingAverageColor,
              extraLines: extraLines,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 14,
          runSpacing: 4,
          children: <Widget>[
            Row(
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
                const SizedBox(width: 6),
                Text(legend, style: const TextStyle(fontSize: 12)),
              ],
            ),
            if (ma != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _DashSwatch(color: movingAverageColor),
                  const SizedBox(width: 6),
                  Text(
                    trf('{label} {v}', {
                      'label': 'MA12',
                      'v': latestMa == null
                          ? '/'
                          : '¥${formatMoney(latestMa, digits: 0)}',
                    }),
                    key: const ValueKey('salary-chart-ma12'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            for (final line in extraLines)
              if (line.showLegend)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _DashSwatch(color: line.color),
                    const SizedBox(width: 6),
                    Text(
                      trf('{label} {v}', {
                        'label': tr(line.label),
                        'v': _latestText(line.values),
                      }),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
          ],
        ),
      ],
    );
  }

  static String _latestText(List<double?> values) {
    final latest = values.lastWhere((v) => v != null, orElse: () => null);
    return latest == null ? '/' : '¥${formatMoney(latest, digits: 0)}';
  }
}

/// 虚线图例：三段小横条，和折线图里的虚线呼应。
class _DashSwatch extends StatelessWidget {
  const _DashSwatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < 3; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 2),
          Container(width: 3, height: 2, color: color),
        ],
      ],
    );
  }
}

class _SalaryTrendPainter extends CustomPainter {
  const _SalaryTrendPainter({
    required this.points,
    required this.color,
    required this.gridColor,
    required this.labelColor,
    required this.emptyText,
    this.fontFamily,
    this.zeroBased = true,
    this.movingAverage,
    this.movingAverageColor = const Color(0xFFE8912D),
    this.extraLines = const <SalaryChartLine>[],
  });

  final List<SalaryPoint> points;
  final Color color;
  final Color gridColor;
  final Color labelColor;
  final String? fontFamily;
  final String emptyText;
  final bool zeroBased;
  final List<double?>? movingAverage;
  final Color movingAverageColor;
  final List<SalaryChartLine> extraLines;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) {
      _drawText(
          canvas, emptyText, Offset(size.width / 2 - 30, size.height / 2));
      return;
    }
    const double leftPad = 50;
    const double rightPad = 12;
    const double topPad = 10;
    const double bottomPad = 22;
    final chart = Rect.fromLTRB(
      leftPad,
      topPad,
      size.width - rightPad,
      size.height - bottomPad,
    );
    if (chart.width <= 0 || chart.height <= 0) return;

    var maxValue = points.first.value;
    var minValue = points.first.value;
    for (final p in points) {
      if (p.value > maxValue) maxValue = p.value;
      if (p.value < minValue) minValue = p.value;
    }
    // 均线与辅助线可能落在数据的上下方，纵轴范围要一起算进去，
    // 否则线会被裁掉（扣掉房贷后的净值还可能为负）。
    for (final v in movingAverage ?? const <double?>[]) {
      if (v == null) continue;
      if (v > maxValue) maxValue = v;
      if (v < minValue) minValue = v;
    }
    for (final line in extraLines) {
      for (final v in line.values) {
        if (v == null) continue;
        if (v > maxValue) maxValue = v;
        if (v < minValue) minValue = v;
      }
    }
    if (maxValue <= 0) maxValue = 1;
    // 0 起是默认口径；自适应时按 min/max 各留半个数据跨度，
    // 有 0 记录的月份仍退回 0 起，避免出现负数金额刻度。
    var bottomValue = 0.0;
    var topValue = maxValue * 1.15;
    if (minValue < 0) {
      // 净值为负说明房贷超过了到手工资：纵轴必须包含 0 以下，
      // 否则这条线会被裁到贴着底边，看不出「倒贴」。
      bottomValue = minValue * 1.15;
      topValue = maxValue > 0 ? maxValue * 1.15 : 1;
    } else if (!zeroBased && minValue > 0) {
      final span = maxValue - minValue;
      final pad = span > 0 ? span / 2 : maxValue * 0.05;
      bottomValue = (minValue - pad) < 0 ? 0 : minValue - pad;
      topValue = maxValue + pad;
    }
    final range = (topValue - bottomValue) <= 0 ? 1.0 : topValue - bottomValue;
    double xOf(int i) => points.length == 1
        ? chart.center.dx
        : chart.left + (i / (points.length - 1)) * chart.width;
    double yOf(double v) =>
        chart.bottom - ((v - bottomValue) / range) * chart.height;

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final f in <double>[0, 0.5, 1]) {
      final y = chart.top + chart.height * (1 - f);
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
      _drawText(
        canvas,
        formatMoney(bottomValue + range * f, digits: 0),
        Offset(2, (y - 6).clamp(0, size.height - 14)),
        width: leftPad - 6,
      );
    }

    // X 轴最多 5 个标签，按点序均匀抽稀。
    final step = (points.length / 5).ceil().clamp(1, points.length);
    for (var i = 0; i < points.length; i += step) {
      _drawText(
        canvas,
        points[i].label,
        Offset((xOf(i) - 26).clamp(0, size.width - 52), chart.bottom + 5),
        width: 52,
        align: TextAlign.center,
      );
    }

    canvas.save();
    canvas.clipRect(chart);
    final line = Path();
    for (var i = 0; i < points.length; i++) {
      final x = xOf(i);
      final y = yOf(points[i].value).clamp(chart.top, chart.bottom);
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
    }
    final fill = Path.from(line)
      ..lineTo(xOf(points.length - 1), chart.bottom)
      ..lineTo(xOf(0), chart.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[color.withOpacity(0.28), color.withOpacity(0.02)],
        ).createShader(
            Rect.fromLTRB(chart.left, chart.top, chart.right, chart.bottom)),
    );

    // 12 月均线画在填充之上、主曲线之下：先画会被渐变蒙住，看不清。
    final ma = movingAverage;
    if (ma != null) {
      _drawSeries(
        canvas,
        ma,
        movingAverageColor,
        dashed: true,
        xOf: xOf,
        yOf: yOf,
        chart: chart,
        width: 1.8,
      );
    }
    // 辅助线（房贷月供 / 扣除后剩余）同样在填充之上、主曲线之下。
    for (final extra in extraLines) {
      _drawSeries(
        canvas,
        extra.values,
        extra.color,
        dashed: extra.dashed,
        xOf: xOf,
        yOf: yOf,
        chart: chart,
        width: 1.8,
      );
    }

    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (points.length == 1 || points.length <= 24) {
      final dot = Paint()..color = color;
      for (var i = 0; i < points.length; i++) {
        canvas.drawCircle(
          Offset(xOf(i), yOf(points[i].value).clamp(chart.top, chart.bottom)),
          2.6,
          dot,
        );
      }
    }
    canvas.restore();
  }

  /// 画一条可空系列：跳过 null，整段断开而不是连成直线。
  void _drawSeries(
    Canvas canvas,
    List<double?> values,
    Color color, {
    required bool dashed,
    required double Function(int) xOf,
    required double Function(double) yOf,
    required Rect chart,
    required double width,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    var segment = <Offset>[];
    void flush() {
      if (segment.length > 1) {
        if (dashed) {
          _drawDashed(canvas, segment, paint);
        } else {
          final path = Path()..moveTo(segment.first.dx, segment.first.dy);
          for (final o in segment.skip(1)) {
            path.lineTo(o.dx, o.dy);
          }
          canvas.drawPath(path, paint);
        }
      }
      segment = <Offset>[];
    }

    for (var i = 0; i < points.length && i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        flush();
        continue;
      }
      segment.add(Offset(xOf(i), yOf(value).clamp(chart.top, chart.bottom)));
    }
    flush();
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset, {
    double width = 100,
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 10,
          color: labelColor,
          fontFamily: fontFamily,
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: width);
    painter.paint(canvas, offset);
  }

  /// 沿折线画虚线：按累计长度切段，拐点处相位连续，不会一格一格断。
  void _drawDashed(Canvas canvas, List<Offset> points, Paint paint) {
    const double dash = 6;
    const double gap = 4;
    var drawing = true;
    var remain = dash;
    for (var i = 1; i < points.length; i++) {
      var from = points[i - 1];
      final to = points[i];
      var rest = (to - from).distance;
      if (rest <= 0) continue;
      final dir = (to - from) / rest;
      while (rest > 0.01) {
        final step = rest < remain ? rest : remain;
        final next = from + dir * step;
        if (drawing) canvas.drawLine(from, next, paint);
        from = next;
        rest -= step;
        remain -= step;
        if (remain <= 0.01) {
          drawing = !drawing;
          remain = drawing ? dash : gap;
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SalaryTrendPainter old) =>
      old.points != points ||
      old.color != color ||
      old.zeroBased != zeroBased ||
      old.movingAverage != movingAverage ||
      old.extraLines != extraLines;
}
