import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import 'typhoon_api.dart';
import 'typhoon_detail_page.dart';
import 'typhoon_geo.dart';
import 'typhoon_widgets.dart';

/// 台风播报：列出某一年度台风，点选查看登陆预报与路径。
///
/// 列表先拉年度清单，再并发拉各台风详情判断「预计登陆地点是否在中国海域
/// 或近中国海域」（预警台风分组）与「生命周期最大强度」——这两项列表接口
/// 都不返回。
class TyphoonPage extends StatefulWidget {
  const TyphoonPage({super.key, this.api});

  final TyphoonApi? api;

  @override
  State<TyphoonPage> createState() => _TyphoonPageState();
}

class _TyphoonPageState extends State<TyphoonPage> {
  late final TyphoonApi _api;
  late final bool _ownsApi;

  late int _year;
  List<TyphoonSummary> _items = const <TyphoonSummary>[];
  bool _loading = true;
  String? _error;

  /// tfid → 是否为预警台风（预计登陆地点在中国海域或近中国海域）。
  final Map<String, bool> _warning = <String, bool>{};

  /// tfid → 生命周期内的最大强度（用于「强台风」及以上标注）。
  final Map<String, TyphoonStrength> _maxStrength = <String, TyphoonStrength>{};
  bool _classifying = false;
  int _classifyDone = 0;
  int _classifyTotal = 0;

  /// 未进入示意图范围的台风默认折叠。
  bool _showOthers = false;

  @override
  void initState() {
    super.initState();
    _ownsApi = widget.api == null;
    _api = widget.api ?? TyphoonApi();
    _year = DateTime.now().year;
    _load();
  }

  @override
  void dispose() {
    if (_ownsApi) _api.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _showOthers = false;
    });
    try {
      final items = await _api.list(_year);
      if (!mounted) return;
      // 活跃优先，再按起始时间倒序（最近生成靠前）。
      final sorted = List<TyphoonSummary>.from(items);
      sorted.sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        return b.startTime.compareTo(a.startTime);
      });
      setState(() {
        _items = sorted;
        _loading = false;
      });
      _classify(sorted);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 逐个拉取详情，按预计登陆地点分组（列表接口不含坐标与预报路径）。
  ///
  /// 拉取失败的台风按「预警」处理，避免把无法判定的台风误折叠起来。
  Future<void> _classify(List<TyphoonSummary> items) async {
    final missing = items
        .map((e) => e.tfid)
        .where((id) => !_warning.containsKey(id))
        .toList(growable: false);
    if (missing.isEmpty) return;
    setState(() {
      _classifying = true;
      _classifyDone = 0;
      _classifyTotal = missing.length;
    });
    try {
      final details = await _api.details(
        missing,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _classifyDone = done;
            _classifyTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        details.forEach((tfid, d) {
          _warning[tfid] = d == null ? true : isWarningTyphoon(d);
          _maxStrength[tfid] = d == null
              ? TyphoonStrength.unknown
              : maxStrengthOf(d.points, d.land);
        });
        _classifying = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _classifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('台风播报')),
        actions: [
          IconButton(
            key: const ValueKey('typhoon-refresh'),
            tooltip: tr('刷新'),
            onPressed: _loading ? null : _load,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            _yearBar(),
            const SizedBox(height: 12),
            if (_error != null)
              TyphoonErrorCard(message: _error!, onRetry: _load)
            else if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_items.isEmpty)
              TyphoonEmptyCard(year: _year)
            else
              ..._groupedItems(),
          ],
        ),
      ),
    );
  }

  /// 「预警台风」（预计登陆地点在中国海域或近中国海域）常显，其余默认折叠。
  List<Widget> _groupedItems() {
    final near = <TyphoonSummary>[];
    final others = <TyphoonSummary>[];
    for (final s in _items) {
      if (_warning[s.tfid] ?? true) {
        near.add(s);
      } else {
        others.add(s);
      }
    }
    return <Widget>[
      if (_classifying) _classifyingHint(),
      if (near.isNotEmpty) ...[
        _sectionHeader(
          icon: Icons.place,
          label: tr('预警台风'),
          count: near.length,
          color: Colors.deepPurple,
        ),
        ...near.map((s) => _itemCard(s)),
      ],
      if (others.isNotEmpty) ...[
        const SizedBox(height: 4),
        _othersSectionHeader(others.length),
        if (_showOthers) ...others.map((s) => _itemCard(s)),
      ],
    ];
  }

  Widget _classifyingHint() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            '${tr('正在识别预警台风')} $_classifyDone/$_classifyTotal',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader({
    required IconData icon,
    required String label,
    required int count,
    required Color color,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _othersSectionHeader(int count) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Row(
        children: [
          Icon(Icons.public_off, size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: 6),
          Text(
            tr('其他台风'),
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('typhoon-list-others-toggle'),
            onPressed: () => setState(() => _showOthers = !_showOthers),
            icon: Icon(
              _showOthers ? Icons.expand_less : Icons.expand_more,
              size: 19,
            ),
            label: Text(
              _showOthers ? tr('折叠其他台风') : tr('显示其他台风'),
              style: const TextStyle(fontSize: 12),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  Widget _yearBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: tr('上一年'),
          onPressed: () {
            setState(() => _year -= 1);
            _load();
          },
          icon: const Icon(Icons.chevron_left),
        ),
        Text(
          '$_year',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        IconButton(
          tooltip: tr('下一年'),
          onPressed: () {
            setState(() => _year += 1);
            _load();
          },
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  Widget _itemCard(TyphoonSummary s) {
    final theme = Theme.of(context);
    final maxS = _maxStrength[s.tfid] ?? TyphoonStrength.unknown;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TyphoonDetailPage(tfid: s.tfid, api: _api),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            s.name,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // 生命周期内达到「强台风」及以上时标注最大强度
                        if (maxS.index >= TyphoonStrength.severeTyphoon.index)
                          TyphoonStrengthBadge(strength: maxS),
                        if (s.isActive)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              tr('进行中'),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.enname,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${tr('生成')} ${s.startTime.split(' ').first}'
                      '${s.isActive ? ' · ${tr('进行中')}' : s.endTime.isNotEmpty ? ' · ${tr('结束')} ${s.endTime.split(' ').first}' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (s.warnLevel.isNotEmpty) TyphoonWarnBadge(level: s.warnLevel),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
