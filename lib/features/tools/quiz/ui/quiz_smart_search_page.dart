import 'package:flutter/material.dart';

import '../../../../core/platform/overlay_theme.dart';
import '../../../../core/platform/quick_search.dart';
import '../../../../core/platform/smart_search.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/storage/local_store.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/mini_segmented.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import '../logic/quiz_search_scope.dart';
import 'quiz_common.dart';

/// 智能搜题：一个框选窗 + 一个结果窗，框好区域后自动跟着题目变答案。
///
/// 需要两样系统授权：悬浮窗（两个窗都靠它显示）与无障碍服务（只靠它截屏取字）。
/// 两样都齐了才会真正启动；缺哪个就地提示并跳到对应设置页。
class QuizSmartSearchPage extends StatefulWidget {
  const QuizSmartSearchPage({
    super.key,
    this.repo,
    this.host = const SmartSearchHost(),
    this.indexWriter,
  });

  final QuizRepository? repo;
  final SmartSearchHost host;

  /// 测试注入：把题库写成索引文件并返回路径。
  final Future<String> Function(QuizRepository repo)? indexWriter;

  @override
  State<QuizSmartSearchPage> createState() => _QuizSmartSearchPageState();
}

class _QuizSmartSearchPageState extends State<QuizSmartSearchPage>
    with WidgetsBindingObserver {
  /// 每次显示数持久化的 key。
  static const String _scopeKey = 'quiz_smart_scope';

  bool _busy = false;
  bool _showing = false;
  bool _overlayGranted = false;
  bool _accessibilityGranted = false;
  bool _needOverlay = false;
  bool _needAccessibility = false;
  bool _blocked = false;
  String? _error;
  int _maxResults = 3;

  QuizRepository? _repo;
  List<Bank> _banks = const <Bank>[];

  /// 搜索范围：勾选的题库 id，空集合表示全部题库。
  Set<String> _bankIds = <String>{};
  String? _indexPath;

  /// 悬浮窗背景色（黑 / 白 / 透明），偏好以原生侧为准。
  OverlayTheme _theme = OverlayTheme.dark;

  /// 「每次显示数」输入框：与 [NumberStepField] 共享。
  final TextEditingController _maxInput = TextEditingController(text: '3');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
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
      final value = int.tryParse(saved?['maxResults']?.toString() ?? '');
      if (!mounted) return;
      setState(() {
        _banks = banks;
        _bankIds = QuizSearchScope.validIds(restored, banks);
        if (value != null) _maxResults = value.clamp(1, 9);
        _maxInput.text = '$_maxResults';
        _theme = OverlayTheme.fromKey(saved?['theme']?.toString());
      });
    } catch (_) {
      // 题库读不出来时保持「全部题库」，不影响开启悬浮窗。
    }
  }

  Future<void> _persistScope() =>
      LocalStore.writeMap(_scopeKey, <String, dynamic>{
        'bankIds': _bankIds.toList(growable: false),
        'maxResults': _maxResults,
        'theme': _theme.key,
      });

  /// 换背景色：持久化并实时下发给原生。
  Future<void> _setTheme(OverlayTheme next) async {
    if (next == _theme) return;
    setState(() => _theme = next);
    await _persistScope();
    await widget.host.setTheme(next.key);
  }

  /// 每次显示数：落盘后立即下发给已开启的悬浮窗。
  Future<void> _setMaxResults(int value) async {
    final next = value.clamp(1, 9);
    if (next == _maxResults) return;
    setState(() => _maxResults = next);
    await _persistScope();
    if (_showing && _indexPath != null) {
      await widget.host.show(_indexPath!, next);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _maxInput.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统授权页回到 App：重新核对，避免用户以为已经生效。
    if (state == AppLifecycleState.resumed) _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    final overlay = await widget.host.canDraw();
    final accessibility = await widget.host.accessibility();
    if (!mounted) return;
    setState(() {
      _overlayGranted = overlay;
      _accessibilityGranted = accessibility;
      if (overlay) _needOverlay = false;
      if (accessibility) _needAccessibility = false;
    });
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _blocked = false;
    });
    try {
      final overlay = await widget.host.canDraw();
      if (!overlay) {
        await widget.host.requestOverlay();
        if (!mounted) return;
        setState(() {
          _busy = false;
          _needOverlay = true;
          _overlayGranted = false;
        });
        return;
      }
      final accessibility = await widget.host.accessibility();
      if (!accessibility) {
        await widget.host.openSettings();
        if (!mounted) return;
        setState(() {
          _busy = false;
          _needAccessibility = true;
          _accessibilityGranted = false;
        });
        return;
      }
      final repo = widget.repo ?? await QuizServices.repo();
      _repo = repo;
      final writer = widget.indexWriter ?? _writeIndex;
      final path = await writer(repo);
      final ok = await widget.host.show(path, _maxResults);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _showing = ok;
        _blocked = !ok;
        _overlayGranted = true;
        _accessibilityGranted = true;
        _indexPath = ok ? path : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = trf('悬浮窗启动失败：{e}', {'e': '$e'});
      });
    }
  }

  /// 按当前题库范围写索引：原生只读这里产出的文件，范围靠内容过滤即可，
  /// 不必给 MethodChannel 增加参数。
  Future<String> _writeIndex(QuizRepository repo) async {
    final items = await repo.quickSearchIndex(bankIds: _bankIds);
    return writeQuickSearchIndex(items);
  }

  Future<void> _stop() async {
    await widget.host.hide();
    if (!mounted) return;
    setState(() {
      _showing = false;
      _indexPath = null;
    });
  }

  static bool _sameScope(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  /// 换题库范围：立刻落盘；窗口已经开着时重写索引再下发给它，不用关掉重开。
  Future<void> _selectBanks(Set<String> ids) async {
    if (_sameScope(ids, _bankIds)) return;
    setState(() => _bankIds = <String>{...ids});
    await _persistScope();
    await QuizSearchScope.remember(_bankIds);
    if (_showing && _indexPath != null) {
      final repo = _repo;
      if (repo != null) {
        final writer = widget.indexWriter ?? _writeIndex;
        _indexPath = await writer(repo);
      }
      await widget.host.show(_indexPath!, _maxResults);
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
      appBar: AppBar(title: Text(tr('智能搜题'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    tr('框选题干和选项，自动出答案'),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 14),
                  QuizSteps(
                    steps: <String>[
                      tr('开启悬浮窗'),
                      tr('框选题干选项'),
                      tr('切回看答案'),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _PermRow(
                    key: const ValueKey('smart-perm-overlay'),
                    icon: Icons.layers_outlined,
                    label: tr('显示在其他应用上层'),
                    granted: _overlayGranted,
                    onOpen: () async {
                      await widget.host.requestOverlay();
                      if (mounted) setState(() => _needOverlay = true);
                    },
                  ),
                  const SizedBox(height: 8),
                  _PermRow(
                    key: const ValueKey('smart-perm-accessibility'),
                    icon: Icons.accessibility_new_outlined,
                    label: tr('无障碍服务'),
                    granted: _accessibilityGranted,
                    onOpen: () async {
                      await widget.host.openSettings();
                      if (mounted) setState(() => _needAccessibility = true);
                    },
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey('smart-search-toggle'),
                      onPressed: _busy ? null : (_showing ? _stop : _start),
                      child: Text(
                        _showing ? tr('关闭悬浮窗') : tr('开启'),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
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
                key: const ValueKey('smart-search-bank'),
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
                                        ?.copyWith(fontWeight: FontWeight.w600),
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
                    fieldKey: const ValueKey('smart-search-max'),
                    stepKeyPrefix: 'smart-search-max',
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
                          key: ValueKey('smart-theme-${t.key}'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_needOverlay)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: SmallHint(
                text: tr('请在系统设置里打开「显示在其他应用上层」，然后回到这里再点开启'),
                color: scheme.error,
              ),
            ),
          if (_needAccessibility)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: SmallHint(
                text: tr('请在「无障碍」里找到 XMtools 智能搜题并打开，然后回到这里再点开启'),
                color: scheme.error,
              ),
            ),
          if (_showing)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: SmallHint(
                text: tr('悬浮窗已开启：点左上角框选题干，答案自动显示'),
              ),
            ),
          if (_blocked)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: SmallHint(
                text: tr('系统拦截了悬浮窗，请检查上面的两项授权后重试'),
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
            text: '截屏只取框选区域内的一小块，识别与匹配都在本机完成，内容不会上传',
          ),
        ],
      ),
    );
  }
}

/// 一行权限状态：已授权显示勾，未授权给「去开启」。
class _PermRow extends StatelessWidget {
  const _PermRow({
    super.key,
    required this.icon,
    required this.label,
    required this.granted,
    required this.onOpen,
  });

  final IconData icon;
  final String label;
  final bool granted;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const okColor = Color(0xFF1B7F3B);
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        if (granted)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.check_circle, size: 16, color: okColor),
              const SizedBox(width: 4),
              Text(
                tr('已授权'),
                style: theme.textTheme.bodySmall?.copyWith(color: okColor),
              ),
            ],
          )
        else
          TextButton(
            onPressed: onOpen,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(tr('去开启')),
          ),
      ],
    );
  }
}
