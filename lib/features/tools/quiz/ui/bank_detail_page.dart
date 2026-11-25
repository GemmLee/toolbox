import 'package:flutter/material.dart';

import '../../../../core/app_theme.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import 'quiz_answer_page.dart';
import 'quiz_common.dart';
import 'quiz_notes_page.dart';
import 'quiz_practice_page.dart';
import 'quiz_question_detail.dart';
import 'quiz_stats_ring.dart';
import 'quiz_study_page.dart';

/// 题库详情：卡片式首页（题库预览 / 错题 / 收藏 / 背题 / 笔记 / 统计），
/// 练习与考试「记录」原样保留在卡片下方；所有数据都只属于这一个题库。
class BankDetailPage extends StatefulWidget {
  const BankDetailPage({super.key, required this.repo, required this.bank});

  final QuizRepository repo;
  final Bank bank;

  @override
  State<BankDetailPage> createState() => _BankDetailPageState();
}

class _BankDetailPageState extends State<BankDetailPage> {
  late Bank _bank = widget.bank;
  late Future<_Overview> _future = _Overview.load(_repo, _bank.id);

  QuizRepository get _repo => widget.repo;

  Future<void> _refresh() async {
    for (final bank in await _repo.listBanks()) {
      if (bank.id == _bank.id) {
        _bank = bank;
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _future = _Overview.load(_repo, _bank.id);
    });
    await _future;
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(context)
        .push<void>(quizRoute<void>(builder: (_) => page));
    if (mounted) await _refresh();
  }

  Future<void> _rename() async {
    final input = TextEditingController(text: _bank.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('重命名题库')),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('题库名称'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(input.text),
            child: Text(tr('保存')),
          ),
        ],
      ),
    );
    input.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    await _repo.renameBank(_bank.id, trimmed);
    await _refresh();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除题库')),
        content: Text(tr('删除后该题库的错题、收藏与考试记录都会一并删除')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _repo.deleteBank(_bank.id);
    if (mounted) Navigator.of(context).pop();
  }

  void _openConfig({bool exam = false, QuizMode? mode}) {
    Navigator.of(context).push(quizRoute<void>(
        builder: (_) => QuizConfigPage(
              repo: _repo,
              bankId: _bank.id,
              exam: exam,
              initialMode: mode,
            )));
  }

  Future<void> _openSession(QuizSession session) async {
    await Navigator.of(context).push(quizRoute<void>(
        builder: (_) => QuizAnswerPage(repo: _repo, sessionId: session.id)));
    if (mounted) await _refresh();
  }

  /// 误点题库产生的空记录可以长按删除（同时清掉会话中的作答）。
  Future<void> _confirmDeleteSession(QuizSession session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除记录')),
        content: Text(tr('确定删除这条记录吗？删除后不可恢复')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.deleteSession(session.id);
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_bank.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: tr('更多'),
            onSelected: (value) async {
              if (value == 'rename') await _rename();
              if (value == 'delete') await _delete();
            },
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'rename',
                child: Text(tr('重命名题库')),
              ),
              PopupMenuItem<String>(
                value: 'delete',
                child: Text(tr('删除题库')),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<_Overview>(
          future: _future,
          builder: (context, snapshot) {
            final data = snapshot.data;
            if (data == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: <Widget>[
                _CardGrid(
                  data: data,
                  onPreview: () => _push(_QuestionPage(
                      repo: _repo, bank: _bank, onChanged: _refresh)),
                  onWrong: () => _push(_RecordPage(
                      repo: _repo,
                      bankId: _bank.id,
                      wrong: true,
                      onChanged: _refresh)),
                  onFavorite: () => _push(_RecordPage(
                      repo: _repo,
                      bankId: _bank.id,
                      wrong: false,
                      onChanged: _refresh)),
                  onStudy: () =>
                      _push(QuizStudyPage(repo: _repo, bankId: _bank.id)),
                  onNotes: () =>
                      _push(QuizNotesPage(repo: _repo, bankId: _bank.id)),
                  onStats: () =>
                      _push(QuizStatsDetailPage(repo: _repo, bankId: _bank.id)),
                ),
                const SizedBox(height: 18),
                _SessionSection(
                  sessions: data.sessions,
                  onOpen: _openSession,
                  onDelete: _confirmDeleteSession,
                ),
              ],
            );
          },
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('bank-practice'),
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: Text(tr('练习')),
                  onPressed: () => _openConfig(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('bank-exam'),
                  icon: const Icon(Icons.timer_outlined),
                  label: Text(tr('模拟考试')),
                  onPressed: () => _openConfig(exam: true),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Overview {
  const _Overview({
    required this.stats,
    required this.noteCount,
    required this.sessions,
  });

  final QuizStats stats;
  final int noteCount;
  final List<QuizSession> sessions;

  static Future<_Overview> load(QuizRepository repo, String bankId) async {
    final stats = await repo.stats(bankId: bankId);
    final noteCount = await repo.countNotes(bankId);
    final sessions = await repo.sessionsOfBank(bankId);
    return _Overview(
      stats: stats,
      noteCount: noteCount,
      sessions: sessions,
    );
  }
}

// —— 卡片首页 ——

/// 三列网格，小卡边长与「工具总览」一致：统计卡 2×2 在左，
/// 右侧一列竖排「题库预览 / 错题」，「收藏 / 背题 / 笔记」再另起一行。
class _CardGrid extends StatelessWidget {
  const _CardGrid({
    required this.data,
    required this.onPreview,
    required this.onWrong,
    required this.onFavorite,
    required this.onStudy,
    required this.onNotes,
    required this.onStats,
  });

  final _Overview data;
  final VoidCallback onPreview;
  final VoidCallback onWrong;
  final VoidCallback onFavorite;
  final VoidCallback onStudy;
  final VoidCallback onNotes;
  final VoidCallback onStats;

  @override
  Widget build(BuildContext context) {
    // 四种功能色是语义编码色，保留色相；深色下整体提亮保证图标清晰。
    final dark = Theme.of(context).brightness == Brightness.dark;
    final previewAccent =
        dark ? const Color(0xFF8FB4FF) : const Color(0xFF3E7BFA);
    final wrongAccent =
        dark ? const Color(0xFFFF8E93) : const Color(0xFFE5484D);
    final favoriteAccent =
        dark ? const Color(0xFFFFC46B) : const Color(0xFFF0A22E);
    final studyAccent =
        dark ? const Color(0xFF7FD8C6) : const Color(0xFF159B86);
    final notesAccent =
        dark ? const Color(0xFFB9A4FF) : const Color(0xFF7A5AF8);
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 10.0;
        // 与工具总览同一套三列公式；宽窗口下限制小卡最大约 120px，
        // 不把卡片拉成巨块，同时和工具总览卡片的观感保持一致。
        const maxGridWidth = 380.0;
        final gridWidth = constraints.maxWidth > maxGridWidth
            ? maxGridWidth
            : constraints.maxWidth;
        final cell = (gridWidth - gap * 2) / 3;
        final big = cell * 2 + gap;
        final stats = data.stats;
        return Center(
          child: SizedBox(
            width: gridWidth,
            child: Column(
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _StatsCard(size: big, stats: stats, onTap: onStats),
                    const SizedBox(width: gap),
                    Column(
                      children: <Widget>[
                        _EntryCard(
                          cardKey: 'bank-card-preview',
                          size: cell,
                          icon: Icons.library_books_outlined,
                          accent: previewAccent,
                          title: tr('题库预览'),
                          subtitle: trf('共 {n} 题', {'n': stats.questionCount}),
                          onTap: onPreview,
                        ),
                        const SizedBox(height: gap),
                        _EntryCard(
                          cardKey: 'bank-card-wrong',
                          size: cell,
                          icon: Icons.error_outline,
                          accent: wrongAccent,
                          title: tr('错题'),
                          subtitle: trf('{n} 道错题', {'n': stats.wrongCount}),
                          onTap: onWrong,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: gap),
                Row(
                  children: <Widget>[
                    _EntryCard(
                      cardKey: 'bank-card-favorite',
                      size: cell,
                      icon: Icons.star_outline,
                      accent: favoriteAccent,
                      title: tr('收藏'),
                      subtitle: trf('收藏 {n} 题', {'n': stats.favoriteCount}),
                      onTap: onFavorite,
                    ),
                    const SizedBox(width: gap),
                    _EntryCard(
                      cardKey: 'bank-card-study',
                      size: cell,
                      icon: Icons.menu_book_outlined,
                      accent: studyAccent,
                      title: tr('背题模式'),
                      subtitle: trf('可背 {n} 题', {'n': stats.questionCount}),
                      onTap: onStudy,
                    ),
                    const SizedBox(width: gap),
                    _EntryCard(
                      cardKey: 'bank-card-notes',
                      size: cell,
                      icon: Icons.sticky_note_2_outlined,
                      accent: notesAccent,
                      title: tr('笔记'),
                      subtitle: trf('{n} 条笔记', {'n': data.noteCount}),
                      onTap: onNotes,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 与「工具总览」卡片同款：正方形、图标不加框、标题 + 一行常驻小字。
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.cardKey,
    required this.size,
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String cardKey;
  final double size;
  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: theme.cardTheme.color,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          side: BorderSide(color: AppTokens.hairline(scheme)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey<String>(cardKey),
          onTap: onTap,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.topLeft,
                        radius: 1.15,
                        colors: <Color>[
                          accent.withOpacity(0.10),
                          accent.withOpacity(0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(11, 12, 11, 11),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(icon, color: accent, size: 26),
                    const Spacer(),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 12.8,
                        height: 1.25,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant.withOpacity(0.9),
                        fontSize: 10.5,
                        height: 1.25,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 统计大卡：2×2，圆环中心是题目总数，点进去看刷题进度等详细数据。
class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.size,
    required this.stats,
    required this.onTap,
  });

  final double size;
  final QuizStats stats;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const accent = Color(0xFF17A673);
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: theme.cardTheme.color,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          side: BorderSide(color: AppTokens.hairline(scheme)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('bank-card-stats'),
          onTap: onTap,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.topRight,
                        radius: 1.1,
                        colors: <Color>[
                          accent.withOpacity(0.09),
                          accent.withOpacity(0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Icon(Icons.donut_large_outlined,
                            color: accent, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tr('统计'),
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Icon(Icons.chevron_right,
                            size: 18, color: scheme.onSurfaceVariant),
                      ],
                    ),
                    Expanded(
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: BankStatsRing(
                            stats: stats,
                            size: size * 0.76,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// —— 卡片点进去后的全屏页 ——

class _QuestionPage extends StatelessWidget {
  const _QuestionPage({
    required this.repo,
    required this.bank,
    required this.onChanged,
  });

  final QuizRepository repo;
  final Bank bank;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('题库预览'))),
        body: _QuestionTab(
          key: ValueKey<String>('tab-questions-${bank.id}'),
          repo: repo,
          bank: bank,
          onChanged: onChanged,
        ),
      );
}

class _RecordPage extends StatelessWidget {
  const _RecordPage({
    required this.repo,
    required this.bankId,
    required this.wrong,
    required this.onChanged,
  });

  final QuizRepository repo;
  final String bankId;
  final bool wrong;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(wrong ? tr('错题') : tr('收藏'))),
        body: _RecordTab(
          key: ValueKey<String>('tab-${wrong ? 'wrong' : 'fav'}-$bankId'),
          repo: repo,
          bankId: bankId,
          wrong: wrong,
          onChanged: onChanged,
        ),
      );
}

// —— 记录（保留原内容，放在卡片下方） ——

class _SessionSection extends StatelessWidget {
  const _SessionSection({
    required this.sessions,
    required this.onOpen,
    required this.onDelete,
  });

  final List<QuizSession> sessions;
  final Future<void> Function(QuizSession) onOpen;
  final Future<void> Function(QuizSession) onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              tr('记录'),
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 6),
            Text(
              '${sessions.length}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
        if (sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SmallHint(text: tr('这个题库还没有练习或考试记录')),
          )
        else ...<Widget>[
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (var i = 0; i < sessions.length; i++) ...<Widget>[
                  if (i > 0) const Divider(height: 1),
                  _sessionTile(context, sessions[i]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _sessionTile(BuildContext context, QuizSession s) {
    final theme = Theme.of(context);
    final finished = s.status != SessionStatus.active;
    final mode = switch (s.mode) {
      QuizMode.exam => tr('模拟考试'),
      QuizMode.wrong => tr('错题练习'),
      QuizMode.favorite => tr('收藏练习'),
      QuizMode.random => tr('随机练习'),
      QuizMode.all => tr('顺序练习'),
    };
    final score = s.scoreEnabled
        ? '${tr('得分')} ${_num(s.totalScore)}/${_num(s.maxScore)}'
        : '';
    return ListTile(
      leading: Icon(
        finished ? Icons.task_alt_outlined : Icons.play_circle_outline,
        color:
            finished ? theme.colorScheme.primary : theme.colorScheme.tertiary,
      ),
      title: Text(mode),
      subtitle: Text(
        <String>[
          dateLabelOf(s.startedAt),
          if (finished && score.isNotEmpty) score,
          if (!finished) tr('未完成'),
        ].join(' · '),
      ),
      trailing: const Icon(Icons.chevron_right),
      onLongPress: () => onDelete(s),
      onTap: () => onOpen(s),
    );
  }

  static String _num(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}

// —— 题目 ——

class _QuestionTab extends StatefulWidget {
  const _QuestionTab({
    super.key,
    required this.repo,
    required this.bank,
    required this.onChanged,
  });

  final QuizRepository repo;
  final Bank bank;
  final Future<void> Function() onChanged;

  @override
  State<_QuestionTab> createState() => _QuestionTabState();
}

class _QuestionTabState extends State<_QuestionTab> {
  static const int _pageSize = 30;

  QuestionType? _type;
  final List<Question> _items = <Question>[];
  bool _hasMore = true;
  bool _loading = false;
  late Set<String> _favorites = <String>{};
  late Set<String> _wrong = <String>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _items.clear();
      _hasMore = true;
    });
    _favorites = await widget.repo.favoriteIds(bankId: widget.bank.id);
    _wrong = await widget.repo.wrongIds(bankId: widget.bank.id);
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    final page = await widget.repo.questionsOfBank(
      widget.bank.id,
      type: _type,
      limit: _pageSize,
      offset: _items.length,
    );
    if (!mounted) return;
    setState(() {
      _items.addAll(page);
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  Future<void> _openDetail(Question question) async {
    await showQuestionDetail(context, widget.repo, question,
        questions: List<Question>.from(_items), onChanged: () async {
      _favorites = await widget.repo.favoriteIds(bankId: widget.bank.id);
      _wrong = await widget.repo.wrongIds(bankId: widget.bank.id);
      if (mounted) setState(() {});
      await widget.onChanged();
    });
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _filterChip(context, null, tr('全部')),
              ...allQuestionTypes
                  .map((t) => _filterChip(context, t, typeLabel(t))),
            ],
          ),
        ),
        Expanded(
          child: _items.isEmpty && !_loading
              ? QuizEmpty(tr('暂无题目'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _items.length + (_hasMore ? 1 : 0),
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index >= _items.length) {
                      return TextButton(
                        onPressed: _loadMore,
                        child: Text(tr('加载更多')),
                      );
                    }
                    final q = _items[index];
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor:
                            theme.colorScheme.primary.withOpacity(0.12),
                        child: Text('${index + 1}',
                            style: theme.textTheme.bodySmall),
                      ),
                      title: Text(
                        q.stem,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Row(
                        children: [
                          Text(typeLabel(q.type)),
                          if (_wrong.contains(q.id)) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.error_outline,
                                size: 14, color: Colors.red),
                          ],
                          if (_favorites.contains(q.id)) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.star,
                                size: 14, color: Colors.amber),
                          ],
                        ],
                      ),
                      onTap: () => _openDetail(q),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _filterChip(BuildContext context, QuestionType? type, String label) {
    final selected = _type == type;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) {
          setState(() => _type = type);
          _reload();
        },
      ),
    );
  }
}

// —— 错题 / 收藏 ——

class _RecordTab extends StatefulWidget {
  const _RecordTab({
    super.key,
    required this.repo,
    required this.bankId,
    required this.wrong,
    required this.onChanged,
  });

  final QuizRepository repo;
  final String bankId;

  /// true = 错题，false = 收藏。
  final bool wrong;
  final Future<void> Function() onChanged;

  @override
  State<_RecordTab> createState() => _RecordTabState();
}

class _RecordTabState extends State<_RecordTab> {
  late Future<List<Question>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = widget.wrong
        ? widget.repo.wrongQuestions(bankId: widget.bankId)
        : widget.repo.favoriteQuestions(bankId: widget.bankId);
  }

  Future<void> _refresh() async {
    setState(_load);
    await _future;
    await widget.onChanged();
  }

  Future<void> _remove(Question q) async {
    if (widget.wrong) {
      await widget.repo.removeWrong(widget.bankId, q.id);
    } else {
      await widget.repo.removeFavorite(widget.bankId, q.id);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Question>>(
      future: _future,
      builder: (context, snapshot) {
        final items = snapshot.data;
        if (items == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (items.isEmpty) {
          return QuizEmpty(widget.wrong ? tr('这个题库还没有错题') : tr('这个题库还没有收藏'));
        }
        return Column(
          children: [
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final q = items[index];
                  return ListTile(
                    title: Text(q.stem,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(typeLabel(q.type)),
                    trailing: IconButton(
                      key: ValueKey<String>('record-action-$index'),
                      icon: Icon(widget.wrong
                          ? Icons.check_circle_outline
                          : Icons.star),
                      tooltip: widget.wrong ? tr('移出错题') : tr('取消收藏'),
                      onPressed: () => _remove(q),
                    ),
                    onTap: () async {
                      await showQuestionDetail(context, widget.repo, q,
                          questions: items, onChanged: _refresh);
                      await _refresh();
                    },
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('start-drill'),
                    icon: const Icon(Icons.play_arrow_outlined),
                    label: Text(widget.wrong ? tr('开始错题练习') : tr('开始收藏练习')),
                    onPressed: () {
                      Navigator.of(context).push(quizRoute<void>(
                          builder: (_) => QuizConfigPage(
                                repo: widget.repo,
                                bankId: widget.bankId,
                                initialMode: widget.wrong
                                    ? QuizMode.wrong
                                    : QuizMode.favorite,
                              )));
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
