import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/mini_segmented.dart';
import 'aihot_api.dart';
import 'news_api.dart';
import 'news_cache.dart';

/// 新闻工具的两个版面：60s 每日简报 / AIHOT 的 AI 速递。
enum _NewsTab { daily, ai }

/// AI 速递里精选资讯的时间窗口。
enum _AiWindow { latest, week }

/// 每日新闻：默认展示 60sAPI 当天简报，可切换到 AIHOT 的 AI 速递。
class DailyNewsPage extends StatefulWidget {
  const DailyNewsPage({
    super.key,
    this.service,
    this.aiHotService,
    this.cache,
  });

  /// 可选的 60sAPI 服务（测试注入）；为空时自建并负责释放。
  final DailyNewsService? service;

  /// 可选的 AIHOT 服务（测试注入）；为空时自建并负责释放。
  final AiHotService? aiHotService;

  /// 可选的离线缓存（测试注入）。
  final NewsCache? cache;

  @override
  State<DailyNewsPage> createState() => _DailyNewsPageState();
}

class _DailyNewsPageState extends State<DailyNewsPage> {
  /// 两个版面共用一套状态：顶部切换条点击与内容区左右滑动都走它。
  final PageController _page = PageController();

  late final DailyNewsService _service;
  late final bool _ownsService;
  late final AiHotService _aiService;
  late final bool _ownsAiService;
  late final NewsCache _cache;

  _NewsTab _tab = _NewsTab.daily;
  _AiWindow _aiWindow = _AiWindow.latest;

  DailyNews? _news;

  /// 是否有请求进行中（空白时显示中央加载圈，同时防止重复触发）。
  bool _loading = false;

  /// 右上角刷新按钮是否显示加载圈：仅「点击刷新按钮且页面已有数据」时为 true。
  /// 自动加载、下拉刷新、失败重试都只显示中央状态，避免屏幕出现两个圈。
  bool _refreshButtonBusy = false;
  String? _error;

  // ---- AI 速递版面状态 ----
  List<AiHotTopic>? _hot;
  List<AiHotItem>? _aiItems;
  bool _aiLoading = false;
  String? _aiError;

  @override
  void initState() {
    super.initState();
    _ownsService = widget.service == null;
    _service = widget.service ?? DailyNewsService();
    _ownsAiService = widget.aiHotService == null;
    _aiService = widget.aiHotService ?? AiHotService();
    _cache = widget.cache ?? NewsCache();
    _load(); // 自动加载：命中 24 小时内的缓存则不再请求
  }

  @override
  void dispose() {
    _page.dispose();
    if (_ownsService) _service.dispose();
    if (_ownsAiService) _aiService.dispose();
    super.dispose();
  }

  /// [fromRefreshButton] 表示由右上角刷新按钮触发。此时页面已有数据，继续展示
  /// 旧内容，只让按钮转圈；其它入口（首次自动加载、下拉刷新、失败重试）走中央状态。
  Future<void> _load({
    bool force = false,
    bool fromRefreshButton = false,
  }) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _refreshButtonBusy = fromRefreshButton && _news != null;
      _error = null;
    });
    // 自动进入时先读离线缓存，24 小时内直接用，不消耗网络请求。
    if (!force) {
      final cached = await _cache.readDaily();
      if (cached != null) {
        if (!mounted) return;
        setState(() {
          _news = cached;
          _loading = false;
          _refreshButtonBusy = false;
        });
        return;
      }
    }
    try {
      final news = await _service.fetch();
      try {
        await _cache.saveDaily(news);
      } catch (_) {
        // 缓存写失败不影响本次展示。
      }
      if (!mounted) return;
      setState(() => _news = news);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _refreshButtonBusy = false;
        });
      }
    }
  }

  /// 顶部切换条点击：滚动到对应版面，实际的状态切换在 [onPageChanged] 里统一处理，
  /// 这样点击与左右滑动走同一条路径，不会出现选中态和内容不一致。
  void _switchTab(_NewsTab tab) {
    _page.animateToPage(
      tab.index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _onPageChanged(int index) {
    final tab = _NewsTab.values[index];
    if (tab != _tab) setState(() => _tab = tab);
    if (tab == _NewsTab.ai && _hot == null && _aiItems == null && !_aiLoading) {
      _loadAi();
    }
  }

  Future<void> _switchWindow(_AiWindow window) async {
    if (window == _aiWindow) return;
    setState(() => _aiWindow = window);
    final key = _windowKey;
    List<AiHotItem>? cached;
    try {
      cached = await _cache.readAiItems(key);
    } catch (_) {}
    if (cached != null) {
      if (mounted) setState(() => _aiItems = cached);
      return;
    }
    _loadAiItems();
  }

  /// AI 速递：先取热点榜展示在上方卡片，再取十条精选填下方长卡。
  Future<void> _loadAi({
    bool force = false,
    bool fromRefreshButton = false,
  }) async {
    if (_aiLoading) return;
    setState(() {
      _aiLoading = true;
      _refreshButtonBusy = fromRefreshButton && _aiItems != null;
      _aiError = null;
    });
    if (!force) {
      final cached = await _cache.readAi();
      if (cached != null) {
        if (!mounted) return;
        setState(() {
          _hot = cached.hot;
          _aiItems = cached.itemsFor(_windowKey);
          _aiLoading = false;
          _refreshButtonBusy = false;
        });
        return;
      }
    }
    try {
      final hot = await _aiService.fetchHot();
      try {
        await _cache.saveAiHot(hot);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _hot = hot);
    } catch (e) {
      if (!mounted) return;
      setState(() => _aiError = e.toString());
    }
    if (!mounted) return;
    try {
      final items = await _aiService.fetchSelected(_windowKey);
      try {
        await _cache.saveAiItems(_windowKey, items);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _aiItems = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _aiError = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _aiLoading = false;
          _refreshButtonBusy = false;
        });
      }
    }
  }

  /// 切换窗口时只重取精选列表，热点榜保持不变。
  Future<void> _loadAiItems() async {
    if (_aiLoading) return;
    setState(() {
      _aiLoading = true;
      _aiError = null;
    });
    try {
      final items = await _aiService.fetchSelected(_windowKey);
      try {
        await _cache.saveAiItems(_windowKey, items);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _aiItems = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _aiError = e.toString());
    } finally {
      if (mounted) setState(() => _aiLoading = false);
    }
  }

  String get _windowKey => _aiWindow == _AiWindow.week ? '7d' : '24h';

  Future<void> _refresh() => _tab == _NewsTab.daily
      ? _load(force: true, fromRefreshButton: true)
      : _loadAi(force: true, fromRefreshButton: true);

  /// PageView 里内层 ListView 的滚动通知 depth 不为 0，默认谓词收不到；
  /// 只按轴过滤，避免横向翻页也触发下拉刷新。
  static bool _verticalOnly(ScrollNotification n) =>
      n.metrics.axis == Axis.vertical;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('每日新闻')),
        actions: [
          IconButton(
            key: const ValueKey('news-refresh'),
            tooltip: tr('刷新'),
            onPressed: _refresh,
            icon: _refreshButtonBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: MiniSegmented<_NewsTab>(
                key: const ValueKey('news-tab'),
                selected: _tab,
                onChanged: _switchTab,
                options: <MiniSegmentedOption<_NewsTab>>[
                  MiniSegmentedOption<_NewsTab>(
                    value: _NewsTab.daily,
                    label: tr('每日新闻'),
                    key: const ValueKey('news-tab-daily'),
                  ),
                  MiniSegmentedOption<_NewsTab>(
                    value: _NewsTab.ai,
                    label: tr('AI速递'),
                    key: const ValueKey('news-tab-ai'),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: PageView(
              key: const ValueKey('news-pages'),
              controller: _page,
              onPageChanged: _onPageChanged,
              children: <Widget>[
                RefreshIndicator(
                  onRefresh: () => _load(force: true),
                  notificationPredicate: _verticalOnly,
                  child: _content(context),
                ),
                RefreshIndicator(
                  onRefresh: () => _loadAi(force: true),
                  notificationPredicate: _verticalOnly,
                  child: _aiContent(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final theme = Theme.of(context);
    final news = _news;

    // 首次加载且没有任何数据。
    if (news == null) {
      if (_loading) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(
              height: 320,
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
        );
      }
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 60),
          EmptyState(
            icon: Icons.cloud_off_outlined,
            title: tr('加载失败'),
            text: _error ?? tr('请稍后重试'),
            action: FilledButton.tonalIcon(
              onPressed: () => _load(),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(tr('重试')),
            ),
          ),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        _headerCard(theme, news),
        if (_error != null) ...[
          const SizedBox(height: 10),
          HintBanner(text: trf('刷新失败：{e}', {'e': _error!})),
        ],
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
            child: Column(
              children: [
                for (var i = 0; i < news.news.length; i++)
                  _NewsItem(index: i + 1, text: news.news[i]),
              ],
            ),
          ),
        ),
        if (news.tip.isNotEmpty) ...[
          const SizedBox(height: 12),
          _tipCard(theme, news.tip),
        ],
        const SizedBox(height: 14),
        Text(
          tr('数据来源：60sAPI'),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
    );
  }

  Widget _aiContent(BuildContext context) {
    final theme = Theme.of(context);
    final hot = _hot;
    final items = _aiItems;

    // 首次加载且两栏都没有数据。
    if (hot == null && items == null) {
      if (_aiLoading) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(
              height: 320,
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
        );
      }
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 60),
          EmptyState(
            icon: Icons.cloud_off_outlined,
            title: tr('加载失败'),
            text: _aiError ?? tr('请稍后重试'),
            action: FilledButton.tonalIcon(
              onPressed: () => _loadAi(),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(tr('重试')),
            ),
          ),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        if (hot != null) _hotCard(theme, hot),
        if (_aiError != null) ...[
          const SizedBox(height: 10),
          HintBanner(text: trf('刷新失败：{e}', {'e': _aiError!})),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Text(
              tr('精选资讯'),
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            MiniSegmented<_AiWindow>(
              key: const ValueKey('news-ai-window'),
              height: 26,
              fontSize: 11.5,
              selected: _aiWindow,
              onChanged: _switchWindow,
              options: <MiniSegmentedOption<_AiWindow>>[
                MiniSegmentedOption<_AiWindow>(
                  value: _AiWindow.latest,
                  label: tr('24 小时'),
                  key: const ValueKey('news-ai-window-latest'),
                ),
                MiniSegmentedOption<_AiWindow>(
                  value: _AiWindow.week,
                  label: tr('近 7 天'),
                  key: const ValueKey('news-ai-window-week'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (items != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
              child: Column(
                children: [
                  for (var i = 0; i < items.length; i++)
                    _AiItemCard(index: i + 1, item: items[i]),
                ],
              ),
            ),
          )
        else if (_aiLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          ),
        const SizedBox(height: 14),
        Text(
          tr('数据来源：AIHOT'),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
    );
  }

  Widget _hotCard(ThemeData theme, List<AiHotTopic> hot) {
    final scheme = theme.colorScheme;
    final shown = hot.take(5).toList(growable: false);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            scheme.primaryContainer,
            scheme.primaryContainer.withOpacity(0.55),
          ],
        ),
        border: Border.all(color: scheme.primary.withOpacity(0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.local_fire_department_outlined,
                  size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                tr('AI 热点'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  trf('{n} 条', {'n': shown.length}),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onPrimaryContainer),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final topic in shown) _HotRow(topic: topic),
        ],
      ),
    );
  }

  Widget _headerCard(ThemeData theme, DailyNews news) {
    final scheme = theme.colorScheme;
    final subParts = <String>[
      if (news.dayOfWeek.isNotEmpty) news.dayOfWeek,
      if (news.lunarDate.isNotEmpty) news.lunarDate,
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            scheme.primaryContainer,
            scheme.primaryContainer.withOpacity(0.55),
          ],
        ),
        border: Border.all(color: scheme.primary.withOpacity(0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.newspaper_outlined, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                tr('今日简报'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  trf('{n} 条', {'n': news.news.length}),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onPrimaryContainer),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _dateText(news),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onPrimaryContainer,
            ),
          ),
          if (subParts.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subParts.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onPrimaryContainer.withOpacity(0.75)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tipCard(ThemeData theme, String tip) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.auto_awesome_outlined,
              size: 16, color: theme.colorScheme.tertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tip,
              style: theme.textTheme.bodySmall
                  ?.copyWith(height: 1.5, fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }

  static String _dateText(DailyNews news) {
    if (news.date.isEmpty) return tr('今日新闻');
    return news.date;
  }
}

class _HotRow extends StatelessWidget {
  const _HotRow({required this.topic});

  final AiHotTopic topic;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withOpacity(0.18),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              '${topic.rank}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  topic.title,
                  maxLines: 2,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                        height: 1.4,
                      ),
                ),
                if (topic.sourceName.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    topic.sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimaryContainer.withOpacity(0.7),
                        ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AiItemCard extends StatelessWidget {
  const _AiItemCard({required this.index, required this.item});

  final int index;
  final AiHotItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$index',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  item.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (item.summary.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  SelectableText(
                    item.summary,
                    maxLines: 3,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                ],
                const SizedBox(height: 3),
                Text(
                  [
                    if (item.sourceName.isNotEmpty) item.sourceName,
                    if (item.timeLabel.isNotEmpty) item.timeLabel,
                  ].join(' · '),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NewsItem extends StatelessWidget {
  const _NewsItem({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$index',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
            ),
          ),
        ],
      ),
    );
  }
}
