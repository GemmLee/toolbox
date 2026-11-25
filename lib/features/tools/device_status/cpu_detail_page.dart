import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import 'device_status_channel.dart';

/// CPU 详情：每核频率/调速器/在线状态、频率驻留分布、温度传感器。
class CpuDetailPage extends StatefulWidget {
  const CpuDetailPage({super.key});

  @override
  State<CpuDetailPage> createState() => _CpuDetailPageState();
}

class _CpuDetailPageState extends State<CpuDetailPage> {
  CpuDetail? _detail;
  DeviceSnapshot? _snapshot;
  DeviceSnapshot? _prev;
  Timer? _timer;
  int _tick = 0;
  bool _inFlight = false;

  /// 频率档 → 采样次数（所有核心合计），用于「驻留分布」。
  final Map<int, int> _dwell = <int, int>{};

  @override
  void initState() {
    super.initState();
    _loadDetail();
    _tickOnce();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) _tickOnce();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadDetail() async {
    final detail = await DeviceStatusChannel.cpuDetail();
    if (!mounted || detail == null) return;
    setState(() => _detail = detail);
  }

  Future<void> _tickOnce() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final snap = await DeviceStatusChannel.snapshot();
      if (!mounted || snap == null) return;
      setState(() {
        _prev = _snapshot;
        _snapshot = snap;
        _tick++;
      });
      for (final core in snap.cores) {
        if (core.curFreq <= 0) continue;
        final slot = _nearestSlot(core.curFreq);
        _dwell[slot] = (_dwell[slot] ?? 0) + 1;
      }
      // 静态信息（档位/温度/调速器变化）每 15 秒回读一次足够
      if (_tick % 7 == 0) await _loadDetail();
    } finally {
      _inFlight = false;
    }
  }

  /// 把当前频率归并到最近的档位（部分机型 curFreq 有几十 kHz 抖动）。
  int _nearestSlot(int freq) {
    final freqs = _detail?.cores.firstOrNull?.freqs ?? const <int>[];
    if (freqs.isEmpty) return (freq / 100000).round() * 100000;
    var best = freqs.first;
    var bestGap = (best - freq).abs();
    for (final f in freqs) {
      final gap = (f - freq).abs();
      if (gap < bestGap) {
        best = f;
        bestGap = gap;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    final snap = _snapshot;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('CPU 详情')),
        actions: [
          IconButton(
            tooltip: tr('立即刷新'),
            onPressed: () {
              _loadDetail();
              _tickOnce();
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: detail == null
          ? Center(
              child: Text(tr('无法读取 CPU 信息')),
            )
          : RefreshIndicator(
              onRefresh: () async {
                await _loadDetail();
                await _tickOnce();
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _summaryCard(theme, detail, snap),
                  const SizedBox(height: 14),
                  _coresCard(theme, detail, snap),
                  const SizedBox(height: 14),
                  _dwellCard(theme),
                  const SizedBox(height: 14),
                  _thermalCard(theme, detail),
                ],
              ),
            ),
    );
  }

  Widget _summaryCard(ThemeData theme, CpuDetail d, DeviceSnapshot? snap) {
    final cores = snap?.cores ?? const <CoreSnapshot>[];
    final online = d.cores.where((c) => c.online).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: MetricTile(
                label: tr('核心'),
                value: '${d.cores.length}',
                compact: true,
                labelFirst: true,
              ),
            ),
            Expanded(
              child: MetricTile(
                label: tr('在线'),
                value: '$online',
                compact: true,
                labelFirst: true,
              ),
            ),
            Expanded(
              child: MetricTile(
                label: tr('最高温度'),
                value: d.maxTemp > 0
                    ? '${formatMoney(d.maxTemp, digits: 1)}℃'
                    : '--',
                compact: true,
                labelFirst: true,
              ),
            ),
            Expanded(
              child: MetricTile(
                label: tr('平均占用'),
                value: _avgUsage(cores) >= 0
                    ? '${formatMoney(_avgUsage(cores) * 100, digits: 0)}%'
                    : '--',
                compact: true,
                labelFirst: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _avgUsage(List<CoreSnapshot> cores) {
    final prev = _prev;
    if (prev == null || cores.isEmpty) return -1;
    var sum = 0.0;
    var n = 0;
    for (final core in cores) {
      final old = prev.cores.where((c) => c.index == core.index).firstOrNull;
      final usage = coreUsage(old, core);
      if (usage >= 0) {
        sum += usage;
        n++;
      }
    }
    return n == 0 ? -1 : sum / n;
  }

  Widget _coresCard(ThemeData theme, CpuDetail d, DeviceSnapshot? snap) {
    final byIndex = <int, CoreSnapshot>{
      for (final c in snap?.cores ?? const <CoreSnapshot>[]) c.index: c,
    };
    return SectionCard(
      title: tr('核心状态'),
      subtitle: tr('每 2 秒刷新；频率条按该核的最小/最大频率取值'),
      children: [
        for (final core in d.cores) ...<Widget>[
          _coreRow(theme, core, byIndex[core.index]),
          if (core != d.cores.last) const Divider(height: 18),
        ],
      ],
    );
  }

  Widget _coreRow(ThemeData theme, CpuCoreDetail core, CoreSnapshot? live) {
    final scheme = theme.colorScheme;
    final cur = live?.curFreq ?? core.curFreq;
    final minFreq = core.minFreq > 0 ? core.minFreq : live?.minFreq ?? 0;
    final maxFreq = core.maxFreq > 0 ? core.maxFreq : live?.maxFreq ?? 0;
    final t = maxFreq > minFreq
        ? ((cur - minFreq) / (maxFreq - minFreq)).clamp(0.0, 1.0)
        : 0.0;
    final usage = live == null
        ? -1.0
        : coreUsage(
            _prev?.cores.where((c) => c.index == core.index).firstOrNull,
            live,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 34,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: core.online
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'CPU${core.index}',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: core.online
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              cur > 0 ? '${formatMoney(cur / 1000000, digits: 2)} GHz' : '--',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            if (usage >= 0)
              Text(
                '${formatMoney(usage * 100, digits: 0)}%',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: t,
            minHeight: 6,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              minFreq > 0
                  ? '${formatMoney(minFreq / 1000000, digits: 2)} ~ '
                      '${formatMoney(maxFreq / 1000000, digits: 2)} GHz'
                  : tr('频率区间未知'),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            Text(
              core.online ? (core.governor.isEmpty ? tr('在线') : core.governor) : tr('离线'),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }

  /// 频率驻留分布：本页打开后每秒采样，统计各档位的停留占比。
  Widget _dwellCard(ThemeData theme) {
    final total = _dwell.values.fold<int>(0, (a, b) => a + b);
    final entries = _dwell.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final top = entries.isEmpty
        ? 0
        : entries.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    return SectionCard(
      title: tr('频率驻留'),
      subtitle: tr('本次打开页面后的采样分布，越靠右频率越高'),
      children: [
        if (entries.isEmpty)
          Text(tr('采样中，稍候即可看到分布'), style: theme.textTheme.bodySmall)
        else
          for (final e in entries.reversed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 62,
                    child: Text(
                      '${formatMoney(e.key / 1000000, digits: 2)}G',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: top == 0 ? 0 : e.value / top,
                        minHeight: 8,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 46,
                    child: Text(
                      '${(e.value * 100 / total).toStringAsFixed(0)}%',
                      textAlign: TextAlign.right,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _thermalCard(ThemeData theme, CpuDetail d) {
    final zones = d.thermal.take(12).toList();
    return SectionCard(
      title: tr('温度传感器'),
      subtitle: d.soc.isEmpty
          ? null
          : trf('SoC：{n}', {'n': d.soc}),
      children: [
        if (zones.isEmpty)
          Text(tr('系统未提供温度传感器'), style: theme.textTheme.bodySmall)
        else
          for (final z in zones)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      z.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: (z.temp / 100).clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        color: z.temp >= 60
                            ? const Color(0xFFE5484D)
                            : z.temp >= 45
                                ? const Color(0xFFF0A22E)
                                : theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 52,
                    child: Text(
                      '${formatMoney(z.temp, digits: 1)}℃',
                      textAlign: TextAlign.right,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
