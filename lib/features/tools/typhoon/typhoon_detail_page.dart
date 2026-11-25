import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import 'typhoon_api.dart';
import 'typhoon_geo.dart';
import 'typhoon_map.dart';
import 'typhoon_widgets.dart';

/// 台风详情：当前态势 + 路径示意图 + 登陆预报 + 路径时间线。
class TyphoonDetailPage extends StatefulWidget {
  const TyphoonDetailPage({super.key, required this.tfid, this.api});

  final String tfid;
  final TyphoonApi? api;

  @override
  State<TyphoonDetailPage> createState() => _TyphoonDetailPageState();
}

class _TyphoonDetailPageState extends State<TyphoonDetailPage> {
  late final TyphoonApi _api;
  late final bool _ownsApi;

  TyphoonDetail? _detail;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ownsApi = widget.api == null;
    _api = widget.api ?? TyphoonApi();
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
    });
    try {
      final detail = await _api.info(widget.tfid);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = _detail;
    return Scaffold(
      appBar: AppBar(
        title: Text(d?.name ?? widget.tfid),
        actions: [
          IconButton(
            key: const ValueKey('typhoon-detail-refresh'),
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
            if (_error != null)
              TyphoonErrorCard(message: _error!, onRetry: _load)
            else if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (d != null) ...[
              _headerCard(d, theme),
              const SizedBox(height: 12),
              _mapCard(d, theme),
              const SizedBox(height: 12),
              _landingCard(d, theme),
              const SizedBox(height: 12),
              _trackCard(d, theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _headerCard(TyphoonDetail d, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    d.name,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                if (d.isActive)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      tr('进行中'),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  )
                else
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      tr('已停编'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              d.enname,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 10),
            if (d.displayCenterLng != null && d.displayCenterLat != null)
              Text(
                '${tr('最新位置')}：${d.displayCenterLat!.toStringAsFixed(1)}°N, '
                '${d.displayCenterLng!.toStringAsFixed(1)}°E',
                style: theme.textTheme.bodyMedium,
              ),
          ],
        ),
      ),
    );
  }

  Widget _mapCard(TyphoonDetail d, ThemeData theme) {
    final hasData =
        d.points.isNotEmpty || d.displayCenterLng != null || d.displayCenterLat != null;
    // 已结束不再画预测路径；已登陆/已结束不再画预计登陆地点。
    final forecasts = d.showForecastTracks
        ? d.latestForecasts
        : const <ForecastTrack>[];
    final landfall =
        d.showPredictedLandfall ? predictedLandfallOf(d) : null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: [
                const Icon(Icons.map_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr('台风路径示意图'),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          hasData
              ? TyphoonMap(
                  points: d.points,
                  centerLng: d.displayCenterLng,
                  centerLat: d.displayCenterLat,
                  land: d.land,
                  radius7: d.windCirclePoint?.radius7,
                  radius10: d.windCirclePoint?.radius10,
                  radius12: d.windCirclePoint?.radius12,
                  forecasts: forecasts,
                  predictedLandfall: landfall,
                )
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(child: Text(tr('暂无路径与中心位置数据'))),
                ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            child: Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                LegendDot(color: Colors.redAccent, label: tr('常登陆城市')),
                LegendDot(color: Colors.red, label: tr('台风中心（台）')),
                LegendDot(color: Colors.deepPurple, label: tr('终点日期')),
                if (landfall != null)
                  LegendDot(
                      color: Colors.orange.shade800, label: tr('预计登陆地点')),
                if (forecasts.isNotEmpty)
                  LegendDot(color: Colors.teal.shade700, label: tr('预计路径')),
                LegendDot(color: Colors.lightBlue.shade400, label: tr('风圈半径')),
                LegendGradient(label: tr('路径按强度着色')),
              ],
            ),
          ),
          // 强度图例（由弱到强）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                for (final s in kLegendStrengths)
                  LegendDot(
                    color: typhoonStrengthColor(s,
                        dark: theme.brightness == Brightness.dark),
                    label: tr(strengthLabel(s)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _landingCard(TyphoonDetail d, ThemeData theme) {
    final mainland = d.mainlandLandings;
    final others = d.land.where((l) => !l.isMainland).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    final all = <Landing>[...mainland, ...others];

    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Text(
                  tr('登陆预报'),
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              tr('数据来源：浙江省水利厅台风路径系统'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 10),
            if (all.isEmpty)
              _emptyLanding(d, theme)
            else
              ...all.map((l) => _landingRow(l, theme)),
          ],
        ),
      ),
    );
  }

  /// 没有登陆记录时，用最近一条预报路径推一个预计登陆点展示，不留空卡片。
  /// 已结束的台风预测已失效，不再展示预计登陆地点。
  Widget _emptyLanding(TyphoonDetail d, ThemeData theme) {
    final p = d.showPredictedLandfall ? predictedLandfallOf(d) : null;
    if (p == null) {
      return Text(tr('暂无登陆预报记录'), style: theme.textTheme.bodyMedium);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${tr('预计登陆地点')}：${p.lat.toStringAsFixed(1)}°N, '
          '${p.lng.toStringAsFixed(1)}°E',
          style: theme.textTheme.bodyMedium,
        ),
        if (p.time != null) ...[
          const SizedBox(height: 2),
          Text(
            '${tr('预计登陆时间')}：${p.time!.replaceAll('  ', ' ')}',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ],
    );
  }

  Widget _landingRow(Landing l, ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // 跟随主题，避免深色模式下固定白底配默认浅色文字导致看不清。
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l.address,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: l.isMainland ? Colors.red : Colors.grey,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  l.isMainland ? tr('大陆') : tr('其他地区'),
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${tr('预计登陆时间')}：${l.time.replaceAll('  ', ' ')}',
            style: theme.textTheme.bodyMedium,
          ),
          if (l.strong != null) ...[
            const SizedBox(height: 2),
            Text(
              '${tr('登陆强度')}：${l.strong}',
              style: theme.textTheme.bodyMedium,
            ),
          ],
          if (l.info != null) ...[
            const SizedBox(height: 6),
            Text(
              l.info!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ],
      ),
    );
  }

  Widget _trackCard(TyphoonDetail d, ThemeData theme) {
    final points = d.points;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('路径时间线'),
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (points.isEmpty)
              Text(tr('暂无路径数据'), style: theme.textTheme.bodyMedium)
            else
              ...points.map((p) => _trackRow(p, theme)),
          ],
        ),
      ),
    );
  }

  Widget _trackRow(TrackPoint p, ThemeData theme) {
    final move = <String>[
      if (p.moveDirection != null) p.moveDirection!,
      if (p.moveSpeed != null) '${p.moveSpeed}km/h',
    ].join(' ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  p.time,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (p.strong != null)
                Text(p.strong!, style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${p.lat != null ? "${p.lat!.toStringAsFixed(1)}°N" : '--'} · '
            '${p.lng != null ? "${p.lng!.toStringAsFixed(1)}°E" : '--'}'
            '${p.pressure != null ? ' · ${tr('气压')} ${p.pressure}hPa' : ''}'
            '${p.speed != null ? ' · ${tr('风速')} ${p.speed}m/s' : ''}',
            style: theme.textTheme.bodySmall,
          ),
          if (move.isNotEmpty)
            Text(
              '${tr('移动')}：$move',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          const Divider(height: 12),
        ],
      ),
    );
  }
}
