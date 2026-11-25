import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import 'quiz_common.dart';

/// 圆环线宽（相对圆环边长的比例）。
///
/// 已刷是底层粗环，错题环覆盖在它上层、略细一点，让两段比例能同时读出来。
/// 抽成常量便于测试钉住「两层都要足够粗」。
const double kRingStrokeFactor = 0.135;
const double kWrongRingStrokeFactor = 0.62;

/// 已刷环用主题色与卡片底色混合后的「浅主题色」，比错题红环柔和。
/// 用不透明混色而不是固定透明度，浅色 / 深色主题下都稳定不会发灰。
Color seenRingColor(ColorScheme scheme) =>
    Color.lerp(scheme.primary, scheme.surface, 0.46) ?? scheme.primary;

/// 圆环两段占比：已刷题目 / 错题，按题目总数归一到 [0, 1]。
///
/// 抽成纯函数便于单测；题库为空时两段都是 0，只画灰色底环。
({double seen, double wrong}) ringFractions(QuizStats stats) {
  double fraction(int value) => stats.questionCount <= 0
      ? 0.0
      : (value / stats.questionCount).clamp(0.0, 1.0).toDouble();
  return (seen: fraction(stats.seenCount), wrong: fraction(stats.wrongCount));
}

/// 圆环内缘直径：扣掉两侧粗环线宽和 2px 抗锯齿余量。
double ringInnerDiameter(double side,
        {double strokeFactor = kRingStrokeFactor}) =>
    math.max(0.0, side - 2 * side * strokeFactor - 4);

/// 环内内容可用区 relative to 内缘直径：留出圆形内切的边距，
/// 数字与两行标记都不会压到粗环上。
const double kRingInnerWidthFactor = 0.72;
const double kRingInnerHeightFactor = 0.66;

/// 数字近似等宽，每位约占字号的 0.62；用于按位数估算实际占宽。
const double kRingDigitWidthFactor = 0.62;

/// 中心题目数的动态字号：位数越多字越小，保证一千多道题也不会盖到圆环上。
///
/// 以圆环内缘可用宽度除以「位数 × 单字宽」得到上限，再取设计字号中的较小值；
/// 极端长数字还有 [BankStatsRing] 内的 FittedBox 做二次兜底缩放。
double ringTotalFontSize({required double side, required int total}) {
  final usable = ringInnerDiameter(side) * kRingInnerWidthFactor;
  final digits = math.max(1, total.abs().toString().length);
  final fitted = usable / (digits * kRingDigitWidthFactor);
  final ideal = side * 0.28;
  return math.min(ideal, fitted).clamp(11.0, 64.0).toDouble();
}

/// 统计大卡与统计详情共用的圆环。
///
/// 粗环是已刷题目，细环（后画、覆盖在粗环上层）是错题；环内显示题目总数
/// 与「已刷 / 错题」两个计数标记，不再有独立的「题目」标签和外置图例。
class BankStatsRing extends StatelessWidget {
  const BankStatsRing({
    super.key,
    required this.stats,
    this.size = 180,
    this.withLegend = true,
  });

  final QuizStats stats;
  final double size;

  /// 是否在圆环内显示「已刷 / 错题」两个计数标记。
  final bool withLegend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fractions = ringFractions(stats);
    final seen = seenRingColor(scheme);
    final totalFont = ringTotalFontSize(side: size, total: stats.questionCount);
    final legendFont = (totalFont * 0.30).clamp(9.5, 14.0).toDouble();
    final inner = ringInnerDiameter(size);
    final total = '${stats.questionCount}';

    return SizedBox(
      key: const ValueKey('stats-ring'),
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          track: scheme.outlineVariant.withOpacity(0.28),
          seenColor: seen,
          wrongColor: scheme.error,
          seen: fractions.seen,
          wrong: fractions.wrong,
        ),
        child: Center(
          child: SizedBox(
            // 环内矩形完全落在内圆里，FittedBox 再把内容整体缩放进去。
            width: inner * kRingInnerWidthFactor,
            height: inner * kRingInnerHeightFactor,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    total,
                    key: const ValueKey('stats-ring-total'),
                    maxLines: 1,
                    softWrap: false,
                    style: (theme.textTheme.displaySmall ?? const TextStyle())
                        .copyWith(
                      fontSize: totalFont,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                      height: 1.05,
                    ),
                  ),
                  if (withLegend) ...<Widget>[
                    const SizedBox(height: 4),
                    _innerLegend(
                      seen,
                      trf('已刷 {n}', {'n': stats.seenCount}),
                      legendFont,
                      scheme,
                    ),
                    const SizedBox(height: 2),
                    _innerLegend(
                      scheme.error,
                      trf('错题 {n}', {'n': stats.wrongCount}),
                      legendFont,
                      scheme,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _innerLegend(
          Color color, String label, double fontSize, ColorScheme scheme) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: fontSize,
              color: scheme.onSurfaceVariant,
              height: 1.1,
            ),
          ),
        ],
      );
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.track,
    required this.seenColor,
    required this.wrongColor,
    required this.seen,
    required this.wrong,
  });

  final Color track;
  final Color seenColor;
  final Color wrongColor;
  final double seen;
  final double wrong;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final stroke = side * kRingStrokeFactor;
    final wrongStroke = stroke * kWrongRingStrokeFactor;
    final radius = (side - stroke) / 2 - 2;
    if (radius <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);
    const start = -math.pi / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (seen > 0) {
      canvas.drawArc(
        rect,
        start,
        seen * 2 * math.pi,
        false,
        Paint()
          ..color = seenColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
    }
    // 细环后画，覆盖在已刷环上方；两种颜色共用一条轨迹，各自的比例都能读出来。
    // 两层都比早期版本更粗（主环 0.135、错题环约 0.084 倍边长），小尺寸下也清晰。
    if (wrong > 0) {
      canvas.drawArc(
        rect,
        start,
        wrong * 2 * math.pi,
        false,
        Paint()
          ..color = wrongColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = wrongStroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.track != track ||
      old.seenColor != seenColor ||
      old.wrongColor != wrongColor ||
      old.seen != seen ||
      old.wrong != wrong;
}

/// 统计详情：圆环 + 刷题进度 / 作答表现 / 分题型题量。
class QuizStatsDetailPage extends StatefulWidget {
  const QuizStatsDetailPage({
    super.key,
    required this.repo,
    required this.bankId,
  });

  final QuizRepository repo;
  final String bankId;

  @override
  State<QuizStatsDetailPage> createState() => _QuizStatsDetailPageState();
}

class _QuizStatsDetailPageState extends State<QuizStatsDetailPage> {
  late final Future<_StatsDetail> _future = _load();

  Future<_StatsDetail> _load() async {
    final stats = await widget.repo.stats(bankId: widget.bankId);
    final stock = await widget.repo.stockOf(widget.bankId);
    final noteCount = await widget.repo.countNotes(widget.bankId);
    return _StatsDetail(stats: stats, stock: stock, noteCount: noteCount);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('统计详情'))),
      body: FutureBuilder<_StatsDetail>(
        future: _future,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final stats = data.stats;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: BankStatsRing(stats: stats, size: 250),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: tr('刷题进度'),
                children: <Widget>[
                  StatRow(label: tr('题目'), value: '${stats.questionCount}'),
                  StatRow(
                    label: tr('已刷题目'),
                    value: '${stats.seenCount}',
                    secondary: trf('覆盖率 {n}%',
                        {'n': stats.seenPercent.toStringAsFixed(1)}),
                    valueColor: scheme.primary,
                  ),
                  StatRow(label: tr('未刷题目'), value: '${stats.unseenCount}'),
                  StatRow(
                    label: tr('错题'),
                    value: '${stats.wrongCount}',
                    valueColor: scheme.error,
                  ),
                  StatRow(label: tr('收藏'), value: '${stats.favoriteCount}'),
                  StatRow(label: tr('笔记'), value: '${data.noteCount}'),
                ],
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: tr('作答表现'),
                children: <Widget>[
                  StatRow(label: tr('历史作答'), value: '${stats.answeredCount}'),
                  StatRow(label: tr('答对次数'), value: '${stats.correctCount}'),
                  StatRow(
                    label: tr('正确率'),
                    value: stats.answeredCount == 0
                        ? '--'
                        : '${stats.accuracy.toStringAsFixed(1)}%',
                  ),
                  StatRow(label: tr('练习/考试次数'), value: '${stats.sessionCount}'),
                ],
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: tr('分题型题量'),
                children: <Widget>[
                  for (final type in allQuestionTypes)
                    StatRow(
                      label: typeLabel(type),
                      value: '${data.stock[type] ?? 0}',
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SmallHint(
                text: tr('错题、收藏与记录只属于当前题库，其他题库互不影响'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatsDetail {
  const _StatsDetail({
    required this.stats,
    required this.stock,
    required this.noteCount,
  });

  final QuizStats stats;
  final Map<QuestionType, int> stock;
  final int noteCount;
}
