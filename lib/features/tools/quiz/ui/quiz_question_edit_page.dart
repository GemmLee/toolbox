import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import 'quiz_common.dart';

/// 题目内容编辑器：修改题干、选项、正确答案与解析，覆盖保存到题库。
///
/// 题型、id、所属题库与排序保持不变，避免影响正在进行的会话、错题和收藏关联。
/// 判断题的选项不由用户编辑，但保存时必须写回固定的「正确 / 错误」两项——
/// 答题页的选项列表直接来自 `question.options`，留空会让判断题变成没有选项。
class QuestionEditPage extends StatefulWidget {
  const QuestionEditPage({
    super.key,
    this.repo,
    required this.question,
    this.saver,
  });

  final QuizRepository? repo;
  final Question question;

  /// 测试注入：替换持久化动作；不传时走 [repo] 的覆盖保存。
  final Future<void> Function(Question question)? saver;

  @override
  State<QuestionEditPage> createState() => _QuestionEditPageState();
}

class _OptionDraft {
  _OptionDraft(this.key, String text) {
    controller.text = text;
  }

  final String key;
  final TextEditingController controller = TextEditingController();

  String get value => controller.text;
}

class _QuestionEditPageState extends State<QuestionEditPage> {
  late final TextEditingController _stem;
  late final TextEditingController _analysis;
  late final TextEditingController _answerText;
  late final List<_OptionDraft> _options;
  late final Set<String> _answerKeys;
  bool _saving = false;

  Question get _q => widget.question;
  bool get _objective => _q.type.hasOptions;
  bool get _judge => _q.type == QuestionType.trueFalse;

  @override
  void initState() {
    super.initState();
    _stem = TextEditingController(text: _q.stem);
    _analysis = TextEditingController(text: _q.analysis ?? '');
    _answerKeys = _q.answer.toSet();
    _answerText = TextEditingController(text: _q.answer.join('\n'));
    if (_judge) {
      _options = <_OptionDraft>[
        _OptionDraft('true', tr('正确')),
        _OptionDraft('false', tr('错误')),
      ];
    } else if (_objective) {
      final source = _q.options.isEmpty
          ? <OptionItem>[
              const OptionItem(key: 'A', text: ''),
              const OptionItem(key: 'B', text: ''),
            ]
          : _q.options;
      _options = source.map((o) => _OptionDraft(o.key, o.text)).toList();
    } else {
      _options = <_OptionDraft>[];
    }
  }

  @override
  void dispose() {
    _stem.dispose();
    _analysis.dispose();
    _answerText.dispose();
    for (final o in _options) {
      o.controller.dispose();
    }
    super.dispose();
  }

  String _nextKey() {
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final used = _options.map((o) => o.key).toSet();
    for (final c in letters.split('')) {
      if (!used.contains(c)) return c;
    }
    var i = _options.length + 1;
    while (used.contains('O$i')) {
      i++;
    }
    return 'O$i';
  }

  void _addOption() {
    setState(() => _options.add(_OptionDraft(_nextKey(), '')));
  }

  void _removeOption(int index) {
    final removed = _options[index].key;
    setState(() {
      _options.removeAt(index).controller.dispose();
      _answerKeys.remove(removed);
    });
  }

  void _toggleAnswer(String key) {
    setState(() {
      if (_q.type == QuestionType.single || _judge) {
        _answerKeys
          ..clear()
          ..add(key);
      } else if (!_answerKeys.remove(key)) {
        _answerKeys.add(key);
      }
    });
  }

  List<String> _collectAnswer() {
    if (!_objective) {
      return _answerText.text
          .split(RegExp(r'[\n;；]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    // 按选项顺序输出，避免答案顺序随点击次序漂移。
    return _options
        .map((o) => o.key)
        .where(_answerKeys.contains)
        .toList(growable: false);
  }

  Future<void> _save() async {
    if (_saving) return;
    final stem = _stem.text.trim();
    if (stem.isEmpty) {
      showToast(context, tr('题干不能为空'));
      return;
    }
    final answer = _collectAnswer();
    if (answer.isEmpty) {
      showToast(context, tr('请填写正确答案'));
      return;
    }
    if (_objective && !_judge) {
      if (_options.any((o) => o.value.trim().isEmpty)) {
        showToast(context, tr('选项内容不能为空'));
        return;
      }
      if (_q.type == QuestionType.single && answer.length > 1) {
        showToast(context, tr('单选题只能有一个正确答案'));
        return;
      }
    }
    // 判断题写回固定两项（用户改不了文本，但选项必须留在库里）。
    final options = _judge
        ? kJudgeOptions
        : (!_objective
            ? const <OptionItem>[]
            : _options
                .map((o) => OptionItem(key: o.key, text: o.value.trim()))
                .toList(growable: false));
    final analysis = _analysis.text.trim();
    final updated = widget.question.withContent(
      stem: stem,
      options: options,
      answer: answer,
      analysis: analysis.isEmpty ? null : analysis,
    );
    setState(() => _saving = true);
    try {
      final saver = widget.saver ?? widget.repo?.updateQuestion;
      if (saver == null) {
        throw StateError('Missing QuizRepository');
      }
      await saver(updated);
      if (!mounted) return;
      Navigator.of(context).pop(updated);
    } catch (e) {
      if (mounted) {
        showToast(context, trf('保存失败：{e}', {'e': '$e'}));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('编辑题目')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton.tonalIcon(
              key: const ValueKey('question-edit-save'),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text(tr('保存')),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _card(children: <Widget>[
            Row(
              children: [
                Chip(label: Text(typeLabel(_q.type))),
                const SizedBox(width: 8),
                SmallHint(text: tr('题型不可修改')),
              ],
            ),
            const SizedBox(height: 10),
            Text(tr('题干'), style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey('question-edit-stem'),
              controller: _stem,
              maxLines: 5,
              minLines: 2,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ]),
          if (_objective) _optionsCard(theme),
          _answerCard(theme),
          _card(children: <Widget>[
            Text(tr('解析'), style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey('question-edit-analysis'),
              controller: _analysis,
              maxLines: 4,
              minLines: 2,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _card({required List<Widget> children}) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      );

  Widget _optionsCard(ThemeData theme) {
    return _card(children: <Widget>[
      Row(
        children: [
          Text(tr('选项'), style: theme.textTheme.titleSmall),
          const Spacer(),
          if (!_judge)
            TextButton.icon(
              key: const ValueKey('question-edit-add-option'),
              onPressed: _addOption,
              icon: const Icon(Icons.add, size: 16),
              label: Text(tr('添加选项')),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
      if (_judge)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: SmallHint(text: tr('判断题的选项由应用自动生成')),
        ),
      for (var i = 0; i < _options.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  _judge ? '' : _options[i].key,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: _judge
                    ? Text(_options[i].value, style: theme.textTheme.bodyMedium)
                    : TextField(
                        key: ValueKey<String>(
                            'question-edit-option-${_options[i].key}'),
                        controller: _options[i].controller,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
              ),
              if (!_judge)
                IconButton(
                  key: ValueKey<String>(
                      'question-edit-remove-${_options[i].key}'),
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: tr('删除选项'),
                  onPressed:
                      _options.length <= 2 ? null : () => _removeOption(i),
                ),
            ],
          ),
        ),
    ]);
  }

  Widget _answerCard(ThemeData theme) {
    return _card(children: <Widget>[
      Text(
        _q.type == QuestionType.short ? tr('参考答案') : tr('正确答案'),
        style: theme.textTheme.titleSmall,
      ),
      const SizedBox(height: 8),
      if (_objective)
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final o in _options)
              FilterChip(
                key: ValueKey<String>('question-edit-answer-${o.key}'),
                label: Text(
                    _judge ? (o.key == 'true' ? tr('正确') : tr('错误')) : o.key),
                selected: _answerKeys.contains(o.key),
                onSelected: (_) => _toggleAnswer(o.key),
              ),
          ],
        )
      else ...<Widget>[
        TextField(
          key: const ValueKey('question-edit-answer-text'),
          controller: _answerText,
          maxLines: 4,
          minLines: 2,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 4),
        SmallHint(text: tr('多个可接受答案每行一个')),
      ],
    ]);
  }
}
