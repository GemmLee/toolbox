import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/quiz_models.dart';
import '../logic/quiz_judge.dart';
import '../state/quiz_session_controller.dart';
import 'quiz_common.dart';

/// 报告页：得分 / 正确数、正确率、用时、分题型统计、简答自评、错题回顾。
class QuizReportPage extends StatefulWidget {
  const QuizReportPage({
    super.key,
    required this.controller,
    this.ownsController = false,
  });

  final QuizSessionController controller;

  /// 由答题页移交的控制器，交由本页释放，避免 use-after-dispose。
  final bool ownsController;

  @override
  State<QuizReportPage> createState() => _QuizReportPageState();
}

class _QuizReportPageState extends State<QuizReportPage> {
  QuizSessionController get _c => widget.controller;

  @override
  void dispose() {
    if (widget.ownsController) _c.dispose();
    super.dispose();
  }

  /// 简答补评：两条分支都重算分数，避免「答对」刷新而「答错」不刷新的错位。
  Future<void> _judge(String questionId, bool correct) async {
    await _c.selfJudge(questionId, correct);
    await _c.refreshScore();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final theme = Theme.of(context);
        final stats = _c.stats();
        final session = _c.session;
        final config = session?.config ?? const QuizConfig();
        final questions = _c.questions;
        final states = questions.map((q) => _c.stateOf(q.id)).toList();
        final byType = SessionStats.byType(questions, states);
        final pendingShorts = <Question>[
          for (var i = 0; i < questions.length; i++)
            if (states[i] == AnswerState.pending) questions[i],
        ];

        return Scaffold(
          appBar: AppBar(
            title: Text(tr('练习报告')),
            automaticallyImplyLeading: false,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      if (config.scoreEnabled) ...[
                        Text(
                          stats.totalScore.toStringAsFixed(1),
                          key: const ValueKey('report-score'),
                          style: theme.textTheme.displaySmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(trf('满分 {n}', {
                          'n': stats.maxScore.toStringAsFixed(1),
                        })),
                      ] else ...[
                        Text(
                          '${stats.correct}',
                          key: const ValueKey('report-correct'),
                          style: theme.textTheme.displaySmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(trf('共 {n} 题 · 正确', {'n': stats.total})),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _metric(context, tr('正确率'),
                              '${stats.accuracy.toStringAsFixed(0)}%'),
                          _metric(context, tr('答对'), '${stats.correct}'),
                          _metric(context, tr('答错'), '${stats.wrong}'),
                          _metric(context, tr('未答'), '${stats.unanswered}'),
                          _metric(context, tr('用时'), clockText(stats.elapsedMs)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('分题型统计'), style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      ...byType.entries.map(
                        (e) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              SizedBox(width: 60, child: Text(typeLabel(e.key))),
                              Expanded(
                                child: Text(
                                  trf('共 {t} · 对 {c} · 错 {w} · 未答 {u}', {
                                    't': e.value[0],
                                    'c': e.value[1],
                                    'w': e.value[2],
                                    'u': e.value[3],
                                  }),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (pendingShorts.isNotEmpty) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          trf('有 {n} 道简答题未自评', {'n': pendingShorts.length}),
                          style: theme.textTheme.titleSmall
                              ?.copyWith(color: Colors.orange),
                        ),
                        const SizedBox(height: 8),
                        ...pendingShorts.map(
                          (q) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(q.stem, maxLines: 2),
                                Row(
                                  children: [
                                    TextButton(
                                      onPressed: () => _judge(q.id, false),
                                      child: Text(tr('答错')),
                                    ),
                                    TextButton(
                                      onPressed: () => _judge(q.id, true),
                                      child: Text(tr('答对')),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('错题与解析回顾'),
                          style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      ...List<Widget>.generate(questions.length, (i) {
                        if (states[i] == AnswerState.correct) {
                          return const SizedBox.shrink();
                        }
                        final q = questions[i];
                        return ExpansionTile(
                          key: ValueKey<String>('review-${q.id}'),
                          title: Text(
                            q.stem,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${typeLabel(q.type)} · ${stateLabel(states[i])}',
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    q.type == QuestionType.short
                                        ? '${tr('参考答案')}：${answerLabelOf(q)}'
                                        : '${tr('正确答案')}：${answerLabelOf(q)}',
                                    style: const TextStyle(
                                        color: Colors.green,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(q.hasAnalysis
                                      ? q.analysis!
                                      : tr('暂无解析')),
                                ],
                              ),
                            ),
                          ],
                        );
                      }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('report-done'),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr('完成')),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _metric(BuildContext context, String label, String value) =>
      MetricTile(label: label, value: value);
}
