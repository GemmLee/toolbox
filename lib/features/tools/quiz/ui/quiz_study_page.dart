import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/mini_segmented.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import '../state/quiz_session_controller.dart';
import 'quiz_answer_page.dart';
import 'quiz_common.dart';

/// 背题范围。
enum StudyScope { all, byType, wrong, favorite }

/// 背题页一次载入的候选数据，之后切换范围 / 题型只在内存里过滤。
class StudyData {
  const StudyData({
    required this.all,
    required this.wrong,
    required this.favorite,
    required this.studied,
  });

  final List<Question> all;
  final List<Question> wrong;
  final List<Question> favorite;

  /// 该题库已背过的题目（记录栏展示 + 「已背不出现」过滤）。
  final List<Question> studied;

  Set<String> get studiedIds => studied.map((q) => q.id).toSet();

  List<Question> pick(StudyScope scope, Set<QuestionType> types) {
    final source = switch (scope) {
      StudyScope.all || StudyScope.byType => all,
      StudyScope.wrong => wrong,
      StudyScope.favorite => favorite,
    };
    if (scope != StudyScope.byType || types.isEmpty) {
      return List<Question>.of(source);
    }
    return source.where((q) => types.contains(q.type)).toList();
  }
}

/// 从某个题库读取背题候选（全量，不用默认 50 条分页口径）。
Future<StudyData> loadStudyData(QuizRepository repo, String bankId) async {
  return StudyData(
    all: await repo.questionsOfBank(bankId, limit: 100000),
    wrong: await repo.wrongQuestions(bankId: bankId),
    favorite: await repo.favoriteQuestions(bankId: bankId),
    studied: await repo.studiedQuestions(bankId),
  );
}

/// 背题模式配置页：选择题型范围后进入答题页，答案与解析默认展开。
///
/// 会话纯内存，不计分、不写练习记录 / 错题本，也不出现在「继续上次」；
/// 只有「背题记录」会落到该题库（多次累计去重）。
class QuizStudyPage extends StatefulWidget {
  const QuizStudyPage({
    super.key,
    required this.repo,
    required this.bankId,
    this.loader,
    this.historyClearer,
    this.studyRecorder,
    Random? random,
  }) : _random = random;

  final QuizRepository repo;
  final String bankId;

  /// 测试注入点：真实 I/O 在 FakeAsync 下不可用。
  final Future<StudyData> Function(QuizRepository repo, String bankId)? loader;

  /// 清空背题记录注入点。
  final Future<void> Function(QuizRepository repo, String bankId)?
      historyClearer;

  /// 背题翻题记录注入点（传给会话控制器）。
  final Future<void> Function(String bankId, String questionId)? studyRecorder;

  final Random? _random;

  @override
  State<QuizStudyPage> createState() => _QuizStudyPageState();
}

class _QuizStudyPageState extends State<QuizStudyPage> {
  late Future<StudyData> _future;
  Random _random = Random();
  final TextEditingController _countController = TextEditingController();

  StudyScope _scope = StudyScope.all;
  final Set<QuestionType> _types = <QuestionType>{};
  bool _shuffle = false;
  bool _skipStudied = false;
  bool _countTouched = false; // false = 跟随最大值（默认）
  int _count = 1;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget._random != null) _random = widget._random!;
    // 默认（未改动）时输入框留空，用 hint 显示当前最大值，避免显示 1 实际背 2。
    _countController.text = '';
    _load();
  }

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  void _load() {
    final loader = widget.loader ?? loadStudyData;
    _future = loader(widget.repo, widget.bankId);
  }

  /// 当前范围 + 题型下的候选（可排除已背过的）。
  List<Question> _candidates(StudyData data) {
    final picked = data.pick(_scope, _types);
    if (!_skipStudied) return picked;
    final studied = data.studiedIds;
    return picked.where((q) => !studied.contains(q.id)).toList();
  }

  /// 当前实际要背的题目（应用数量截断 + 乱序）。
  List<Question> _visibleOf(StudyData data) {
    final candidates = _candidates(data);
    final max = candidates.length;
    final wanted = max <= 0 ? 0 : (_countTouched ? _count.clamp(1, max) : max);
    final picked = candidates.take(wanted).toList();
    if (_shuffle) picked.shuffle(_random);
    return picked;
  }

  void _resetOptions() {
    setState(() {
      _countTouched = false;
      _countController.text = '';
    });
  }

  Future<void> _start(StudyData data) async {
    if (_busy) return;
    final questions = _visibleOf(data);
    if (questions.isEmpty) {
      showToast(context, tr('没有可背的题目'));
      return;
    }
    setState(() => _busy = true);
    final controller = QuizSessionController(
      widget.repo,
      random: _random,
      onStudy: widget.studyRecorder,
    );
    final ok = await controller.startStudy(questions);
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() => _busy = false);
    if (!ok) {
      controller.dispose();
      showToast(context, tr('没有可背的题目'));
      return;
    }
    // 控制器所有权交给答题页（与练习配置页一致），这里不再重复释放。
    await Navigator.of(context).push(quizRoute<void>(
      builder: (_) => QuizAnswerPage(repo: widget.repo, controller: controller),
    ));
    // 从答题页返回后刷新记录（背过的题已写入）。
    if (mounted) setState(_load);
  }

  Future<void> _clearHistory() async {
    final clearer = widget.historyClearer ??
        (QuizRepository repo, String bankId) => repo.clearStudyHistory(bankId);
    await clearer(widget.repo, widget.bankId);
    if (!mounted) return;
    setState(_load);
    showToast(context, tr('已清空背题记录'));
  }

  Widget _switchRow({
    required Key key,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title),
      value: value,
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('背题模式'))),
      body: FutureBuilder<StudyData>(
        future: _future,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final max = _candidates(data).length;
          final count = _visibleOf(data).length;
          final sliderMax = max <= 0 ? 1 : max;
          final shown = _countTouched ? _count.clamp(1, sliderMax) : sliderMax;
          return ListView(
            key: const ValueKey('study-list'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              SectionCard(
                title: tr('背题范围'),
                dense: true,
                children: <Widget>[
                  MiniSegmented<StudyScope>(
                    expanded: true,
                    selected: _scope,
                    onChanged: (value) => setState(() {
                      _scope = value;
                      if (value != StudyScope.byType) _types.clear();
                      _resetOptions();
                    }),
                    options: <MiniSegmentedOption<StudyScope>>[
                      MiniSegmentedOption<StudyScope>(
                        value: StudyScope.all,
                        label: tr('全部'),
                        key: const ValueKey('study-scope-all'),
                      ),
                      MiniSegmentedOption<StudyScope>(
                        value: StudyScope.byType,
                        label: tr('按题型'),
                        key: const ValueKey('study-scope-type'),
                      ),
                      MiniSegmentedOption<StudyScope>(
                        value: StudyScope.wrong,
                        label: tr('错题'),
                        key: const ValueKey('study-scope-wrong'),
                      ),
                      MiniSegmentedOption<StudyScope>(
                        value: StudyScope.favorite,
                        label: tr('收藏'),
                        key: const ValueKey('study-scope-favorite'),
                      ),
                    ],
                  ),
                ],
              ),
              if (_scope == StudyScope.byType) ...<Widget>[
                const SizedBox(height: 12),
                SectionCard(
                  title: tr('选择题型'),
                  subtitle: tr('不选则包含全部题型'),
                  dense: true,
                  children: <Widget>[
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final type in allQuestionTypes)
                          FilterChip(
                            key: ValueKey<String>('study-type-${type.key}'),
                            label: Text(typeLabel(type)),
                            selected: _types.contains(type),
                            onSelected: (_) => setState(() {
                              if (!_types.remove(type)) _types.add(type);
                              _resetOptions();
                            }),
                          ),
                      ],
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              SectionCard(
                title: tr('背题选项'),
                dense: true,
                children: <Widget>[
                  _switchRow(
                    key: const ValueKey('study-shuffle'),
                    title: tr('题目乱序'),
                    value: _shuffle,
                    onChanged: (v) => setState(() => _shuffle = v),
                  ),
                  _switchRow(
                    key: const ValueKey('study-skip-studied'),
                    title: tr('已背过的题不出现'),
                    value: _skipStudied,
                    onChanged: (v) => setState(() {
                      _skipStudied = v;
                      _resetOptions();
                    }),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      SizedBox(
                        width: 72,
                        child:
                            Text(tr('背题数量'), style: theme.textTheme.bodyMedium),
                      ),
                      Expanded(
                        child: Slider(
                          key: const ValueKey('study-count-slider'),
                          value: shown.toDouble(),
                          min: 1,
                          max: sliderMax.toDouble(),
                          divisions: sliderMax <= 1 ? null : sliderMax - 1,
                          label: '$shown',
                          onChanged: max <= 0
                              ? null
                              : (v) {
                                  final n = v.round().clamp(1, sliderMax);
                                  setState(() {
                                    _countTouched = true;
                                    _count = n;
                                    _countController.text = '$n';
                                  });
                                },
                        ),
                      ),
                      const SizedBox(width: 8),
                      NumberStepField(
                        controller: _countController,
                        fieldKey: const ValueKey('study-count-input'),
                        min: 1,
                        max: sliderMax.toDouble(),
                        width: 100,
                        hint: '$shown',
                        onChanged: (text) {
                          final parsed = int.tryParse(text.trim());
                          if (parsed == null) return;
                          final n = parsed.clamp(1, sliderMax);
                          setState(() {
                            _countTouched = true;
                            _count = n;
                          });
                          if (n != parsed) {
                            _countController.text = '$n';
                            _countController.selection =
                                TextSelection.collapsed(
                                    offset: _countController.text.length);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: tr('背题记录'),
                subtitle: trf('已背 {n} 题', {'n': data.studied.length}),
                dense: true,
                trailing: data.studied.isEmpty
                    ? null
                    : IconButton(
                        key: const ValueKey('study-history-clear'),
                        tooltip: tr('清空背题记录'),
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: _clearHistory,
                      ),
                children: <Widget>[
                  if (data.studied.isEmpty)
                    SmallHint(text: tr('暂无背题记录'))
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (final q in data.studied.take(8))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '· ${q.stem}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        if (data.studied.length > 8)
                          Text(
                            trf('还有 {n} 题', {'n': data.studied.length - 8}),
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SmallHint(
                text: tr('进入即显示正确答案与解析，不记分、不写入练习记录'),
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  trf('共 {n} 题', {'n': count}),
                  key: const ValueKey('study-count'),
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FutureBuilder<StudyData>(
            future: _future,
            builder: (context, snapshot) => FilledButton.icon(
              key: const ValueKey('study-start'),
              icon: const Icon(Icons.menu_book_outlined),
              label: Text(tr('开始背题')),
              onPressed: snapshot.data == null || _busy
                  ? null
                  : () => _start(snapshot.data!),
            ),
          ),
        ),
      ),
    );
  }
}
