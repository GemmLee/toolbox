import 'package:flutter/material.dart';

import '../../../../core/app_theme.dart';
import '../../../../core/settings/tool_texts.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import '../state/quiz_session_controller.dart';
import 'quiz_ai_panel.dart';
import 'quiz_common.dart';
import 'quiz_question_edit_page.dart';
import 'quiz_report_page.dart';

/// 答题页：练习（确认即判分）/ 考试（交卷后判分）+ 答题卡 + 计时。
class QuizAnswerPage extends StatefulWidget {
  const QuizAnswerPage({
    super.key,
    required this.repo,
    this.controller,
    this.sessionId,
  });

  final QuizRepository repo;

  /// 新建会话时传入；为空则按 [sessionId] 恢复。
  final QuizSessionController? controller;

  /// 断点续答的会话 id。
  final String? sessionId;

  @override
  State<QuizAnswerPage> createState() => _QuizAnswerPageState();
}

class _QuizAnswerPageState extends State<QuizAnswerPage> {
  late final QuizSessionController _c;
  late final Future<void> _ready;

  /// 自己创建的控制器才由自己释放；外部传入（断点续答）不接管。
  late final bool _ownsController = widget.controller == null;

  /// 跳到报告页时把控制器所有权移交过去，避免本页 dispose 后报告页仍在监听。
  bool _handedOff = false;
  final Map<String, List<String>> _drafts = <String, List<String>>{};
  final Map<String, TextEditingController> _texts =
      <String, TextEditingController>{};
  bool _reported = false;
  double _dragDx = 0;
  double _dragDy = 0;

  @override
  void initState() {
    super.initState();
    _c = widget.controller ?? QuizSessionController(widget.repo);
    _ready = _prepare();
    _c.addListener(_onChange);
  }

  Future<void> _prepare() async {
    if (widget.controller == null && widget.sessionId != null) {
      await _c.resume(widget.sessionId!);
    }
  }

  void _onChange() {
    // 背题是纯浏览会话，没有交卷与报告页。
    if (_c.session?.config.studyMode ?? false) return;
    if (_c.submitted && !_reported) {
      _reported = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openReport());
    }
  }

  void _openReport() {
    if (!mounted) return;
    _handedOff = _ownsController;
    Navigator.of(context).pushReplacement(quizRoute<void>(
        builder: (_) => QuizReportPage(
              controller: _c,
              ownsController: _ownsController,
            )));
  }

  /// 编辑当前题：编辑页已落库，这里只替换会话内存快照。
  Future<void> _editCurrent(Question q) async {
    final edited = await Navigator.of(context).push<Question>(
      quizRoute<Question>(
        builder: (_) => QuestionEditPage(repo: widget.repo, question: q),
      ),
    );
    if (edited == null) return;
    _c.replaceQuestion(edited);
  }

  /// AI 解析写回题库后同步替换会话里的题目快照。
  Future<void> _saveAnalysis(Question q, String text) async {
    final updated = await widget.repo.saveAnalysis(q, text);
    if (!mounted) return;
    _c.replaceQuestion(updated);
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    for (final text in _texts.values) {
      text.dispose();
    }
    if (!_handedOff) _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        return AnimatedBuilder(
          animation: _c,
          builder: (context, _) => _buildBody(context),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final q = _c.current;
    final session = _c.session;
    if (q == null || session == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('刷题助手'))),
        body: QuizEmpty(tr('会话已结束')),
      );
    }
    final exam = session.isExam;
    final study = session.config.studyMode;
    final state = _c.stateOf(q.id);
    // 背题模式进入即展示答案与解析，不需要先作答。
    final showResult = study || (!exam && state != AnswerState.unanswered);
    final answered = _c.questions
        .where((item) => _c.stateOf(item.id) != AnswerState.unanswered)
        .length;
    final unanswered = _c.questions.length - answered;
    final wrongCount = _c.questions
        .where((item) => _c.stateOf(item.id) == AnswerState.wrong)
        .length;

    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(study
              ? trf(
                  '背题 {n} / {t}', {'n': _c.index + 1, 't': _c.questions.length})
              : trf('第 {n} / {t} 题',
                  {'n': _c.index + 1, 't': _c.questions.length})),
          actions: [
            if (session.timed && !study)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    clockText(_c.remainMs),
                    key: const ValueKey('answer-clock'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: _c.remainMs < 60000 ? Colors.red : null,
                    ),
                  ),
                ),
              ),
          ],
          // 进度条贴在 AppBar 下缘。背题不记作答，按当前浏览位置推进。
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(3),
            child: QuizProgressBar(
              key: const ValueKey('answer-progress'),
              answered: study ? _c.index + 1 : answered,
              total: _c.questions.length,
            ),
          ),
        ),
        // 底部栏常驻（含 SafeArea），body 不再重复兜底部安全区。
        body: SafeArea(
          top: false,
          child: QuizBackdrop(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: (_) {
                _dragDx = 0;
                _dragDy = 0;
              },
              onHorizontalDragUpdate: (details) {
                _dragDx += details.delta.dx;
                _dragDy += details.delta.dy;
              },
              onHorizontalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                // 斜向滑动优先让给页面滚动，避免误切题。
                if (_dragDx.abs() <= _dragDy.abs() * 1.2) return;
                // 左滑下一题、右滑上一题；慢速大幅和快速小幅都能触发。
                if (_dragDx <= -80 || velocity <= -400) {
                  if (_c.index < _c.questions.length - 1) _c.next();
                } else if (_dragDx >= 80 || velocity >= 400) {
                  if (_c.index > 0) _c.previous();
                }
              },
              child: ListView(
                // 题号变化时重建，切题后回到题目顶部而不是沿用上一题的滚动位置。
                key: ValueKey<String>('answer-body-${_c.index}'),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Chip(label: Text(typeLabel(q.type))),
                            if (session.scoreEnabled)
                              Chip(
                                label: Text(trf(
                                    '{n} 分', {'n': session.config.scoreOf(q)})),
                              ),
                            if (_c.isWrong(q.id))
                              const Icon(Icons.error_outline,
                                  size: 16, color: Colors.red),
                          ],
                        ),
                      ),
                      _headerAction(
                        key: const ValueKey('answer-edit'),
                        icon: Icons.edit_outlined,
                        tooltip: tr('编辑本题'),
                        onPressed: () => _editCurrent(q),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    q.stem,
                    key: const ValueKey('answer-stem'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      height: 1.55,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ..._answerArea(context, q, showResult, state, study),
                  if (showResult) ..._resultArea(context, q, state, study),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar:
            _bottomBar(q, exam, answered, wrongCount, unanswered, study),
      ),
    );
  }

  /// 紧凑功能按钮（40×40）：题干行右侧的编辑按钮。
  Widget _headerAction({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) =>
      IconButton(
        key: key,
        icon: Icon(icon, size: 21),
        tooltip: tooltip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      );

  /// 底部功能按钮（44×44）：收藏 / 答题卡，比题干行按钮大一号，便于单手点。
  Widget _toolAction({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) =>
      IconButton(
        key: key,
        icon: Icon(icon, size: 22),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      );

  /// 判分后单个选项的标注：错选红底、漏选（正确但没选中）绿底、
  /// 选中的正确答案文字变绿。只在练习模式确认判分后生效，考试答题中不显示。
  ///
  /// 底色不用 `tileColor`：`ListTile` 通过 `Ink` 画在 Scaffold 的 Material 墨层，
  /// 会被页面渐变背景（`QuizBackdrop`）整层盖住，所以改为显式容器绘制。
  _OptionMark _optionMark(
    BuildContext context,
    Question q,
    AnswerState state,
    bool showResult,
    List<String> picked,
    String key,
    bool study,
  ) {
    if (!showResult || !q.type.hasOptions) return const _OptionMark();
    final correct = q.answer.map((e) => e.trim()).toSet();
    final chosen = picked.map((e) => e.trim()).toSet();
    final k = key.trim();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final alpha = dark ? 0.32 : 0.18;
    final edge = dark ? 0.75 : 0.55;
    // 背题模式：正确答案直接标绿，不需要先作答。
    if (study) {
      return correct.contains(k)
          ? _OptionMark(
              background: Colors.green.withOpacity(alpha * 0.7),
              text: dark ? Colors.green.shade300 : Colors.green.shade700,
              border: Colors.green.withOpacity(edge),
            )
          : const _OptionMark();
    }
    if (state != AnswerState.wrong && state != AnswerState.correct) {
      return const _OptionMark();
    }
    if (chosen.contains(k) && !correct.contains(k)) {
      return _OptionMark(
        background: Colors.red.withOpacity(alpha),
        border: Colors.red.withOpacity(edge),
      );
    }
    if (correct.contains(k) && !chosen.contains(k)) {
      return _OptionMark(
        background: Colors.green.withOpacity(alpha),
        border: Colors.green.withOpacity(edge),
      );
    }
    if (correct.contains(k)) {
      return _OptionMark(
        text: dark ? Colors.green.shade300 : Colors.green.shade700,
        border: Colors.green.withOpacity(edge),
      );
    }
    return const _OptionMark();
  }

  /// 选项行：细描边圆角，判分后描边与底色一起变色。
  ///
  /// 底色不用 `ListTile.tileColor`（它经 Ink 画在 Scaffold 的墨层，会被页面渐变
  /// 背景盖住），而是用显式容器绘制；未标注时只留一圈淡描边，不做卡片底。
  Widget _optionRow(String optKey, _OptionMark mark, Widget child) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey<String>('opt-bg-$optKey'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: mark.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: mark.border ?? scheme.outlineVariant.withOpacity(0.45),
          width: mark.border == null ? 1 : 1.2,
        ),
      ),
      child: child,
    );
  }

  List<Widget> _answerArea(BuildContext context, Question q, bool showResult,
      AnswerState state, bool study) {
    final exam = (_c.session?.isExam ?? false);
    // 背题只读：不提供作答入口，也不写入任何记录。
    final locked = study || _locked(q);
    final picked = _drafts[q.id] ?? _c.answerOf(q.id) ?? const <String>[];
    _OptionMark mark(String key) =>
        _optionMark(context, q, state, showResult, picked, key, study);
    TextStyle? markTextStyle(_OptionMark mark) {
      if (mark.text != null) {
        return TextStyle(color: mark.text, fontWeight: FontWeight.w600);
      }
      // 背题时选项只读，显式给正常文字色，避免整片灰掉。
      if (study) {
        return TextStyle(color: Theme.of(context).colorScheme.onSurface);
      }
      return null;
    }

    switch (q.type) {
      case QuestionType.single:
      case QuestionType.trueFalse:
        return _c.optionsOf(q).map(
          (o) {
            final markValue = mark(o.key);
            return _optionRow(
              o.key,
              markValue,
              RadioListTile<String>(
                key: ValueKey<String>('opt-${o.key}'),
                value: o.key,
                groupValue: picked.isEmpty ? null : picked.first,
                title: Text(
                  optionLabelOf(q, o),
                  style: markTextStyle(markValue),
                ),
                onChanged:
                    locked ? null : (v) => _pick(q, <String>[v ?? o.key]),
              ),
            );
          },
        ).toList();
      case QuestionType.multiple:
        final options = _c.optionsOf(q);
        final allKeys = options.map((e) => e.key).toList(growable: false);
        final allSelected =
            allKeys.isNotEmpty && picked.length == allKeys.length;
        final tiles = options.map((o) {
          final markValue = mark(o.key);
          return _optionRow(
            o.key,
            markValue,
            CheckboxListTile(
              key: ValueKey<String>('opt-${o.key}'),
              value: picked.contains(o.key),
              title: Text(
                optionLabelOf(q, o),
                style: markTextStyle(markValue),
              ),
              onChanged: locked
                  ? null
                  : (v) {
                      final next = Set<String>.from(picked);
                      if (v == true) {
                        next.add(o.key);
                      } else {
                        next.remove(o.key);
                      }
                      final ordered = options
                          .map((e) => e.key)
                          .where(next.contains)
                          .toList();
                      _pick(q, ordered);
                    },
            ),
          );
        }).toList();
        return <Widget>[
          ...tiles,
          // 与最后一个选项留一段距离，避免误触成选项。
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('opt-select-all'),
              onPressed: locked || allKeys.isEmpty
                  ? null
                  : () => _pick(q, allSelected ? const <String>[] : allKeys),
              icon: Icon(
                allSelected ? Icons.deselect : Icons.select_all,
                size: 18,
              ),
              label: Text(tr(allSelected ? '清空全选' : '一键全选')),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ];
      case QuestionType.fill:
      case QuestionType.short:
        final controller = _texts.putIfAbsent(
          q.id,
          () => TextEditingController(
              text: (_c.answerOf(q.id) ?? const <String>[]).join('')),
        );
        return <Widget>[
          TextField(
            key: ValueKey<String>('input-${q.type.key}'),
            controller: controller,
            readOnly: locked,
            minLines: q.type == QuestionType.short ? 3 : 1,
            maxLines: q.type == QuestionType.short ? 6 : 1,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: q.type == QuestionType.fill ? tr('填写答案') : tr('作答'),
            ),
            onChanged: (value) {
              _drafts[q.id] = <String>[value];
              if (exam) _c.answer(q.id, <String>[value]);
            },
          ),
          if (!study && !exam && q.type == QuestionType.short) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('self-wrong'),
                    icon: const Icon(Icons.close),
                    label: Text(tr('答错')),
                    onPressed: locked ? null : () => _selfJudge(q, false),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('self-right'),
                    icon: const Icon(Icons.check),
                    label: Text(tr('答对')),
                    onPressed: locked ? null : () => _selfJudge(q, true),
                  ),
                ),
              ],
            ),
          ],
        ];
    }
  }

  List<Widget> _resultArea(
      BuildContext context, Question q, AnswerState state, bool study) {
    final theme = Theme.of(context);
    final color = stateColor(context, state);
    final picked = _drafts[q.id] ?? _c.answerOf(q.id) ?? const <String>[];
    return <Widget>[
      const Divider(height: 24),
      if (!study)
        Row(
          children: [
            Icon(
              state == AnswerState.correct ? Icons.check_circle : Icons.cancel,
              color: color,
            ),
            const SizedBox(width: 8),
            Text(stateLabel(state),
                style: theme.textTheme.titleSmall?.copyWith(color: color)),
          ],
        )
      else
        Text(tr('答案与解析'),
            style: theme.textTheme.titleSmall
                ?.copyWith(color: Colors.green, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Text(
        q.type == QuestionType.short
            ? '${tr('参考答案')}：${answerLabelOf(q)}'
            : '${tr('正确答案')}：${answerLabelOf(q)}',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: Colors.green, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      Text(tr('解析'), style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(
        q.hasAnalysis ? q.analysis! : tr('暂无解析'),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: q.hasAnalysis ? null : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 8),
      QuizAiExplanation(
        question: q,
        myAnswer: (picked.isEmpty ? '' : picked.join('、')),
        onSaveAnalysis: (text) => _saveAnalysis(q, text),
      ),
    ];
  }

  /// 「确认后禁止修改」：练习里已确认的题锁定选项，简答未自评时不锁。
  bool _locked(Question q) {
    final session = _c.session;
    if (session == null || session.isExam) return false;
    if (session.config.lockAfterConfirm != true) return false;
    final state = _c.stateOf(q.id);
    if (state == AnswerState.unanswered) return false;
    if (q.type == QuestionType.short && state == AnswerState.pending) {
      return false;
    }
    return true;
  }

  /// 答对后按设置自动切到下一题（最后一题不切）。
  void _maybeAutoNext(Question q) {
    final session = _c.session;
    if (session == null || session.isExam) return;
    if (session.config.autoNextOnCorrect != true) return;
    if (_c.stateOf(q.id) != AnswerState.correct) return;
    if (_c.index < _c.questions.length - 1) _c.next();
  }

  /// 简易刷题里「选完即自动确认」的题型：只覆盖单选与判断。
  /// 多选需要多点几次、填空要打字、简答要自评，都保留确认按钮。
  bool _autoConfirmOn(Question q, bool exam) =>
      !exam &&
      (_c.session?.config.simpleMode ?? false) &&
      (q.type == QuestionType.single || q.type == QuestionType.trueFalse);

  /// 底部栏两行，常驻显示：
  /// - 主操作行：上一题 / 确认（交卷）/ 下一题；简易刷题的单选 / 判断选完即
  ///   自动确认，这一行省略，只靠左右滑动翻页；
  /// - 功能行：左下角统计已答与答错题数，右下角收藏与答题卡。
  Widget _bottomBar(
    Question q,
    bool exam,
    int answered,
    int wrongCount,
    int unanswered,
    bool study,
  ) {
    final autoConfirm = _autoConfirmOn(q, exam);
    final simple = _c.session?.config.simpleMode ?? false;
    if (study) {
      // 背题只有翻页，没有确认 / 交卷，也不显示「已答 / 错」统计。
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('answer-prev'),
                  onPressed: _c.index == 0 ? null : _c.previous,
                  child: Text(tr('上一题')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('answer-next'),
                  onPressed:
                      _c.index >= _c.questions.length - 1 ? null : _c.next,
                  child: Text(tr('下一题')),
                ),
              ),
              _toolAction(
                key: const ValueKey('answer-favorite'),
                icon: _c.isFavorite(q.id) ? Icons.star : Icons.star_border,
                tooltip: tr('收藏'),
                onPressed: () => _c.toggleFavorite(q.id),
              ),
              _toolAction(
                key: const ValueKey('answer-sheet'),
                icon: Icons.grid_on_outlined,
                tooltip: tr('答题卡'),
                onPressed: _openSheet,
              ),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, autoConfirm ? 4 : 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!autoConfirm) ...[
              Row(
                children: [
                  if (!simple) ...[
                    OutlinedButton(
                      key: const ValueKey('answer-prev'),
                      onPressed: _c.index == 0 ? null : _c.previous,
                      child: Text(tr('上一题')),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: exam
                        ? FilledButton(
                            key: const ValueKey('answer-submit'),
                            onPressed: _submit,
                            child: Text(tr('交卷')),
                          )
                        : FilledButton(
                            key: const ValueKey('answer-confirm'),
                            onPressed: () => _confirm(q),
                            child: Text(tr('确认')),
                          ),
                  ),
                  if (!simple) ...[
                    const SizedBox(width: 8),
                    OutlinedButton(
                      key: const ValueKey('answer-next'),
                      onPressed:
                          _c.index >= _c.questions.length - 1 ? null : _c.next,
                      child: Text(tr('下一题')),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
            ],
            Row(
              children: [
                Expanded(
                    child: _sessionStats(
                        context, answered, wrongCount, unanswered, exam)),
                _toolAction(
                  key: const ValueKey('answer-favorite'),
                  icon: _c.isFavorite(q.id) ? Icons.star : Icons.star_border,
                  tooltip: tr('收藏'),
                  onPressed: () => _c.toggleFavorite(q.id),
                ),
                _toolAction(
                  key: const ValueKey('answer-sheet'),
                  icon: Icons.grid_on_outlined,
                  tooltip: tr('答题卡'),
                  onPressed: _openSheet,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 左下角会话统计：已答题数；练习模式叠加答错题数（答错标红）与
  /// 「未答 {n}」跳转按钮（点一下到序号最靠前的未作答题）。
  /// 考试只显示已答数，避免提前泄露对错（与「考试不提前标注」同一设计）。
  Widget _sessionStats(
    BuildContext context,
    int answered,
    int wrongCount,
    int unanswered,
    bool exam,
  ) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Row(
      key: const ValueKey('answer-stats'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            trf('已答 {n}', {'n': answered}),
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (!exam) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              trf('错 {n}', {'n': wrongCount}),
              style: style?.copyWith(
                color: wrongCount > 0 ? Colors.red : null,
                fontWeight: wrongCount > 0 ? FontWeight.w600 : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 2),
          _unansweredJump(context, unanswered),
        ],
      ],
    );
  }

  /// 「未答 {n}」小按钮：点击跳到会话里序号最靠前的未作答题。
  Widget _unansweredJump(BuildContext context, int unanswered) {
    final theme = Theme.of(context);
    return TextButton(
      key: const ValueKey('answer-jump-unanswered'),
      onPressed: unanswered > 0 ? _jumpToFirstUnanswered : null,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 26),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: theme.colorScheme.primary,
        disabledForegroundColor: theme.colorScheme.onSurfaceVariant,
        textStyle: theme.textTheme.bodySmall,
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      child: Text(
        trf('未答 {n}', {'n': unanswered}),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  void _jumpToFirstUnanswered() {
    final index = _c.firstUnansweredIndex;
    if (index != null) _c.goTo(index);
  }

  void _pick(Question q, List<String> keys) async {
    if (_locked(q)) return;
    setState(() => _drafts[q.id] = keys);
    final exam = _c.session?.isExam ?? false;
    if (exam) {
      await _c.answer(q.id, keys);
      return;
    }
    // 简易刷题：单选 / 判断选完立刻判分，省掉一次点击。
    if (_autoConfirmOn(q, exam)) await _confirm(q);
  }

  Future<void> _confirm(Question q) async {
    if (_locked(q)) return;
    final draft = _drafts[q.id] ??
        _c.answerOf(q.id) ??
        (_texts[q.id]?.text.isNotEmpty ?? false
            ? <String>[_texts[q.id]!.text]
            : const <String>[]);
    await _c.answer(q.id, draft);
    if (!mounted) return;
    _maybeAutoNext(q);
  }

  Future<void> _selfJudge(Question q, bool correct) async {
    final text = _texts[q.id]?.text ?? '';
    await _c.judgeShortAnswer(q.id, <String>[text], correct);
    if (!mounted) return;
    if (correct) _maybeAutoNext(q);
  }

  Future<void> _submit() async {
    final unanswered = _c.unansweredCount;
    final pending = _c.pendingShortCount;
    if (unanswered > 0 || pending > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('交卷')),
          content: Text(
            '${trf('还有 {n} 题未答', {'n': unanswered})}'
            '${pending > 0 ? '\n${trf('有 {n} 道简答题未自评', {'n': pending})}' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(tr('继续答题')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('交卷')),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _c.submit();
  }

  Future<void> _handleExit() async {
    // 背题是纯内存浏览会话：直接返回，不弹「退出将保存进度」也不落库。
    if (_c.session?.config.studyMode ?? false) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final exam = _c.session?.isExam ?? false;
    // 练习模式刷完全部题目：直接结束会话退出，不再记成「未完成」，
    // 也不用再让用户确认一次「稍后继续」。
    if (!exam && !_c.submitted && _c.allAnswered) {
      await _c.finishPractice();
      if (mounted) Navigator.of(context).pop();
      return;
    }
    // 已交卷 / 已结束的会话，退出就是离开，没有进度需要确认。
    if (_c.submitted) {
      await _c.saveProgress();
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final unanswered = _c.unansweredCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(exam ? tr('退出考试') : tr('退出练习')),
        content: Text(
          '${tr('退出将保存进度，可稍后继续')}'
          '${unanswered > 0 ? '\n${trf('还有 {n} 题未答', {
                  'n': unanswered
                })}' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('继续答题')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('退出')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _c.saveProgress();
    if (mounted) Navigator.of(context).pop();
  }

  void _openSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _AnswerSheet(controller: _c),
    );
  }
}

/// 答题卡格子的双通道配色：填充 = 作答 / 结果状态，边框 = 收藏标记。
/// 错误与收藏可叠加（红底 + 深色粗边框），不再依赖角标，格子因此可以缩小。
class _SheetCellPalette {
  const _SheetCellPalette({
    required this.fill,
    required this.border,
    required this.borderWidth,
  });

  final Color fill;
  final Color border;
  final double borderWidth;

  factory _SheetCellPalette.of(
    BuildContext context, {
    required AnswerState state,
    required bool wrongBook,
    required bool favorite,
  }) {
    final theme = Theme.of(context);
    final base = switch (state) {
      AnswerState.correct => Colors.green,
      AnswerState.wrong => Colors.red,
      AnswerState.pending => Colors.orange,
      // 之前进过错题本、本次还没作答的题继续标红，避免丢失错题标记。
      AnswerState.unanswered =>
        wrongBook ? Colors.red : theme.colorScheme.outline,
    };
    final neutral = state == AnswerState.unanswered && !wrongBook;
    return _SheetCellPalette(
      fill: base.withOpacity(neutral ? 0.10 : 0.38),
      // 深色主题下自动变成浅色描边，保证「深色粗边框」两种主题都看得见。
      border: favorite
          ? theme.colorScheme.onSurface
          : theme.colorScheme.outlineVariant,
      borderWidth: favorite ? 2.5 : 1,
    );
  }
}

/// 答题卡：仅用颜色区分状态、每栏 80 题分段展示，内容超出屏幕时可上下滚动。
/// 只构建当前栏的格子，题量再大也不会撑爆弹层。
class _AnswerSheet extends StatefulWidget {
  const _AnswerSheet({required this.controller});

  final QuizSessionController controller;

  @override
  State<_AnswerSheet> createState() => _AnswerSheetState();
}

class _AnswerSheetState extends State<_AnswerSheet> {
  /// 每栏题数（最后一栏可以不足）。格子缩小后一屏能放下 80 题，分页更少。
  static const int _pageSize = 80;
  static const double _groupWidth = 104;

  /// 去掉星标 / 错题角标后，格子从 44×44 / 间距 8 缩到 34×34 / 间距 6。
  static const double _cellSize = 34;
  static const double _cellSpacing = 6;

  final ScrollController _groupScroll = ScrollController();
  late final PageController _pager;
  late int _group;

  @override
  void initState() {
    super.initState();
    // 打开时自动定位到当前题目所在栏（例如答到第 45 题 → 41-80）。
    _group = widget.controller.index ~/ _pageSize;
    _pager = PageController(initialPage: _group);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _revealGroup(animated: false));
  }

  @override
  void dispose() {
    _groupScroll.dispose();
    _pager.dispose();
    super.dispose();
  }

  int _groupCount(int total) => (total + _pageSize - 1) ~/ _pageSize;

  String _groupLabel(int group, int total) {
    final start = group * _pageSize + 1;
    final next = (group + 1) * _pageSize;
    return '$start-${next > total ? total : next}';
  }

  /// 让当前栏的标签始终出现在可视区域中部。
  void _revealGroup({bool animated = true}) {
    if (!_groupScroll.hasClients) return;
    final position = _groupScroll.position;
    final raw =
        _group * _groupWidth + _groupWidth / 2 - position.viewportDimension / 2;
    final offset = raw.clamp(0.0, position.maxScrollExtent).toDouble();
    if (animated) {
      _groupScroll.animateTo(offset,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    } else {
      _groupScroll.jumpTo(offset);
    }
  }

  void _selectGroup(int group) {
    if (group == _group) return;
    setState(() => _group = group);
    _revealGroup();
    if (_pager.hasClients) {
      _pager.animateToPage(group,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  /// 一屏能放几列：格子与间距固定，按弹层实际宽度算，宽屏自动多排。
  int _columnsFor(double width) {
    final raw = ((width + _cellSpacing) / (_cellSize + _cellSpacing)).floor();
    return raw < 1 ? 1 : raw;
  }

  /// 一栏所需高度：Wrap 换行后的行数 × 格子 + 行间距。
  double _gridHeight(int items, int columns) {
    if (items <= 0) return 0;
    final rows = (items + columns - 1) ~/ columns;
    return rows * _cellSize + (rows - 1) * _cellSpacing;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.controller;
    final total = c.questions.length;
    final groupCount = _groupCount(total);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 水平内边距左右各 16；分栏高度按首栏题数算（最后一栏只会更矮）。
            final columns = _columnsFor(constraints.maxWidth - 32);
            final firstPage = total < _pageSize ? total : _pageSize;
            final pageHeight = _gridHeight(firstPage, columns);
            return SingleChildScrollView(
              key: const ValueKey('answer-sheet-scroll'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: AnimatedBuilder(
                animation: c,
                builder: (context, _) {
                  var group = _group;
                  if (groupCount > 0 && group >= groupCount) {
                    group = groupCount - 1;
                  }
                  if (group < 0) group = 0;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(tr('答题卡'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      if (groupCount > 1) ...[
                        SizedBox(
                          height: 44,
                          child: ListView.builder(
                            key: const ValueKey('answer-sheet-groups'),
                            controller: _groupScroll,
                            scrollDirection: Axis.horizontal,
                            itemExtent: _groupWidth,
                            itemCount: groupCount,
                            itemBuilder: (context, i) => Center(
                              child: ChoiceChip(
                                key: ValueKey<String>('sheet-group-$i'),
                                label: Text(_groupLabel(i, total)),
                                selected: i == group,
                                onSelected: (_) => _selectGroup(i),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      // 每一栏一页，可左右滑动翻页；点上方栏号同样会滑过去。
                      SizedBox(
                        height: pageHeight,
                        child: PageView.builder(
                          key: const ValueKey('answer-sheet-pager'),
                          controller: _pager,
                          itemCount: groupCount == 0 ? 1 : groupCount,
                          onPageChanged: (i) {
                            setState(() => _group = i);
                            _revealGroup();
                          },
                          itemBuilder: (context, i) => Align(
                            alignment: Alignment.topLeft,
                            child: Wrap(
                              spacing: _cellSpacing,
                              runSpacing: _cellSpacing,
                              children: _pageCells(theme, i, total),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 14,
                        runSpacing: 6,
                        children: [
                          _legend(context, tr('未答'),
                              theme.colorScheme.outline.withOpacity(0.10)),
                          _legend(context, tr('已答'),
                              Colors.green.withOpacity(0.38)),
                          _legend(
                              context, tr('错误'), Colors.red.withOpacity(0.38)),
                          _legend(context, tr('待自评'),
                              Colors.orange.withOpacity(0.38)),
                          _legend(
                            context,
                            tr('收藏'),
                            theme.colorScheme.outline.withOpacity(0.10),
                            border: theme.colorScheme.onSurface,
                            borderWidth: 2.5,
                          ),
                          _legend(
                            context,
                            tr('当前题'),
                            theme.colorScheme.outline.withOpacity(0.10),
                            ring: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  /// 只构建本栏的格子：题量再大，单页也只有 [pageSize] 个。
  List<Widget> _pageCells(ThemeData theme, int group, int total) {
    final start = group * _pageSize;
    final end = start + _pageSize > total ? total : start + _pageSize;
    return <Widget>[
      for (var i = start; i < end; i++) _cell(theme, i),
    ];
  }

  Widget _cell(ThemeData theme, int i) {
    final c = widget.controller;
    final q = c.questions[i];
    final state = c.stateOf(q.id);
    final current = i == c.index;
    final palette = _SheetCellPalette.of(
      context,
      state: state,
      wrongBook: c.isWrong(q.id),
      favorite: c.isFavorite(q.id),
    );
    return GestureDetector(
      onTap: () {
        c.goTo(i);
        Navigator.of(context).pop();
      },
      child: Container(
        key: ValueKey<String>('sheet-$i'),
        width: _cellSize,
        height: _cellSize,
        decoration: BoxDecoration(
          color: palette.fill,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: palette.border, width: palette.borderWidth),
          // 当前题用主题色外圈标记，不占用边框通道，收藏状态仍可读。
          boxShadow: current
              ? <BoxShadow>[
                  BoxShadow(
                    color: theme.colorScheme.primary,
                    blurRadius: 0,
                    spreadRadius: 2,
                    offset: Offset.zero,
                  )
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          '${i + 1}',
          style: theme.textTheme.bodySmall?.copyWith(
            height: 1,
            // 彩色/深色填充块上按实际合成色取前景：深色底自动白字。
            color: AppTheme.readableOn(
              palette.fill,
              base: theme.colorScheme.surface,
            ),
            fontWeight: current ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 图例色块与实际格子用同一套「填充 + 边框（+ 当前题外圈）」编码。
  Widget _legend(
    BuildContext context,
    String label,
    Color fill, {
    Color? border,
    double borderWidth = 1,
    Color? ring,
  }) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: border ?? theme.colorScheme.outlineVariant,
              width: borderWidth,
            ),
            boxShadow: ring == null
                ? null
                : <BoxShadow>[
                    BoxShadow(color: ring, blurRadius: 0, spreadRadius: 1.5)
                  ],
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// 判分后单个选项的标注：底色（错选红 / 漏选绿）与文字色（选对的正确项变绿）。
class _OptionMark {
  const _OptionMark({this.background, this.text, this.border});

  /// 底色：错选红 / 漏选绿（答对时不铺底色）。
  final Color? background;

  /// 文字色：选对的正确选项变绿。
  final Color? text;

  /// 描边色：判分后与底色同步，未标注时用主题淡描边。
  final Color? border;
}
