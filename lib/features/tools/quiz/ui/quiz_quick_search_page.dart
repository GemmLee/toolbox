import 'package:flutter/material.dart';

import '../../../../core/platform/overlay_theme.dart';
import '../../../../core/platform/quick_search.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/storage/local_store.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/mini_segmented.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import '../logic/quiz_photo_match.dart';
import '../logic/quiz_search_scope.dart';
import 'quiz_common.dart';
import 'quiz_quick_search_overlay.dart';

/// 便捷搜题：开启系统悬浮窗，在任意应用里输拼音首字母就能看到题库里的题。
///
/// 系统悬浮窗不可用（未授权 / ROM 拦截）时，降级为页面内的应用内浮窗。
class QuizQuickSearchPage extends StatefulWidget {
  const QuizQuickSearchPage({
    super.key,
    this.repo,
    this.host = const QuickSearchHost(),
    this.indexWriter,
    this.matcher,
  });

  final QuizRepository? repo;
  final QuickSearchHost host;

  /// 测试注入：把题库写成索引文件并返回路径。
  final Future<String> Function(QuizRepository repo)? indexWriter;

  /// 测试注入：应用内浮窗的匹配函数。
  final Future<PhotoMatch?> Function(QuizRepository repo, String text)? matcher;

  @override
  State<QuizQuickSearchPage> createState() => _QuizQuickSearchPageState();
}

class _QuizQuickSearchPageState extends State<QuizQuickSearchPage>
    with WidgetsBindingObserver {
  /// 搜索范围（题库）持久化的 key。
  static const String _scopeKey = 'quiz_quick_scope';

  QuizRepository? _repo;
  List<Bank> _banks = const <Bank>[];

  /// 搜索范围：勾选的题库 id，空集合表示全部题库。
  Set<String> _bankIds = <String>{};
  String? _indexPath;
  int _maxResults = 3;

  /// 悬浮窗背景色（黑 / 白 / 透明），偏好以原生侧为准。
  OverlayTheme _theme = OverlayTheme.dark;

  /// 「每次显示数」输入框：与 [NumberStepField] 共享，切换时同步文本。
  final TextEditingController _maxInput = TextEditingController(text: '3');
  bool _busy = false;
  bool _showing = false;
  bool _fallback = false;
  bool _needPermission = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadScope();
  }

  /// 题库列表 + 上次选的范围：库被删了就自动从范围里剔除。
  Future<void> _loadScope() async {
    try {
      final repo = widget.repo ?? await QuizServices.repo();
      final banks = await repo.listBanks();
      final saved = await LocalStore.readMap(_scopeKey);
      // 本入口没存过时，沿用其它搜索入口最近一次选择的题库。
      final scope = saved ?? await LocalStore.readMap(QuizSearchScope.lastKey);
      final restored = QuizSearchScope.idsFrom(scope);
      final savedMax = int.tryParse(saved?['maxResults']?.toString() ?? '');
      if (!mounted) return;
      setState(() {
        _banks = banks;
        _bankIds = QuizSearchScope.validIds(restored, banks);
        if (savedMax != null) _maxResults = savedMax.clamp(1, 9);
        _maxInput.text = '$_maxResults';
        _theme = OverlayTheme.fromKey(saved?['theme']?.toString());
      });
    } catch (_) {
      // 题库读不出来时保持「全部题库」，不影响开启悬浮窗。
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _maxInput.dispose();
    super.dispose();
  }

  Future<void> _persistScope() =>
      LocalStore.writeMap(_scopeKey, <String, dynamic>{
        'bankIds': _bankIds.toList(growable: false),
        'maxResults': _maxResults,
        'theme': _theme.key,
      });

  /// 换背景色：持久化并实时下发给原生（开着窗时原生会刷新画笔）。
  Future<void> _setTheme(OverlayTheme theme) async {
    if (theme == _theme) return;
    setState(() => _theme = theme);
    await _persistScope();
    await widget.host.setTheme(theme.key);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统授权页回到 App：重新检查权限，避免用户以为已经生效。
    if (state == AppLifecycleState.resumed && _needPermission) {
      _refreshPermission();
    }
  }

  Future<void> _refreshPermission() async {
    final granted = await widget.host.canDraw();
    if (!mounted) return;
    setState(() => _needPermission = !granted);
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = widget.repo ?? await QuizServices.repo();
      _repo = repo;
      final granted = await widget.host.canDraw();
      if (!granted) {
        await widget.host.request();
        if (!mounted) return;
        setState(() {
          _busy = false;
          _needPermission = true;
        });
        return;
      }
      final writer = widget.indexWriter ?? _writeIndex;
      final path = await writer(repo);
      final ok = await widget.host.show(path, _scope, _maxResults);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _showing = ok;
        _fallback = !ok;
        _needPermission = false;
        _indexPath = ok ? path : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _fallback = true;
        _error = trf('悬浮窗启动失败：{e}', {'e': '$e'});
      });
    }
  }

  /// 按当前题库范围重写索引：全局索引有 4000 题上限，靠后的题库可能整本都不在里面，
  /// 所以选了什么题库就只把那些题库写进去。
  Future<String> _writeIndex(QuizRepository repo) async {
    final items = await repo.quickSearchIndex(bankIds: _bankIds);
    return writeQuickSearchIndex(items, fileName: kQuickSearchScopeIndexFile);
  }

  Future<void> _stop() async {
    await widget.host.hide();
    if (!mounted) return;
    setState(() {
      _showing = false;
      _indexPath = null;
    });
  }

  /// 换题库范围：立刻落盘；窗口已经开着时把新范围下发给它，不用关掉重开。
  Future<void> _selectBanks(Set<String> ids) async {
    if (_sameScope(ids, _bankIds)) return;
    setState(() => _bankIds = <String>{...ids});
    await _persistScope();
    await QuizSearchScope.remember(_bankIds);
    if (_showing && _indexPath != null) {
      // 换范围要连索引一起换：文件重写后再下发，Service 会重新读一遍。
      final repo = _repo;
      if (repo != null) {
        final writer = widget.indexWriter ?? _writeIndex;
        _indexPath = await writer(repo);
      }
      await widget.host.show(_indexPath!, _scope, _maxResults);
    }
  }

  /// 下发给悬浮窗的范围：空集合统一成 null，原生侧只认「null = 全部」。
  Set<String>? get _scope => _bankIds.isEmpty ? null : _bankIds;

  static bool _sameScope(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  /// 每次显示数：落盘后立即下发给已开启的悬浮窗。
  Future<void> _setMaxResults(int value) async {
    final next = value.clamp(1, 9);
    if (next == _maxResults) return;
    setState(() => _maxResults = next);
    await _persistScope();
    if (_showing && _indexPath != null) {
      await widget.host.show(_indexPath!, _scope, next);
    }
  }

  Future<void> _pickBanks() async {
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      builder: (_) => BankMultiSheet(banks: _banks, selected: _bankIds),
    );
    if (picked == null || !mounted) return;
    await _selectBanks(picked);
  }

  /// 当前搜索范围的名字（没选就是全部题库）。
  String get _scopeName {
    if (_bankIds.isEmpty) return tr('全部题库');
    if (_bankIds.length == 1) {
      for (final bank in _banks) {
        if (bank.id == _bankIds.first) return bank.name;
      }
      return tr('全部题库');
    }
    return trf('已选 {n} 个题库', {'n': '${_bankIds.length}'});
  }

  int get _scopeCount {
    if (_bankIds.isEmpty) {
      return _banks.fold<int>(0, (sum, b) => sum + b.questionCount);
    }
    return _banks
        .where((b) => _bankIds.contains(b.id))
        .fold<int>(0, (sum, b) => sum + b.questionCount);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('便捷搜题'))),
      body: Stack(
        children: <Widget>[
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: <Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        tr('在其他应用里也能搜题'),
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 14),
                      QuizSteps(
                        steps: <String>[
                          tr('开启悬浮窗'),
                          tr('切到要搜的题'),
                          tr('输首字母看答案'),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: FilledButton(
                              key: const ValueKey('quick-search-toggle'),
                              onPressed:
                                  _busy ? null : (_showing ? _stop : _start),
                              child: Text(
                                _showing ? tr('关闭悬浮窗') : tr('开启'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_busy) ...<Widget>[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                      ],
                    ],
                  ),
                ),
              ),
              if (_banks.length > 1) ...<Widget>[
                const SizedBox(height: 4),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const ValueKey('quick-search-bank'),
                    onTap: _busy ? null : _pickBanks,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  tr('搜索范围'),
                                  style: theme.textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: <Widget>[
                                    Flexible(
                                      child: Text(
                                        _scopeName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    SmallHint(
                                      text: trf('共 {n} 题', {'n': _scopeCount}),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.expand_more,
                            size: 20,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          tr('每次显示数'),
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      NumberStepField(
                        controller: _maxInput,
                        fieldKey: const ValueKey('quick-search-max'),
                        stepKeyPrefix: 'quick-search-max',
                        min: 1,
                        max: 9,
                        width: 104,
                        onChanged: (value) {
                          final n = int.tryParse(value);
                          if (n != null) _setMaxResults(n);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          tr('悬浮窗背景'),
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      MiniSegmented<OverlayTheme>(
                        selected: _theme,
                        onChanged: _setTheme,
                        options: <MiniSegmentedOption<OverlayTheme>>[
                          for (final t in OverlayTheme.values)
                            MiniSegmentedOption<OverlayTheme>(
                              value: t,
                              label: tr(t.labelKey),
                              key: ValueKey('quick-theme-${t.key}'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (_needPermission)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                  child: SmallHint(
                    text: tr('请在系统设置里打开「显示在其他应用上层」，然后回到这里再点开启'),
                    color: scheme.error,
                  ),
                ),
              if (_showing)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                  child: SmallHint(
                    text: tr('悬浮窗已开启：切到别的应用，输首字母搜题'),
                  ),
                ),
              if (_fallback)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
                  child: SmallHint(
                    text: tr('系统悬浮窗被拦截，已切换为应用内浮窗'),
                    color: scheme.error,
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                  child: SmallHint(text: _error!, color: scheme.error),
                ),
              const SizedBox(height: 8),
              const SmallHint(
                text: '悬浮窗不会读取其他应用的内容，只用你输入的文字在本机题库里匹配',
              ),
            ],
          ),
          if (_fallback)
            Positioned.fill(
              child: InAppQuickSearch(
                repo: _repo!,
                bankIds: _bankIds,
                matcher: widget.matcher,
                onClose: () => setState(() => _fallback = false),
              ),
            ),
        ],
      ),
    );
  }
}
