import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import 'quiz_answer_page.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import '../state/quiz_session_controller.dart';
import 'quiz_common.dart';

/// 抽题页库存：总库存 + 历史「没做过」的库存，一次查库供开关切换复用。
class _StockData {
  const _StockData(this.total, this.unseen);

  const _StockData.empty()
      : total = const <QuestionType, int>{},
        unseen = const <QuestionType, int>{};

  final Map<QuestionType, int> total;
  final Map<QuestionType, int> unseen;

  int get unseenTotal => unseen.values.fold<int>(0, (a, b) => a + b);
}

/// 练习 / 考试配置页。
class QuizConfigPage extends StatefulWidget {
  const QuizConfigPage({
    super.key,
    required this.repo,
    this.bankId,
    this.exam = false,
    this.initialMode,
  });

  final QuizRepository repo;
  final String? bankId;

  /// true = 模拟考试配置。
  final bool exam;

  /// 直接进入某个模式（错题练习 / 收藏练习）。
  final QuizMode? initialMode;

  @override
  State<QuizConfigPage> createState() => _QuizConfigPageState();
}

class _QuizConfigPageState extends State<QuizConfigPage> {
  late Future<_StockData> _stock;
  QuizMode _mode = QuizMode.all;
  final Map<QuestionType, int> _counts = <QuestionType, int>{};

  /// 每种题型的数量输入框。放在 state 里而不是 build 里：否则每次重建都会
  /// 用控制器文本覆盖用户输入，且初始的 “0” 会一直留在框里和光标重叠。
  final Map<QuestionType, TextEditingController> _countInputs =
      <QuestionType, TextEditingController>{
    for (final type in allQuestionTypes) type: TextEditingController(),
  };
  bool _scoreEnabled = false;
  double _globalScore = 2;
  final Map<QuestionType, double> _typeScores = <QuestionType, double>{};
  bool _timed = false;
  int _minutes = 30;
  bool _shuffleOptions = true;
  bool _shuffleQuestions = true;
  bool _onlyUnseen = false;
  bool _lockAfterConfirm = false;
  bool _autoNextOnCorrect = false;
  bool _simpleMode = false;
  final TextEditingController _wrongThreshold =
      TextEditingController(text: '1');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode ?? (widget.exam ? QuizMode.exam : QuizMode.all);
    _timed = widget.exam;
    _stock = _loadStock();
    _loadDefaults();
  }

  /// 同时取回总库存与「没做过」的库存：切换开关时不重新查库、不闪一下。
  Future<_StockData> _loadStock() async {
    final total = await widget.repo.stockOf(widget.bankId);
    final unseen = await widget.repo.unseenStockOf(widget.bankId);
    return _StockData(total, unseen);
  }

  @override
  void dispose() {
    for (final controller in _countInputs.values) {
      controller.dispose();
    }
    _wrongThreshold.dispose();
    super.dispose();
  }

  /// 读取备份页里保存的默认设置。
  Future<void> _loadDefaults() async {
    final score = await widget.repo.getSetting('globalScore');
    final so = await widget.repo.getSetting('shuffleOptions');
    final sq = await widget.repo.getSetting('shuffleQuestions');
    final unseen = await widget.repo.getSetting('onlyUnseen');
    final lock = await widget.repo.getSetting('lockAfterConfirm');
    final autoNext = await widget.repo.getSetting('autoNextOnCorrect');
    final threshold = await widget.repo.getSetting('wrongRemoveThreshold');
    final simple = await widget.repo.getSetting('simpleMode');
    if (!mounted) return;
    setState(() {
      final value = double.tryParse(score ?? '');
      if (value != null) _globalScore = value;
      _shuffleOptions = so != 'false';
      _shuffleQuestions = sq != 'false';
      _onlyUnseen = unseen == 'true';
      _lockAfterConfirm = lock == 'true';
      _autoNextOnCorrect = autoNext == 'true';
      _simpleMode = simple == 'true';
      final n = int.tryParse(threshold ?? '');
      if (n != null) _wrongThreshold.text = '${n.clamp(1, 99)}';
    });
  }

  bool get _needCounts => _mode == QuizMode.random || _mode == QuizMode.exam;

  Future<void> _start() async {
    final onlyUnseen = _onlyUnseen;
    if (onlyUnseen && (await _stock).unseenTotal == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('没做过的题已刷完，关闭该选项可重新练习'))),
      );
      return;
    }
    setState(() => _busy = true);
    final threshold = (int.tryParse(_wrongThreshold.text) ?? 1).clamp(1, 99);
    // 记住本次选择：下次进入配置页、以及旧会话续答都读同一套设置。
    await widget.repo.setSetting('wrongRemoveThreshold', '$threshold');
    final config = QuizConfig(
      typeCounts: _needCounts
          ? Map<QuestionType, int>.from(_counts)
          : const <QuestionType, int>{},
      scoreEnabled: _scoreEnabled,
      globalScore: _scoreEnabled ? _globalScore : null,
      typeScores: _scoreEnabled
          ? Map<QuestionType, double>.from(_typeScores)
          : const <QuestionType, double>{},
      durationSec: _timed ? _minutes * 60 : null,
      shuffleOptions: _shuffleOptions,
      shuffleQuestions: _shuffleQuestions,
      onlyUnseen: onlyUnseen,
      lockAfterConfirm: _lockAfterConfirm,
      autoNextOnCorrect: _autoNextOnCorrect,
      wrongRemoveThreshold: threshold,
      simpleMode: _simpleMode,
    );
    final controller = QuizSessionController(widget.repo);
    final ok = await controller.start(
      bankId: widget.bankId,
      mode: _mode,
      config: config,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('没有可练习的题目'))),
      );
      controller.dispose();
      return;
    }
    await Navigator.of(context).pushReplacement(quizRoute<void>(
        builder: (_) =>
            QuizAnswerPage(repo: widget.repo, controller: controller)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.exam ? tr('模拟考试') : tr('练习'))),
      body: FutureBuilder<_StockData>(
        future: _stock,
        builder: (context, snapshot) {
          final data = snapshot.data ?? const _StockData.empty();
          final stock = _onlyUnseen ? data.unseen : data.total;
          final total = data.total.values.fold<int>(0, (a, b) => a + b);
          final unseenTotal = data.unseen.values.fold<int>(0, (a, b) => a + b);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Text(tr('模式'), style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  if (widget.initialMode != null)
                    _modeChip(
                        widget.initialMode!, _modeName(widget.initialMode!))
                  else if (widget.exam)
                    _modeChip(QuizMode.exam, tr('考试'))
                  else ...[
                    _modeChip(QuizMode.all, tr('全部')),
                    _modeChip(QuizMode.random, tr('随机')),
                    _modeChip(QuizMode.wrong, tr('错题')),
                    _modeChip(QuizMode.favorite, tr('收藏')),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                key: const ValueKey('config-only-unseen'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr('已做过的题不出现')),
                value: _onlyUnseen,
                onChanged: (v) => setState(() => _onlyUnseen = v),
              ),
              if (_onlyUnseen && unseenTotal == 0)
                SmallHint(
                  text: tr('没做过的题已刷完，关闭该选项可重新练习'),
                  color: theme.colorScheme.error,
                ),
              if (total == 0 && !_needCounts) ...[
                const SizedBox(height: 12),
                SmallHint(
                  text: tr('题库为空，请先导入题目'),
                  color: theme.colorScheme.error,
                ),
              ],
              if (_needCounts) ...[
                const SizedBox(height: 16),
                Text(tr('抽题数量'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                ...allQuestionTypes.map((type) {
                  final have = stock[type] ?? 0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: SizedBox(
                      height: 42,
                      child: Row(
                        children: [
                          SizedBox(width: 56, child: Text(typeLabel(type))),
                          Expanded(
                            child: Text(
                              trf(_onlyUnseen ? '未做 {n} 题' : '库存 {n} 题',
                                  {'n': have}),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: have == 0 ? Colors.red : null,
                              ),
                            ),
                          ),
                          NumberStepField(
                            controller: _countInputs[type]!,
                            fieldKey: ValueKey<String>('count-${type.key}'),
                            stepKeyPrefix: 'count-${type.key}',
                            width: 116,
                            onChanged: (value) {
                              final n = int.tryParse(value) ?? 0;
                              if (n <= 0) {
                                _counts.remove(type);
                              } else {
                                _counts[type] = n;
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
              const SizedBox(height: 20),
              SwitchListTile(
                key: const ValueKey('config-score'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr('计分模式')),
                subtitle: Text(_scoreEnabled ? tr('按分值计分') : tr('只统计对错')),
                value: _scoreEnabled,
                onChanged: (v) => setState(() => _scoreEnabled = v),
              ),
              if (_scoreEnabled) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(width: 80, child: Text(tr('全局分值'))),
                    Expanded(
                      child: Slider(
                        value: _globalScore,
                        min: 1,
                        max: 10,
                        divisions: 18,
                        label: _globalScore.toStringAsFixed(1),
                        onChanged: (v) => setState(() => _globalScore = v),
                      ),
                    ),
                    Text(_globalScore.toStringAsFixed(1)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  tr('分值优先级：单题分值 > 题型分值 > 全局分值'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                ...allQuestionTypes.map((type) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          SizedBox(width: 80, child: Text(typeLabel(type))),
                          Expanded(
                            child: Slider(
                              value: _typeScores[type] ?? _globalScore,
                              min: 1,
                              max: 10,
                              divisions: 18,
                              label: (_typeScores[type] ?? _globalScore)
                                  .toStringAsFixed(1),
                              onChanged: (v) =>
                                  setState(() => _typeScores[type] = v),
                            ),
                          ),
                          Text((_typeScores[type] ?? _globalScore)
                              .toStringAsFixed(1)),
                        ],
                      ),
                    )),
              ],
              const SizedBox(height: 12),
              SwitchListTile(
                key: const ValueKey('config-timer'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr('计时')),
                subtitle:
                    Text(_timed ? trf('{n} 分钟', {'n': _minutes}) : tr('不限时')),
                value: _timed,
                onChanged: (v) => setState(() => _timed = v),
              ),
              if (_timed)
                Row(
                  children: [
                    SizedBox(width: 80, child: Text(tr('时长'))),
                    Expanded(
                      child: Slider(
                        value: _minutes.toDouble(),
                        min: 5,
                        max: 180,
                        divisions: 35,
                        label: '$_minutes',
                        onChanged: (v) => setState(() => _minutes = v.round()),
                      ),
                    ),
                    Text('${tr('分钟')} $_minutes'),
                  ],
                ),
              SwitchListTile(
                key: const ValueKey('config-shuffle-options'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr('选项乱序')),
                value: _shuffleOptions,
                onChanged: (v) => setState(() => _shuffleOptions = v),
              ),
              SwitchListTile(
                key: const ValueKey('config-shuffle-questions'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr('题目乱序')),
                value: _shuffleQuestions,
                onChanged: (v) => setState(() => _shuffleQuestions = v),
              ),
              SwitchListTile(
                key: const ValueKey('config-simple-mode'),
                contentPadding: EdgeInsets.zero,
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(tr('简易刷题')),
                    InfoHint(
                      key: const ValueKey('config-simple-mode-hint'),
                      text: tr('单选和判断题选完即自动确认，不再显示确认按钮；'
                          '上一题 / 下一题按钮也会隐藏，左右滑动即可翻页'),
                    ),
                  ],
                ),
                value: _simpleMode,
                onChanged: (v) {
                  setState(() => _simpleMode = v);
                  widget.repo.setSetting('simpleMode', '$v');
                },
              ),
              SwitchListTile(
                key: const ValueKey('config-lock-after-confirm'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr('确认后禁止修改')),
                value: _lockAfterConfirm,
                onChanged: (v) {
                  setState(() => _lockAfterConfirm = v);
                  widget.repo.setSetting('lockAfterConfirm', '$v');
                },
              ),
              SwitchListTile(
                key: const ValueKey('config-auto-next'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr('答对切换下一题')),
                value: _autoNextOnCorrect,
                onChanged: (v) {
                  setState(() => _autoNextOnCorrect = v);
                  widget.repo.setSetting('autoNextOnCorrect', '$v');
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        tr('答对错题移出错题本次数'),
                        maxLines: 2,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    NumberStepField(
                      controller: _wrongThreshold,
                      fieldKey: const ValueKey('config-wrong-threshold'),
                      stepKeyPrefix: 'config-wrong-threshold',
                      min: 1,
                      max: 99,
                      width: 104,
                      hint: '1',
                      onChanged: (value) {
                        final n = int.tryParse(value);
                        if (n != null && n >= 1) {
                          widget.repo.setSetting('wrongRemoveThreshold', '$n');
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            key: const ValueKey('config-start'),
            onPressed: _busy ? null : _start,
            child: Text(_busy ? tr('准备中') : tr('开始')),
          ),
        ),
      ),
    );
  }

  String _modeName(QuizMode mode) => switch (mode) {
        QuizMode.all => tr('顺序练习'),
        QuizMode.random => tr('随机练习'),
        QuizMode.wrong => tr('错题练习'),
        QuizMode.favorite => tr('收藏练习'),
        QuizMode.exam => tr('模拟考试'),
      };

  Widget _modeChip(QuizMode mode, String label) => ChoiceChip(
        key: ValueKey<String>('mode-${mode.key}'),
        label: Text(label),
        selected: _mode == mode,
        onSelected: (_) => setState(() => _mode = mode),
      );
}
