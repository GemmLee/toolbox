import '../data/quiz_models.dart';

/// 判分规则（纯函数，便于单测）：
///
/// - 单选 / 判断：答案集合相等；
/// - 多选：必须全对（MVP 不做部分分）；
/// - 填空：去空格、忽略大小写后命中任一可接受答案即对；
/// - 简答：不自动判分，由用户自评；
/// - 未答：不计正确，也不视为答错（未答不写错题）。
/// 简答：[shortJudged] 为 true 时按 [shortCorrect] 判对错，否则为待自评。
AnswerState evaluateAnswer(
  Question question,
  List<String>? userAnswer, {
  bool shortJudged = false,
  bool shortCorrect = false,
}) {
  final answer = <String>[
    ...?userAnswer?.map((e) => e.trim()).where((e) => e.isNotEmpty),
  ];
  if (answer.isEmpty) return AnswerState.unanswered;

  switch (question.type) {
    case QuestionType.single:
    case QuestionType.trueFalse:
    case QuestionType.multiple:
      return _sameSet(answer, question.answer)
          ? AnswerState.correct
          : AnswerState.wrong;
    case QuestionType.fill:
      final normalized = answer.map(_normalize).toSet();
      final accepted = question.answer.map(_normalize).toSet();
      return normalized.any(accepted.contains)
          ? AnswerState.correct
          : AnswerState.wrong;
    case QuestionType.short:
      // 简答：未自评 = 待判；自评后按用户选择
      if (!shortJudged) return AnswerState.pending;
      return shortCorrect ? AnswerState.correct : AnswerState.wrong;
  }
}

/// 简答已作答但尚未自评。
bool isPendingShort(Question question, List<String>? userAnswer) =>
    question.type == QuestionType.short &&
    userAnswer != null &&
    userAnswer.any((e) => e.trim().isNotEmpty);

bool _sameSet(List<String> a, List<String> b) {
  final left = a.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
  final right = b.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
  if (left.length != right.length) return false;
  return left.every(right.contains);
}

/// 填空归一化：去所有空白 + 忽略大小写。
String _normalize(String input) =>
    input.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// 计分：分值优先级 单题 score > 题型分值 > 全局分值。
///
/// [scoreEnabled] 为 false 时（对错模式）返回 0，只统计正确 / 错误 / 未答。
double scoreFor(Question question, QuizConfig config) =>
    config.scoreEnabled ? config.scoreOf(question) : 0;

/// 会话统计。
class SessionStats {
  const SessionStats({
    required this.total,
    required this.answered,
    required this.correct,
    required this.wrong,
    required this.unanswered,
    required this.pending,
    required this.totalScore,
    required this.maxScore,
    required this.elapsedMs,
  });

  final int total;

  /// 已作答题数（不含简答待自评？含，只要填了内容）。
  final int answered;
  final int correct;
  final int wrong;
  final int unanswered;

  /// 简答已作答但尚未自评的数量。
  final int pending;
  final double totalScore;
  final double maxScore;
  final int elapsedMs;

  /// 正确率（%），无已作答时返回 0。
  double get accuracy => answered == 0 ? 0 : correct / answered * 100;

  /// 分题型统计。
  static Map<QuestionType, List<int>> byType(
    List<Question> questions,
    List<AnswerState> states,
  ) {
    final out = <QuestionType, List<int>>{};
    for (var i = 0; i < questions.length && i < states.length; i++) {
      final bucket = out.putIfAbsent(
        questions[i].type,
        () => <int>[0, 0, 0, 0], // 总、对、错、未答
      );
      bucket[0]++;
      switch (states[i]) {
        case AnswerState.correct:
          bucket[1]++;
        case AnswerState.wrong:
          bucket[2]++;
        case AnswerState.unanswered:
          bucket[3]++;
        case AnswerState.pending:
          bucket[3]++;
      }
    }
    return out;
  }
}

/// 由作答明细计算统计。
SessionStats buildStats({
  required List<Question> questions,
  required List<List<String>> answers,
  required List<AnswerState> states,
  required QuizConfig config,
  required int elapsedMs,
}) {
  var answered = 0;
  var correct = 0;
  var wrong = 0;
  var unanswered = 0;
  var pending = 0;
  double total = 0;
  double max = 0;
  for (var i = 0; i < questions.length; i++) {
    final state = i < states.length ? states[i] : AnswerState.unanswered;
    final q = questions[i];
    max += scoreFor(q, config);
    switch (state) {
      case AnswerState.correct:
        answered++;
        correct++;
        total += scoreFor(q, config);
      case AnswerState.wrong:
        answered++;
        wrong++;
      case AnswerState.unanswered:
        unanswered++;
      case AnswerState.pending:
        // 简答未自评：计为待判，考试按 0 分处理并单独提示
        pending++;
    }
  }
  return SessionStats(
    total: questions.length,
    answered: answered,
    correct: correct,
    wrong: wrong,
    unanswered: unanswered,
    pending: pending,
    totalScore: total,
    maxScore: max,
    elapsedMs: elapsedMs,
  );
}
