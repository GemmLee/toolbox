import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import 'quiz_ai_panel.dart';
import 'quiz_common.dart';
import 'quiz_question_edit_page.dart';

/// 题目详情底部面板：正确答案、解析、收藏 / 移出错题，以及编辑题目内容。
///
/// [questions] 传入后支持左右滑动切题（列表内当前题由 [question] 定位）；
/// 不传则只显示单题。
Future<void> showQuestionDetail(
  BuildContext context,
  QuizRepository repo,
  Question question, {
  List<Question>? questions,
  VoidCallback? onChanged,
}) async {
  final bankId = question.bankId;
  final results = await Future.wait(<Future<Object>>[
    repo.favoriteIds(bankId: bankId),
    repo.wrongIds(bankId: bankId),
  ]);
  if (!context.mounted) return;
  final all = questions ?? <Question>[question];
  var index = all.indexWhere((q) => q.id == question.id);
  if (index < 0) index = 0;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => QuestionDetailSheet(
      repo: repo,
      questions: all,
      initialIndex: index,
      favoriteIds: (results[0] as Set<String>).toSet(),
      wrongIds: (results[1] as Set<String>).toSet(),
      onChanged: onChanged,
    ),
  );
}

/// 题目详情内容。左右滑动切题；编辑、收藏、移出错题后就地刷新，不关面板。
class QuestionDetailSheet extends StatefulWidget {
  const QuestionDetailSheet({
    super.key,
    required this.repo,
    required this.questions,
    required this.initialIndex,
    required this.favoriteIds,
    required this.wrongIds,
    this.onChanged,
  });

  final QuizRepository repo;
  final List<Question> questions;
  final int initialIndex;
  final Set<String> favoriteIds;
  final Set<String> wrongIds;
  final VoidCallback? onChanged;

  @override
  State<QuestionDetailSheet> createState() => _QuestionDetailSheetState();
}

class _QuestionDetailSheetState extends State<QuestionDetailSheet> {
  late List<Question> _questions;
  late int _index;
  late Set<String> _favorites;
  late Set<String> _wrong;
  late final PageController _pages;

  Question get _question => _questions[_index];

  @override
  void initState() {
    super.initState();
    _questions = List<Question>.from(widget.questions);
    _index = widget.initialIndex.clamp(0, _questions.length - 1);
    _favorites = widget.favoriteIds.toSet();
    _wrong = widget.wrongIds.toSet();
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _notify() => widget.onChanged?.call();

  Future<void> _edit() async {
    final current = _question;
    final edited = await Navigator.of(context).push<Question>(
      quizRoute<Question>(
        builder: (_) => QuestionEditPage(repo: widget.repo, question: current),
      ),
    );
    if (edited == null || !mounted) return;
    setState(() => _questions[_index] = edited);
    _notify();
  }

  /// 把 AI 解析写回题库，并就地刷新详情里的解析文本。
  Future<void> _saveAnalysis(Question question, String text) async {
    final updated = await widget.repo.saveAnalysis(question, text);
    if (!mounted) return;
    setState(() => _questions[_index] = updated);
    _notify();
  }

  Future<void> _toggleFavorite() async {
    final q = _question;
    if (_favorites.contains(q.id)) {
      await widget.repo.removeFavorite(q.bankId, q.id);
      if (!mounted) return;
      setState(() => _favorites.remove(q.id));
    } else {
      await widget.repo.addFavorite(q.bankId, q.id);
      if (!mounted) return;
      setState(() => _favorites.add(q.id));
    }
    _notify();
  }

  Future<void> _removeWrong() async {
    final q = _question;
    await widget.repo.removeWrong(q.bankId, q.id);
    if (!mounted) return;
    setState(() => _wrong.remove(q.id));
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final question = _question;
    final favorite = _favorites.contains(question.id);
    final wrong = _wrong.contains(question.id);
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.86,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
            child: Row(
              children: <Widget>[
                Chip(label: Text(typeLabel(question.type))),
                const SizedBox(width: 8),
                if (question.difficulty != null)
                  Chip(label: Text(trf('难度 {n}', {'n': question.difficulty}))),
                if (question.score != null)
                  Chip(label: Text(trf('{n} 分', {'n': question.score}))),
                const Spacer(),
                IconButton(
                  key: const ValueKey('detail-favorite'),
                  icon: Icon(favorite ? Icons.star : Icons.star_border,
                      color: primary, size: 22),
                  tooltip: favorite ? tr('取消收藏') : tr('收藏'),
                  onPressed: _toggleFavorite,
                ),
                if (wrong)
                  IconButton(
                    key: const ValueKey('detail-remove-wrong'),
                    icon: Icon(Icons.check_circle_outline,
                        color: primary, size: 22),
                    tooltip: tr('移出错题'),
                    onPressed: _removeWrong,
                  ),
                IconButton(
                  key: const ValueKey('detail-edit'),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: tr('编辑题目'),
                  onPressed: _edit,
                ),
              ],
            ),
          ),
          if (_questions.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                trf('{n} / {total}', <String, Object?>{
                  'n': _index + 1,
                  'total': _questions.length,
                }),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          Expanded(
            child: PageView.builder(
              controller: _pages,
              itemCount: _questions.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) =>
                  _QuestionPage(question: _questions[i], sheet: this),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单页详情内容：题干、选项、答案、解析与标签。
class _QuestionPage extends StatelessWidget {
  const _QuestionPage({required this.question, required this.sheet});

  final Question question;
  final _QuestionDetailSheetState sheet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(question.stem, style: theme.textTheme.titleMedium),
          if (question.options.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...question.options.map(
              (o) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(child: Text(optionLabelOf(question, o))),
                    if (question.answer.contains(o.key))
                      const Icon(Icons.check, size: 16, color: Colors.green),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            question.type == QuestionType.short
                ? '${tr('参考答案')}：${answerLabelOf(question)}'
                : '${tr('正确答案')}：${answerLabelOf(question)}',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: Colors.green, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Text(tr('解析'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            question.hasAnalysis ? question.analysis! : tr('暂无解析'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: question.hasAnalysis
                  ? null
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          QuizAiExplanation(
            question: question,
            onSaveAnalysis: (text) => sheet._saveAnalysis(question, text),
          ),
          if (question.tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              children: question.tags.map((t) => Chip(label: Text(t))).toList(),
            ),
          ],
        ],
      ),
    );
  }
}
