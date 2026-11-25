import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import '../ip_diagnosis/logic/ip_diagnosis_service.dart';
import 'battery_detail_page.dart';
import 'battery_history.dart';
import 'cpu_detail_page.dart';
import 'device_status_channel.dart';
import 'ip_diagnosis_card.dart';
import 'network_detail_pages.dart';
import 'storage_detail_page.dart';

/// 开机时长：不足一天显示「小时 分」，超过一天改显示「天 小时」。
String formatUptime(Duration uptime) {
  if (uptime.inHours >= 24) {
    return trf('{d} 天 {h} 小时', {
      'd': uptime.inDays,
      'h': uptime.inHours % 24,
    });
  }
  return trf('{h} 小时 {m} 分', {
    'h': uptime.inHours,
    'm': uptime.inMinutes % 60,
  });
}

/// 手机状态监控：内存 / 存储 / CPU / 电池 / 系统信息，1s 自动刷新。
class DeviceStatusPage extends StatefulWidget {
  const DeviceStatusPage({super.key});

  @override
  State<DeviceStatusPage> createState() => _DeviceStatusPageState();
}

class _DeviceStatusPageState extends State<DeviceStatusPage> {
  DeviceStaticInfo? _static;
  DeviceSnapshot? _current;
  DeviceSnapshot? _previous;
  double _fps = 0;
  bool _auto = true;
  bool _loading = true;
  String? _error;
  Timer? _timer;

  /// 网络诊断卡片的页面级状态：监控页每秒 setState、ListView 会回收滚出屏幕的
  /// child，状态必须由页面持有，卡片只订阅，避免滚动 / 刷新时丢诊断结果。
  /// 两张网络卡片各自只跑自己那部分：IP 检测不测速、测速不查 IP 情报，
  /// 一次点击不会同时发起两套外网请求。
  final _ipController =
      IpDiagnosisController(scope: DiagnosisScope.ip);
  final _speedController =
      IpDiagnosisController(scope: DiagnosisScope.speed);

  /// 防止 1 秒轮询与下拉刷新并发，避免快照乱序覆盖。
  bool _inFlight = false;

  @override
  void initState() {
    super.initState();
    _loadStatic();
    _refresh();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ipController.dispose();
    _speedController.dispose();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_auto && mounted) _refresh();
    });
  }

  Future<void> _loadStatic() async {
    final info = await DeviceStatusChannel.staticInfo();
    if (!mounted) return;
    setState(() => _static = info);
  }

  Future<void> _refresh() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final snapshot = await DeviceStatusChannel.snapshot();
      if (!mounted) return;
      setState(() {
        _previous = _current;
        _current = snapshot;
        _loading = false;
        if (snapshot == null) {
          _error = tr('无法获取设备状态（仅支持 Android 真机/模拟器）');
          return;
        }
        _error = null;
        if (snapshot.framesElapsedMs > 200) {
          final fps = snapshot.framesDelta * 1000 / snapshot.framesElapsedMs;
          // 平滑显示，过滤偶发抖动
          _fps = _fps <= 0 ? fps : _fps * 0.6 + fps * 0.4;
        }
      });
      // 记一条采样，供电池详情画 24 小时曲线（间隔不足 30s 时内部会忽略）
      if (snapshot != null) {
        unawaited(BatteryHistory.add(BatterySample(
          time: DateTime.now(),
          level: snapshot.batteryLevel,
          temp: snapshot.batteryTemp,
          currentUa: snapshot.batteryCurrentUa,
        )));
      }
    } finally {
      _inFlight = false;
    }
  }

  void _toggleAuto() {
    setState(() => _auto = !_auto);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('手机状态监控')),
        actions: [
          IconButton(
            tooltip: _auto ? tr('暂停自动刷新') : tr('开启自动刷新'),
            onPressed: _toggleAuto,
            icon:
                Icon(_auto ? Icons.pause_outlined : Icons.play_arrow_outlined),
          ),
          IconButton(
            tooltip: tr('立即刷新'),
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView(theme)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  children: [
                    _tappable(
                      _memoryStorageCard(),
                      () => _pushDetail(const StorageDetailPage()),
                    ),
                    const SizedBox(height: 14),
                    _tappable(
                      _cpuCard(),
                      () => _pushDetail(const CpuDetailPage()),
                    ),
                    const SizedBox(height: 14),
                    _tappable(
                      _batteryCard(),
                      () => _pushDetail(const BatteryDetailPage()),
                    ),
                    const SizedBox(height: 14),
                    _deviceCard(),
                    const SizedBox(height: 14),
                    _tappable(
                      IpBriefCard(controller: _ipController),
                      () => _pushDetail(
                        IpDetailPage(controller: _ipController),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _tappable(
                      SpeedBriefCard(controller: _speedController),
                      () => _pushDetail(
                        SpeedDetailPage(controller: _speedController),
                      ),
                    ),
                  ],
                ),
    );
  }

  void _pushDetail(Widget page) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  Widget _tappable(Widget child, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: child,
    );
  }

  Widget _errorView(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  /// 内存 + 存储合并卡：上半是内存/交换的环形占比，下半是内部存储占用。
  ///
  /// 两者原本是两张卡，但点进去是同一个详情页，合成一张后列表更紧凑。
  Widget _memoryStorageCard() {
    final theme = Theme.of(context);
    final snapshot = _current;

    final ramTotal = snapshot?.ramTotal ?? 0;
    final ramUsed = ((snapshot?.ramTotal ?? 0) - (snapshot?.ramAvail ?? 0))
        .clamp(0, ramTotal);
    final swapTotal = snapshot?.swapTotal ?? 0;
    final swapUsed =
        (swapTotal - (snapshot?.swapFree ?? 0)).clamp(0, swapTotal);

    final total = snapshot?.storageTotal ?? 0;
    final free = snapshot?.storageFree ?? 0;
    final used = (total - free).clamp(0, total);
    final pct = total > 0 ? used / total : 0.0;

    final muted = theme.colorScheme.onSurfaceVariant;
    final tabular = theme.textTheme.bodySmall?.copyWith(
      color: muted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return SectionCard(
      title: tr('内存存储'),
      trailing: Icon(Icons.chevron_right, size: 20, color: muted),
      children: [
        Row(
          children: [
            Expanded(
              child: _ringTile(
                label: tr('内存'),
                value: ramTotal > 0 ? ramUsed / ramTotal : 0,
                detail: '${formatBytes(ramUsed, digits: 2)}\n'
                    '${formatBytes(ramTotal, digits: 2)}',
              ),
            ),
            Expanded(
              child: _ringTile(
                label: tr('交换'),
                value: swapTotal > 0 ? swapUsed / swapTotal : 0,
                detail: '${formatBytes(swapUsed, digits: 2)}\n'
                    '${formatBytes(swapTotal, digits: 2)}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Divider(
          height: 1,
          color: theme.colorScheme.outlineVariant.withOpacity(0.6),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(tr('内部存储'), style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text('${formatBytes(used)} / ${formatBytes(total)}',
                style: tabular),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 8,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '${(pct * 100).toStringAsFixed(0)}%',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }

  Widget _cpuCard() {
    final snapshot = _current;
    final cores = snapshot?.cores ?? const <CoreSnapshot>[];
    final temp = snapshot?.cpuTemp ?? 0;
    return SectionCard(
      title: trf('CPU（{n} 核）', {'n': cores.length}),
      subtitle: temp > 0
          ? '${tr('温度')} ${formatMoney(temp, digits: 1)}℃'
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InfoHint(
            text: tr('占用率按两次采样的 /proc/stat 差值计算'),
          ),
          Icon(
            Icons.chevron_right,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
      children: [
        if (cores.isEmpty)
          Text(tr('无法读取 CPU 信息'), style: Theme.of(context).textTheme.bodySmall)
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 10,
              childAspectRatio: 0.74,
            ),
            itemCount: cores.length,
            itemBuilder: (context, i) {
              final core = cores[i];
              final usage = coreUsage(_prevCore(core.index), core);
              return _cpuCell(core: core, usage: usage);
            },
          ),
      ],
    );
  }

  CoreSnapshot? _prevCore(int index) {
    final previous = _previous;
    if (previous == null) return null;
    for (final core in previous.cores) {
      if (core.index == index) return core;
    }
    return null;
  }

  Widget _cpuCell({required CoreSnapshot core, required double usage}) {
    final theme = Theme.of(context);
    final freqMhz = core.curFreq > 0 ? (core.curFreq / 1000).round() : 0;
    final range = core.maxFreq > 0
        ? '${(core.minFreq / 1000).round()}~${(core.maxFreq / 1000).round()}MHz'
        : '';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _Ring(
          value: usage < 0 ? 0 : usage,
          center: usage < 0 ? '--' : '${(usage * 100).toStringAsFixed(0)}%',
          size: 50,
          stroke: 4.5,
        ),
        const SizedBox(height: 5),
        Text(
          'Cpu${core.index}',
          style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
          maxLines: 1,
        ),
        Text(
          freqMhz > 0 ? '$freqMhz MHz' : tr('离线'),
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
        ),
        Text(
          range,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 9,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _batteryCard() {
    final snapshot = _current;
    if (snapshot == null) return const SizedBox.shrink();
    final level = snapshot.batteryLevel;
    final voltageV = snapshot.batteryVoltageMv / 1000.0;
    final currentValid = snapshot.batteryCurrentUa != 0;
    final currentMa = snapshot.batteryCurrentUa / 1000.0;
    final powerW = currentValid
        ? (voltageV * currentMa.abs() / 1000).clamp(0.0, 1000.0)
        : 0.0;
    final charging = _isCharging(snapshot);
    return SectionCard(
      title: tr('电池'),
      subtitle: _batteryStateText(snapshot),
      trailing: Icon(
        Icons.chevron_right,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Ring(
              value: level >= 0 ? level / 100 : 0,
              center: level >= 0 ? '${level.toStringAsFixed(0)}%' : '--',
              size: 64,
              stroke: 6,
              color: charging ? const Color(0xFF34C77B) : null,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                          child: MetricTile(
                        label: tr('温度'),
                        value:
                            '${formatMoney(snapshot.batteryTemp, digits: 1)}℃',
                        compact: true,
                        labelFirst: true,
                      )),
                      Expanded(
                          child: MetricTile(
                        label: tr('电压'),
                        value: '${formatMoney(voltageV, digits: 2)} V',
                        compact: true,
                        labelFirst: true,
                      )),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: MetricTile(
                          label: trf('电流（{s}）', {
                            's': charging ? tr('充电') : tr('放电'),
                          }),
                          value: currentValid
                              ? '${formatMoney(currentMa.abs(), digits: 0)} mA'
                              : '--',
                          compact: true,
                          labelFirst: true,
                        ),
                      ),
                      Expanded(
                        child: MetricTile(
                          label: tr('功率'),
                          value: currentValid
                              ? '${formatMoney(powerW, digits: 2)} W'
                              : '--',
                          compact: true,
                          labelFirst: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  bool _isCharging(DeviceSnapshot snapshot) {
    return snapshot.batteryStatus == 2 ||
        snapshot.batteryStatus == 5 ||
        snapshot.batteryPlugged != 0;
  }

  String _batteryStateText(DeviceSnapshot snapshot) {
    if (snapshot.batteryPlugged != 0) {
      switch (snapshot.batteryPlugged) {
        case 1:
          return tr('充电中 · AC 电源');
        case 2:
          return tr('充电中 · USB');
        case 4:
          return tr('充电中 · 无线');
        default:
          return tr('充电中');
      }
    }
    switch (snapshot.batteryStatus) {
      case 4:
        return tr('已充满');
      case 3:
      case 5:
        return tr('放电中');
      default:
        return tr('未在充电');
    }
  }

  Widget _deviceCard() {
    final theme = Theme.of(context);
    final info = _static;
    if (info == null) return const SizedBox.shrink();
    final fpsText = _fps > 0 ? '≈${_fps.toStringAsFixed(0)} FPS' : tr('测量中');
    final uptimeText = formatUptime(Duration(milliseconds: info.uptimeMs));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${info.manufacturer} ${info.model}',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              trf('内核：{v}', {'v': info.kernel}),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _deviceCol(tr('代号'), info.device),
                _deviceCol(tr('硬件'), info.hardware),
                _deviceCol(tr('SDK'),
                    '${info.sdkInt} · ${trf('安卓 {v}', {'v': info.release})}'),
                _deviceCol(tr('FPS'), fpsText),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              trf('已开机 {t} · 屏幕刷新率 {v} Hz', {
                't': uptimeText,
                'v': info.refreshRate.toStringAsFixed(0),
              }),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceCol(String label, String value) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _ringTile({
    required String label,
    required double value,
    required String detail,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        _Ring(value: value, center: '${(value * 100).toStringAsFixed(0)}%'),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({
    required this.value,
    required this.center,
    this.size = 56,
    this.stroke = 5,
    this.color,
  });

  final double value;
  final String center;
  final double size;
  final double stroke;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clamped = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: clamped,
              strokeWidth: stroke,
              color: color ?? scheme.primary,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          Text(
            center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
