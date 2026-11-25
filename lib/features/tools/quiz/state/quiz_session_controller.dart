import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import '../logic/quiz_judge.dart';

/// 抽题结果：题目列表与库存不足提示。
class PickResult {
  const PickResult({required this.questions, this.shortage = const <String>[]});

  final List<Question> questions;

  /// 库存不足描述（题型：需要 x / 仅有 y）。
  final List<String> shortage;

  bool get empty => questions.isEmpty;
}

/// 练习 / 考试会话控制器。
///
/// 职责：
/// - 建立会话（全部 / 随机 / 错题 / 收藏 / 考试）并写入 session_questions；
/// - 作答实时落库，保存 elapsedMs 以支持断点续答；
/// - 练习模式确认即判分，考试交卷后统一判分；
/// - 错题写入（INSERT OR IGNORE）与「仅错题模式答对移出」；
/// - 收藏幂等，取消收藏不影响本次会话；
/// - 计时：到时自动交卷。
class QuizSessionController extends ChangeNotifier {
  QuizSessionController(this._repo, {Random? random, this.onStudy})
      : _random = random ?? Random();

  final QuizRepository _repo;
  final Random _random;

  /// 背题时翻到某题的回调（默认写 study_history）。测试可注入以隔离 I/O。
  final Future<void> Function(String bankId, String questionId)? onStudy;

  /// 记录一题已背：仅背题会话调用，且是背题唯一允许的写库。
  Future<void> _markStudied(Question? q) async {
    if (!_ephemeral || q == null) return;
    final mark = onStudy ?? _repo.markStudied;
    await mark(q.bankId, q.id);
  }

  QuizSession? _session;
  List<Question> _questions = <Question>[];
  final Map<String, List<String>> _answers = <String, List<String>>{};
  final Map<String, bool> _judged = <String, bool>{}; // 简答自评结果
  final Map<String, bool> _selfJudged = <String, bool>{};
  final Map<String, List<String>> _optionOrder = <String, List<String>>{};
  int _index = 0;
  Timer? _ticker;
  int _elapsedMs = 0;
  bool _submitted = false;
  bool _disposed = false;

  /// 上次写 `sessions.activeAt` 的时刻：切题很频繁，节流成几秒一次足够排序用。
  int _lastTouchMs = 0;
  static const int _touchIntervalMs = 5000;

  /// 本次会话已经累计过「答对次数」的题目：重复点确认不重复计数。
  final Set<String> _wrongCounted = <String>{};

  /// 背题会话只存在内存里：练习相关写库全部跳过（背题记录是唯一例外）。
  bool get _ephemeral => _session?.config.studyMode ?? false;

  QuizSession? get session => _session;
  List<Question> get questions => List<Question>.unmodifiable(_questions);
  int get index => _index;
  int get elapsedMs => _elapsedMs;
  bool get submitted => _submitted;

  Question? get current => _questions.isEmpty || _index >= _questions.length
      ? null
      : _questions[_index];

  /// 题目被编辑后同步会话内存快照，保证当前页、答题卡与判分立即用新内容。
  void replaceQuestion(Question updated) {
    final i = _questions.indexWhere((q) => q.id == updated.id);
    if (i < 0) return;
    _questions[i] = updated;
    notifyListeners();
  }

  /// 收藏 id（本次会话内变化实时反映）。
  Set<String> _favorites = <String>{};
  Set<String> _wrong = <String>{};
  bool isFavorite(String questionId) => _favorites.contains(questionId);
  bool isWrong(String questionId) => _wrong.contains(questionId);

  /// 每道题的作答状态（答题卡 / 报告）。
  AnswerState stateOf(String questionId) {
    final q = _byId(questionId);
    if (q == null) return AnswerState.unanswered;
    return evaluateAnswer(
      q,
      _answers[questionId],
      shortJudged: _selfJudged[questionId] ?? false,
      shortCorrect: _judged[questionId] ?? false,
    );
  }

  Question? _byId(String id) {
    for (final q in _questions) {
      if (q.id == id) return q;
    }
    return null;
  }

  /// 已作答题数。
  int get answeredCount => _questions
      .where((q) => (_answers[q.id] ?? const <String>[]).isNotEmpty)
      .length;

  /// 未作答题数。
  int get unansweredCount => _questions.length - answeredCount;

  /// 本次会话中序号最靠前的未作答题下标（答题卡顺序）。
  ///
  /// 与页面「未答」计数同一口径：简答写了内容但未自评算已答（待自评）。
  int? get firstUnansweredIndex {
    for (var i = 0; i < _questions.length; i++) {
      if (stateOf(_questions[i].id) == AnswerState.unanswered) return i;
    }
    return null;
  }

  /// 是否每道题都已作答（简答还需完成自评）。
  ///
  /// 练习模式没有「交卷」这一步，靠这个判断会话是否已经刷完：
  /// 刷完就结束会话，首页不该再挂一条「未完成」。
  bool get allAnswered =>
      _questions.isNotEmpty &&
      _questions.every((q) {
        final answer = _answers[q.id];
        if (answer == null || answer.isEmpty) return false;
        if (q.type == QuestionType.short) return _selfJudged[q.id] ?? false;
        return true;
      });

  /// 练习刷完全部题目后收尾：标记会话已结束并落库。
  ///
  /// 与 [submit] 的区别是不再重复写题作答与错题计数（练习模式每答一题
  /// 已经记过账），只补算分数并把状态从 active 改成 submitted。
  Future<void> finishPractice() async {
    if (_ephemeral) return;
    final session = _session;
    if (session == null || _submitted || !allAnswered) return;
    _ticker?.cancel();
    var total = 0.0;
    var max = 0.0;
    for (final q in _questions) {
      max += scoreFor(q, session.config);
      if (stateOf(q.id) == AnswerState.correct) {
        total += scoreFor(q, session.config);
      }
    }
    _submitted = true;
    _session = session.copyWith(
      status: SessionStatus.submitted,
      elapsedMs: _elapsedMs,
      totalScore: total,
      maxScore: max,
      finishedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _repo.updateSession(_session!);
    notifyListeners();
  }

  /// 待自评的简答数量（交卷前提示）。
  int get pendingShortCount => _questions
      .where((q) => isPendingShort(q, _answers[q.id]))
      .where((q) => !(_selfJudged[q.id] ?? false))
      .length;

  /// 剩余毫秒（不限时返回 -1）。
  int get remainMs => _session?.remainMs ?? -1;

  // ---------- 建立会话 ----------

  /// 抽取题目（全部 / 随机 / 错题 / 收藏）。
  Future<PickResult> pick({
    required String? bankId,
    required QuizMode mode,
    QuizConfig config = const QuizConfig(),
  }) async {
    List<Question> source;
    switch (mode) {
      case QuizMode.wrong:
        source = await _repo.wrongQuestions(bankId: bankId);
      case QuizMode.favorite:
        source = await _repo.favoriteQuestions(bankId: bankId);
      case QuizMode.all:
      case QuizMode.random:
      case QuizMode.exam:
        source = bankId == null
            ? await _questionsOfAllBanks()
            : await _repo.questionsOfBank(bankId, limit: 100000);
    }
    if (source.isEmpty) return const PickResult(questions: <Question>[]);

    // 「只刷没做过的题」：在按题型分组之前先剔除历史已作答的题，
    // 这样 shortage 里的库存口径与 UI 显示的「未做 N 题」一致。
    if (config.onlyUnseen) {
      final done = await _repo.answeredQuestionIds();
      if (done.isNotEmpty) {
        source = source.where((q) => !done.contains(q.id)).toList();
      }
    }

    final shortage = <String>[];
    List<Question> picked;
    if (mode == QuizMode.random || mode == QuizMode.exam) {
      picked = <Question>[];
      final byType = <QuestionType, List<Question>>{};
      for (final q in source) {
        byType.putIfAbsent(q.type, () => <Question>[]).add(q);
      }
      for (final entry in config.typeCounts.entries) {
        final pool = List<Question>.of(byType[entry.key] ?? const <Question>[]);
        if (pool.length < entry.value) {
          shortage.add('${entry.key.key}：需要 ${entry.value}，仅有 ${pool.length}');
        }
        pool.shuffle(_random);
        picked.addAll(pool.take(entry.value));
      }
      if (picked.isEmpty) {
        // 未配置题型数量时退化为全部
        picked = List<Question>.of(source);
      }
      if (config.shuffleQuestions) picked.shuffle(_random);
    } else {
      picked = List<Question>.of(source);
      if (config.shuffleQuestions) picked.shuffle(_random);
    }
    return PickResult(questions: picked, shortage: shortage);
  }

  Future<List<Question>> _questionsOfAllBanks() async {
    final banks = await _repo.listBanks();
    final out = <Question>[];
    for (final bank in banks) {
      out.addAll(await _repo.questionsOfBank(bank.id, limit: 100000));
    }
    return out;
  }

  /// 背题模式：用给定题目建立**纯内存**会话。
  ///
  /// 不写 sessions / session_questions，不记分、不计时、不触发错题规则；
  /// 只读取收藏与错题标记用于界面展示。[questions] 由背题页按范围筛好传入。
  Future<bool> startStudy(List<Question> questions) async {
    if (questions.isEmpty) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    _session = QuizSession(
      id: newId(),
      bankId: null,
      mode: QuizMode.all,
      config: const QuizConfig(
        studyMode: true,
        shuffleOptions: false,
        shuffleQuestions: false,
      ),
      status: SessionStatus.active,
      startedAt: now,
      activeAt: now,
    );
    _questions = List<Question>.of(questions);
    for (final q in _questions) {
      _optionOrder[q.id] = List<String>.from(q.options.map((o) => o.key));
    }
    _index = 0;
    _elapsedMs = 0;
    _submitted = false;
    _answers.clear();
    _judged.clear();
    _selfJudged.clear();
    _wrongCounted.clear();
    // 只读标记，让收藏星标与错题图标与题库保持一致。
    await _loadFlags();
    // 进入背题即算「背过」第一题（goTo 不会为第 0 题触发）。
    await _markStudied(_questions.isEmpty ? null : _questions.first);
    notifyListeners();
    return true;
  }

  /// 开始新会话。
  Future<bool> start({
    required String? bankId,
    required QuizMode mode,
    QuizConfig config = const QuizConfig(),
  }) async {
    final picked = await pick(bankId: bankId, mode: mode, config: config);
    if (picked.empty) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = QuizSession(
      id: newId(),
      bankId: bankId,
      mode: mode,
      config: config,
      status: SessionStatus.active,
      startedAt: now,
      activeAt: now,
      durationSec: config.durationSec,
      scoreEnabled: config.scoreEnabled,
    );
    await _repo.insertSession(session);
    final items = <SessionQuestion>[];
    for (var i = 0; i < picked.questions.length; i++) {
      final q = picked.questions[i];
      final order = <String>[
        ...List<String>.generate(q.options.length, (i) => q.options[i].key)
      ];
      if (config.shuffleOptions && q.options.length > 1) order.shuffle(_random);
      _optionOrder[q.id] = order;
      items.add(SessionQuestion(
        sessionId: session.id,
        questionId: q.id,
        orderNo: i,
        optionOrder: order,
      ));
    }
    await _repo.insertSessionQuestions(items);
    _session = session;
    _questions = picked.questions;
    _index = 0;
    _elapsedMs = 0;
    _submitted = false;
    _answers.clear();
    _judged.clear();
    _selfJudged.clear();
    _wrongCounted.clear();
    await _loadFlags();
    _startTicker();
    notifyListeners();
    return true;
  }

  /// 断点续答：恢复题目顺序、选项顺序、作答与剩余时间。
  Future<bool> resume(String sessionId) async {
    final session = await _repo.sessionById(sessionId);
    if (session == null) return false;
    final items = await _repo.sessionQuestions(sessionId);
    if (items.isEmpty) return false;
    final ordered = List<SessionQuestion>.of(items)
      ..sort((a, b) => a.orderNo.compareTo(b.orderNo));
    final questions =
        await _repo.questionsByIds(ordered.map((e) => e.questionId));
    if (questions.isEmpty) return false;
    _session = session;
    _questions = questions;
    _answers.clear();
    _judged.clear();
    _selfJudged.clear();
    _optionOrder.clear();
    for (final item in ordered) {
      if (item.userAnswer.isNotEmpty) {
        _answers[item.questionId] = item.userAnswer;
      }
      if (item.selfJudged) {
        _selfJudged[item.questionId] = true;
        _judged[item.questionId] = item.isCorrect ?? false;
      }
      if (item.optionOrder.isNotEmpty) {
        _optionOrder[item.questionId] = item.optionOrder;
      }
    }
    _elapsedMs = session.elapsedMs;
    _submitted = session.status == SessionStatus.submitted;
    // 进过一次就算「刚动过」：即使没作答，首页也该指向这一套。
    _touch(force: true);
    // 回到上次刷到的题号；越界（题目数变化 / 旧数据）时退回第 1 题。
    final saved = session.lastIndex;
    _index = saved < 0 || saved >= questions.length ? 0 : saved;
    await _loadFlags();
    await refreshBehavior();
    if (_submitted) {
      notifyListeners();
      return true;
    }
    // 考试超时：恢复时直接自动交卷
    if (session.expired) {
      await submit(auto: true);
      return true;
    }
    _startTicker();
    notifyListeners();
    return true;
  }

  Future<void> _loadFlags() async {
    _favorites = await _repo.favoriteIds();
    _wrong = await _repo.wrongIds();
  }

  /// 把「行为类」设置从设置表读进当前会话，覆盖建会话时的快照。
  ///
  /// 断点续答的旧练习 / 考试用的是当时保存的 config，之后在设置页改
  /// 确认后禁止修改 / 答对切换下一题 / 简易刷题 / 错题阈值都不会生效；
  /// 恢复时用最新设置覆盖这四个字段，其余（题目、分值、时长）仍按会话快照。
  Future<void> refreshBehavior() async {
    final session = _session;
    if (session == null) return;
    final lock = await _repo.getSetting('lockAfterConfirm');
    final autoNext = await _repo.getSetting('autoNextOnCorrect');
    final simple = await _repo.getSetting('simpleMode');
    final threshold =
        int.tryParse(await _repo.getSetting('wrongRemoveThreshold') ?? '');
    _session = session.copyWith(
      config: session.config.copyWith(
        lockAfterConfirm: lock == 'true',
        autoNextOnCorrect: autoNext == 'true',
        simpleMode: simple == 'true',
        wrongRemoveThreshold: threshold == null ? 1 : threshold.clamp(1, 99),
      ),
    );
    _notifySafe();
  }

  void _notifySafe() {
    if (!_disposed) notifyListeners();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || _submitted) return;
      _elapsedMs += 1000;
      final session = _session;
      if (session != null && session.expired) {
        unawaited(submit(auto: true));
        return;
      }
      notifyListeners();
    });
  }

  // ---------- 作答 ----------

  /// 选项展示顺序（打乱后）。
  List<OptionItem> optionsOf(Question q) {
    final order = _optionOrder[q.id];
    if (order == null || order.length != q.options.length) return q.options;
    final byKey = <String, OptionItem>{for (final o in q.options) o.key: o};
    return order.map((k) => byKey[k]).whereType<OptionItem>().toList();
  }

  List<String>? answerOf(String questionId) => _answers[questionId];

  /// 标记会话「刚动过」：断点续答、切题、作答都算。
  ///
  /// 首页「继续上次」按 `sessions.activeAt` 排序，多套没刷完时才回得到刚放下的
  /// 那套；切题很频繁，因此默认节流成 [_touchIntervalMs] 写一次。
  void _touch({bool force = false}) {
    if (_ephemeral) return;
    final session = _session;
    if (session == null || session.status != SessionStatus.active) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastTouchMs < _touchIntervalMs) return;
    _lastTouchMs = now;
    _session = session.copyWith(activeAt: now);
    unawaited(_repo.touchSession(session.id, at: now));
  }

  void goTo(int index) {
    if (index < 0 || index >= _questions.length) return;
    _index = index;
    // 切题即落库，退出或杀掉进程后再次进入仍停在这一题。背题会话不落库。
    final session = _session;
    if (!_ephemeral && session != null && session.lastIndex != index) {
      _session = session.copyWith(lastIndex: index);
      unawaited(_repo.updateSessionIndex(session.id, index));
      _touch();
    }
    // 背题：翻到的每一题都计入该题库的背题记录（去重由 Repository 保证）。
    if (_ephemeral && index < _questions.length) {
      unawaited(_markStudied(_questions[index]));
    }
    notifyListeners();
  }

  void next() => goTo(_index + 1 >= _questions.length ? _index : _index + 1);

  void previous() => goTo(_index <= 0 ? 0 : _index - 1);

  /// 记录作答（练习模式立即判分；考试仅保存）。
  Future<void> answer(String questionId, List<String> value,
      {bool? selfJudgedCorrect}) async {
    if (_ephemeral) return;
    if (_session == null || _submitted) return;
    final q = _byId(questionId);
    if (q == null) return;
    _answers[questionId] = value;
    if (q.type == QuestionType.short && selfJudgedCorrect != null) {
      _selfJudged[questionId] = true;
      _judged[questionId] = selfJudgedCorrect;
    }
    await _persistAnswer(questionId);
    _touch();
    notifyListeners();
  }

  Future<void> _persistAnswer(String questionId) async {
    final session = _session;
    final q = _byId(questionId);
    if (session == null || q == null) return;
    // 考试中未判分；练习中简答未自评也不判分
    final practice = !session.isExam;
    bool? correct;
    final selfJudged = _selfJudged[questionId] ?? false;
    if (q.type == QuestionType.short) {
      if (practice && selfJudged) correct = _judged[questionId];
    } else if (practice) {
      final state = stateOf(questionId);
      correct = state == AnswerState.correct
          ? true
          : (state == AnswerState.wrong ? false : null);
    }
    final item = SessionQuestion(
      sessionId: session.id,
      questionId: questionId,
      orderNo: _questions.indexOf(q),
      userAnswer: _answers[questionId] ?? const <String>[],
      isCorrect: correct,
      selfJudged: selfJudged,
      optionOrder: _optionOrder[questionId] ?? const <String>[],
      answeredAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _repo.updateSessionQuestion(item);
    if (practice && correct != null && !session.mode.isExam) {
      await _applyWrongRule(q, correct);
    }
  }

  /// 错题规则：答错写入并清零累计答对次数；错题练习里答对累计到阈值才移出。
  Future<void> _applyWrongRule(Question q, bool correct) async {
    if (correct) {
      await _noteCorrect(q);
    } else {
      await _noteWrong(q);
    }
  }

  Future<void> _noteCorrect(Question q) async {
    if (!(_session?.mode.isWrongDrill ?? false)) return;
    if (!_wrongCounted.add(q.id)) return;
    final threshold = _session?.config.wrongRemoveThreshold ?? 1;
    final count = await _repo.bumpWrongCorrectCount(q.id);
    if (count >= threshold) {
      await _repo.removeWrong(q.bankId, q.id);
      _wrong.remove(q.id);
    }
  }

  Future<void> _noteWrong(Question q) async {
    await _repo.addWrong(q.bankId, q.id);
    _wrong.add(q.id);
  }

  /// 练习模式「确认」：判分并显示答案与解析。
  /// 简答自评（报告页补评）。
  Future<void> selfJudge(String questionId, bool correct) =>
      judgeShortAnswer(questionId, null, correct);

  /// 简答「写入答案 + 自评」合并为一次落库。
  ///
  /// 之前页面先 `answer(selfJudgedCorrect:)` 再 `selfJudge()`，会重复写库并
  /// 重复执行错题规则；统一在这里处理。练习模式的错题规则由
  /// [_persistAnswer] 内统一应用，考试模式（提交后才补评）在此补一次。
  Future<void> judgeShortAnswer(
    String questionId,
    List<String>? value,
    bool correct,
  ) async {
    if (_ephemeral) return;
    final q = _byId(questionId);
    final session = _session;
    if (q == null || session == null) return;
    if (value != null) _answers[questionId] = value;
    _selfJudged[questionId] = true;
    _judged[questionId] = correct;
    await _persistAnswer(questionId);
    _touch();
    if (session.isExam) await _applyWrongRule(q, correct);
    notifyListeners();
  }

  /// 重新计算分数（简答在报告中补自评后调用）。
  Future<void> refreshScore() async {
    if (_ephemeral) return;
    final session = _session;
    if (session == null) return;
    double total = 0;
    double max = 0;
    for (final q in _questions) {
      max += scoreFor(q, session.config);
      final correct = stateOf(q.id) == AnswerState.correct;
      if (correct) total += scoreFor(q, session.config);
      await _repo.updateSessionQuestion(SessionQuestion(
        sessionId: session.id,
        questionId: q.id,
        orderNo: _questions.indexOf(q),
        userAnswer: _answers[q.id] ?? const <String>[],
        isCorrect: correct
            ? true
            : (stateOf(q.id) == AnswerState.wrong ? false : null),
        selfJudged: _selfJudged[q.id] ?? false,
        optionOrder: _optionOrder[q.id] ?? const <String>[],
        answeredAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    _session = session.copyWith(totalScore: total, maxScore: max);
    await _repo.updateSession(_session!);
    notifyListeners();
  }

  /// 收藏 / 取消收藏（幂等；取消不影响本次会话）。
  Future<void> toggleFavorite(String questionId) async {
    final q = _byId(questionId);
    if (q == null) return;
    if (_favorites.contains(questionId)) {
      await _repo.removeFavorite(q.bankId, questionId);
      _favorites.remove(questionId);
    } else {
      await _repo.addFavorite(q.bankId, questionId);
      _favorites.add(questionId);
    }
    notifyListeners();
  }

  /// 手动移出错题本。
  // ---------- 交卷 ----------

  /// 考试交卷：统一判分（简答需先自评）。
  ///
  /// [auto] 为 true 表示到时自动交卷。未自评的简答按答错处理并计入待自评提示。
  Future<SessionStats?> submit({bool auto = false}) async {
    if (_ephemeral) return null;
    final session = _session;
    if (session == null || _submitted) return null;
    _ticker?.cancel();
    double total = 0;
    double max = 0;
    for (final q in _questions) {
      final answer = _answers[q.id];
      final selfJudged = _selfJudged[q.id] ?? false;
      bool? correct;
      if (q.type == QuestionType.short) {
        // 未自评的简答：交卷时按未答（0 分）处理，报告单独提示
        correct = selfJudged ? (_judged[q.id] ?? false) : null;
      } else {
        final state = evaluateAnswer(q, answer);
        correct = state == AnswerState.correct
            ? true
            : (state == AnswerState.wrong ? false : null);
      }
      if (correct == false) {
        await _noteWrong(q);
      } else if (correct == true) {
        await _noteCorrect(q);
      }
      max += scoreFor(q, session.config);
      if (correct == true) total += scoreFor(q, session.config);
      await _repo.updateSessionQuestion(SessionQuestion(
        sessionId: session.id,
        questionId: q.id,
        orderNo: _questions.indexOf(q),
        userAnswer: answer ?? const <String>[],
        isCorrect: correct,
        selfJudged: selfJudged,
        optionOrder: _optionOrder[q.id] ?? const <String>[],
        answeredAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    _submitted = true;
    _session = session.copyWith(
      status: SessionStatus.submitted,
      elapsedMs: _elapsedMs,
      totalScore: total,
      maxScore: max,
      finishedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _repo.updateSession(_session!);
    notifyListeners();
    return stats();
  }

  /// 保存进度（退出练习 / 页面暂停时调用）。
  Future<void> saveProgress() async {
    if (_ephemeral) return;
    final session = _session;
    if (session == null) return;
    _ticker?.cancel();
    await _repo.updateSession(session.copyWith(elapsedMs: _elapsedMs));
    if (!_submitted && session.status == SessionStatus.active) {
      _startTicker();
    }
  }

  /// 统计（报告页）。
  SessionStats stats() {
    final config = _session?.config ?? const QuizConfig();
    return buildStats(
      questions: _questions,
      answers:
          _questions.map((q) => _answers[q.id] ?? const <String>[]).toList(),
      states: _questions.map((q) => stateOf(q.id)).toList(),
      config: config,
      elapsedMs: _elapsedMs,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    super.dispose();
  }
}
