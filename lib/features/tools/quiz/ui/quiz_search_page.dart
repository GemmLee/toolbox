import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/storage/local_store.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import '../logic/quiz_initials.dart';
import '../logic/quiz_search_scope.dart';
import 'quiz_common.dart';
import 'quiz_question_detail.dart';

/// 全局搜索的三种口径。
enum QuizSearchMode {
  /// 原有 SQL LIKE 子串包含匹配，按题库内顺序排列。
  contains,

  /// 词项精确等同匹配，按内部相关度排序（相关度不展示）。
  keywords,

  /// 汉字拼音首字母匹配：`zgdd` → 「中国的首都」。
  initials,
}

/// 全局搜索：跨题库搜索题干 / 选项 / 解析 / 标签（分页）。
class QuizSearchPage extends StatefulWidget {
  const QuizSearchPage({super.key, required this.repo});

  final QuizRepository repo;

  @override
  State<QuizSearchPage> createState() => _QuizSearchPageState();
}

class _QuizSearchPageState extends State<QuizSearchPage> {
  static const int _pageSize = 20;
  static const String _scopeKey = QuizSearchScope.searchKey;

  final TextEditingController _controller = TextEditingController();
  final Set<QuestionType> _types = <QuestionType>{};
  bool _onlyWrong = false;
  bool _onlyFavorite = false;
  final List<SearchHit> _items = <SearchHit>[];
  int _total = 0;
  bool _loading = false;
  String _query = '';
  QuizSearchMode _mode = QuizSearchMode.contains;

  /// 搜索范围：勾选的题库 id，空集合表示全部题库。
  Set<String> _bankIds = <String>{};
  List<Bank> _banks = const <Bank>[];

  @override
  void initState() {
    super.initState();
    _loadBanks();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadBanks() async {
    try {
      final banks = await widget.repo.listBanks();
      final saved = await LocalStore.readMap(_scopeKey);
      // 首次进入没有自己的选择时，沿用其它搜索入口最近一次选过的题库。
      final ids = saved == null
          ? await QuizSearchScope.lastIds()
          : QuizSearchScope.idsFrom(saved);
      if (!mounted) return;
      setState(() {
        _banks = banks;
        // 题库被删掉后，把失效的 id 从范围里剔除，避免一直搜不到东西。
        _bankIds = QuizSearchScope.validIds(ids, banks);
      });
    } catch (_) {
      // 题库读不出来时按「全部题库」搜，不影响搜索本身。
    }
  }

  Future<void> _search({bool reset = true}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (reset) {
        _items.clear();
        _query = _controller.text;
      }
    });
    final result = switch (_mode) {
      QuizSearchMode.contains => await widget.repo.search(
          query: _query,
          types: _types,
          onlyWrong: _onlyWrong,
          onlyFavorite: _onlyFavorite,
          bankIds: _bankIds,
          limit: _pageSize,
          offset: _items.length,
        ),
      QuizSearchMode.keywords => await widget.repo.searchKeywords(
          query: _query,
          types: _types,
          onlyWrong: _onlyWrong,
          onlyFavorite: _onlyFavorite,
          bankIds: _bankIds,
          limit: _pageSize,
          offset: _items.length,
        ),
      QuizSearchMode.initials => await widget.repo.searchInitials(
          query: _query,
          types: _types,
          onlyWrong: _onlyWrong,
          onlyFavorite: _onlyFavorite,
          bankIds: _bankIds,
          limit: _pageSize,
          offset: _items.length,
        ),
    };
    if (!mounted) return;
    setState(() {
      _items.addAll(result.items);
      _total = result.total;
      _loading = false;
    });
  }

  Future<void> _pickBanks() async {
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      builder: (_) => BankMultiSheet(banks: _banks, selected: _bankIds),
    );
    if (picked == null || !mounted) return;
    setState(() => _bankIds = <String>{...picked});
    await LocalStore.writeMap(_scopeKey, <String, dynamic>{
      'bankIds': _bankIds.toList(growable: false),
    });
    await QuizSearchScope.remember(_bankIds);
    _search();
  }

  String get _scopeLabel => _bankIds.isEmpty
      ? tr('全部题库')
      : trf('题库 {n}', {'n': '${_bankIds.length}'});

  String? get _modeHint => switch (_mode) {
        QuizSearchMode.keywords => tr('空格分隔多个关键词，按匹配程度排序'),
        QuizSearchMode.initials => tr('输入汉字首字母，空格分隔多个片段，例如 zgdd sh'),
        QuizSearchMode.contains => null,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initialsUnsupported =
        _mode == QuizSearchMode.initials && QuizInitials.supported == false;
    return Scaffold(
      appBar: AppBar(title: Text(tr('全局搜索'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              key: const ValueKey('search-field'),
              controller: _controller,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: tr('搜索题干、选项、解析、标签'),
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _controller.clear();
                    _search();
                  },
                ),
              ),
              onSubmitted: (_) => _search(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<QuizSearchMode>(
                key: const ValueKey('search-mode'),
                showSelectedIcon: false,
                segments: <ButtonSegment<QuizSearchMode>>[
                  ButtonSegment<QuizSearchMode>(
                    value: QuizSearchMode.contains,
                    label: Text(tr('包含')),
                  ),
                  ButtonSegment<QuizSearchMode>(
                    value: QuizSearchMode.keywords,
                    label: Text(tr('关键词')),
                  ),
                  ButtonSegment<QuizSearchMode>(
                    value: QuizSearchMode.initials,
                    label: Text(tr('首字母')),
                  ),
                ],
                selected: <QuizSearchMode>{_mode},
                onSelectionChanged: (selected) {
                  setState(() => _mode = selected.first);
                  _search();
                },
              ),
            ),
          ),
          if (_modeHint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: SmallHint(text: _modeHint!, maxLines: 1),
            ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilterChip(
                    key: const ValueKey('filter-banks'),
                    avatar: const Icon(Icons.library_books_outlined, size: 16),
                    label: Text(_scopeLabel),
                    selected: _bankIds.isNotEmpty,
                    onSelected: (_) => _pickBanks(),
                  ),
                ),
                ...allQuestionTypes.map(
                  (type) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: FilterChip(
                      key: ValueKey<String>('filter-${type.key}'),
                      label: Text(typeLabel(type)),
                      selected: _types.contains(type),
                      onSelected: (v) {
                        setState(() {
                          if (v) {
                            _types.add(type);
                          } else {
                            _types.remove(type);
                          }
                        });
                        _search();
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilterChip(
                    key: const ValueKey('filter-wrong'),
                    label: Text(tr('仅错题')),
                    selected: _onlyWrong,
                    onSelected: (v) {
                      setState(() => _onlyWrong = v);
                      _search();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilterChip(
                    key: const ValueKey('filter-favorite'),
                    label: Text(tr('仅收藏')),
                    selected: _onlyFavorite,
                    onSelected: (v) {
                      setState(() => _onlyFavorite = v);
                      _search();
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                trf('共 {n} 条结果', {'n': _total}),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          Expanded(
            child: initialsUnsupported
                ? QuizEmpty(tr('当前系统不支持拼音首字母搜索'))
                : _items.isEmpty
                    ? QuizEmpty(_loading ? tr('搜索中') : tr('输入关键词开始搜索'))
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount:
                            _items.length + (_items.length < _total ? 1 : 0),
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          if (index >= _items.length) {
                            return TextButton(
                              onPressed: () => _search(reset: false),
                              child: Text(tr('加载更多')),
                            );
                          }
                          final hit = _items[index];
                          return ListTile(
                            title: Text(hit.question.stem,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                                '${hit.bankName} · ${typeLabel(hit.question.type)}'),
                            onTap: () => showQuestionDetail(
                              context,
                              widget.repo,
                              hit.question,
                              questions: _items
                                  .map((h) => h.question)
                                  .toList(growable: false),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
