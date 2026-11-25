import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import '../ip_diagnosis/data/ip_models.dart';
import '../ip_diagnosis/logic/ip_classifier.dart';
import '../ip_diagnosis/logic/ip_diagnosis_service.dart';
import 'speed_chart.dart';

/// 网络诊断卡片的页面级状态。
///
/// 监控页每秒 setState 且 ListView 会回收滚出屏幕的 child，状态不能放在卡片
/// 自己的 State 里；由页面持有本控制器，卡片用 [ListenableBuilder] 订阅。
/// [service] 可注入：widget 测试给一份全假采集器，不触发真实网络 / socket。
class IpDiagnosisController extends ChangeNotifier {
  IpDiagnosisController({
    IpDiagnosisService? service,
    this.scope = DiagnosisScope.all,
  })  : _service = service ?? IpDiagnosisService(),
        _ownsService = service == null;

  final IpDiagnosisService _service;
  final bool _ownsService;

  /// 只跑 IP 检测或只做测速：两个详情页各自独立，互不触发对方的请求。
  final DiagnosisScope scope;

  DiagnosisResult? result;
  DiagnosisPhase phase = DiagnosisPhase.intel;
  bool loading = false;
  String? error;

  /// 测速过程中的实时采样点（折线边测边画）；重跑诊断时清空。
  final List<double> liveDown = <double>[];
  final List<double> liveUp = <double>[];

  bool _disposed = false;

  /// 手动触发一次诊断；[loading] 兼作并发守卫，避免重复采集。
  Future<void> run() async {
    if (loading || _disposed) return;
    loading = true;
    error = null;
    phase = DiagnosisPhase.intel;
    liveDown.clear();
    liveUp.clear();
    _notify();
    try {
      final value = await _service.diagnose(
        scope: scope,
        onProgress: (p) {
          phase = p;
          _notify();
        },
        onSpeedSample: (direction, mbps) {
          if (direction == SpeedDirection.down) {
            liveDown.add(mbps);
          } else {
            liveUp.add(mbps);
          }
          _notify();
        },
      );
      result = value;
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_ownsService) _service.dispose();
    super.dispose();
  }
}

/// 详情卡片显示哪一组分区：总览外的两个详情子页各取一半。
enum IpDetailMode { all, ip, speed }

/// 「手机状态监控」中的网络诊断详情卡片：连接概览 / 公网 IP 与属地 / 可信度 /
/// 网络质量四个分区（含上下行多点测速折线），外加数据来源与诊断时间。
///
/// [mode] 让「IP 检测」与「网络测速」两个详情子页各自只显示相关的分区；
/// 默认 [IpDetailMode.all] 是原来的完整视图。总览页只放简要卡片，点进去才
/// 到详情子页。不随页面进入自动跑诊断（含多次外网请求 + 测速，且监控页 1s
/// 刷新），空闲态由按钮触发 [IpDiagnosisController.run]。
class IpDiagnosisCard extends StatelessWidget {
  const IpDiagnosisCard({
    super.key,
    required this.controller,
    this.mode = IpDetailMode.all,
    this.title,
  });

  final IpDiagnosisController controller;
  final IpDetailMode mode;

  /// 详情子页传入，避免与页面标题重复；不传时按 [mode] 取默认标题。
  final String? title;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return SectionCard(
          title: title ?? _defaultTitle(),
          subtitle: _defaultSubtitle(),
          trailing: _trailing(),
          children: _children(context),
        );
      },
    );
  }

  String _defaultTitle() => switch (mode) {
        IpDetailMode.all => tr('网络诊断'),
        IpDetailMode.ip => tr('IP 检测'),
        IpDetailMode.speed => tr('网络测速'),
      };

  String _defaultSubtitle() => switch (mode) {
        IpDetailMode.all => tr('网络状态、IP 属地与质量测速'),
        IpDetailMode.ip => tr('连接状态、公网出口与可信度'),
        IpDetailMode.speed => tr('延迟、抖动与上下行速率'),
      };

  Widget _trailing() {
    final loading = controller.loading;
    return IconButton(
      key: const ValueKey('ip-refresh'),
      tooltip: controller.result == null ? _startLabel() : _againLabel(),
      onPressed: loading ? null : () => controller.run(),
      icon: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
    );
  }

  String _startLabel() => switch (mode) {
        IpDetailMode.ip => tr('开始检测'),
        IpDetailMode.speed => tr('开始测速'),
        IpDetailMode.all => tr('开始诊断'),
      };

  String _againLabel() => switch (mode) {
        IpDetailMode.ip => tr('重新检测'),
        IpDetailMode.speed => tr('重新测速'),
        IpDetailMode.all => tr('重新诊断'),
      };

  List<Widget> _children(BuildContext context) {
    final result = controller.result;
    if (result == null) return _idleChildren(context);

    return <Widget>[
      if (controller.loading) ...<Widget>[
        HintBanner(text: _phaseText(controller.phase)),
        const SizedBox(height: 12),
      ],
      if (mode != IpDetailMode.speed) ...<Widget>[
        ..._sectionTitle(context, '连接概览'),
        ..._overviewRows(result),
        const SizedBox(height: 14),
        const Divider(height: 1),
        const SizedBox(height: 14),
        ..._sectionTitle(context, '公网 IP 与属地'),
        ..._intelRows(result),
        const SizedBox(height: 14),
        const Divider(height: 1),
        const SizedBox(height: 14),
        ..._sectionTitle(
          context,
          '可信度',
          subtitle: '基于公开情报的启发式评估，不是安全结论',
        ),
        ..._trustRows(context, result),
      ],
      if (mode == IpDetailMode.all) ...<Widget>[
        const SizedBox(height: 14),
        const Divider(height: 1),
        const SizedBox(height: 14),
      ],
      if (mode != IpDetailMode.ip) ...<Widget>[
        ..._sectionTitle(
          context,
          '网络质量',
          subtitle: '延迟为 TCP 握手耗时，非 ICMP ping；速率为多次采样平均',
        ),
        ..._qualityRows(result),
        // 诊断中优先画正在采集的实时曲线；还没出第一个点时保留上一次的图，
        // 避免「重新诊断」一开始折线先消失一截。
        if (controller.loading &&
            (controller.liveDown.isNotEmpty || controller.liveUp.isNotEmpty))
          ..._chartRows(controller.liveDown, controller.liveUp)
        else
          ..._chartRows(result.downSamples, result.upSamples),
      ],
      const SizedBox(height: 14),
      SmallHint(
        text: trf(
          result.scope == DiagnosisScope.ip
              ? '数据来源：ipip.net / ipwho.is / 本地系统 · 检测时间 {t}'
              : result.scope == DiagnosisScope.speed
                  ? '数据来源：本地系统 / 测速节点 · 测速时间 {t}'
                  : '数据来源：ipip.net / ipwho.is / 本地系统 / 测速节点 · 诊断时间 {t}',
          {'t': _formatTime(result.diagnosedAt)},
        ),
      ),
    ];
  }

  /// 还没跑过诊断时的空态：按钮触发，不随页面进入自动采集。
  List<Widget> _idleChildren(BuildContext context) {
    final loading = controller.loading;
    final error = controller.error;
    if (loading) {
      return <Widget>[
        Row(
          children: <Widget>[
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(tr('诊断中')),
          ],
        ),
        const SizedBox(height: 10),
        HintBanner(text: _phaseText(controller.phase)),
        if (controller.liveDown.isNotEmpty || controller.liveUp.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          SpeedChart(
            down: controller.liveDown,
            up: controller.liveUp,
          ),
        ],
      ];
    }
    return <Widget>[
      if (error != null) ...<Widget>[
        SmallHint(
          text: tr('加载失败'),
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 4),
        SmallHint(text: tr('请稍后重试')),
        const SizedBox(height: 10),
      ],
      Center(
        child: FilledButton.tonalIcon(
          key: const ValueKey('ip-start'),
          onPressed: () => controller.run(),
          icon: const Icon(Icons.play_arrow, size: 18),
          label: Text(tr(error != null ? '重试' : _startLabel())),
        ),
      ),
    ];
  }

  /// 卡片内分区标题：小号标题 + 可选的一行说明，下面直接跟 StatRow 列表，
  /// 不再用 Card 套 Card。
  List<Widget> _sectionTitle(
    BuildContext context,
    String title, {
    String? subtitle,
  }) {
    return <Widget>[
      Text(tr(title), style: Theme.of(context).textTheme.titleSmall),
      if (subtitle != null) ...<Widget>[
        const SizedBox(height: 2),
        SmallHint(text: tr(subtitle)),
      ],
      const SizedBox(height: 6),
    ];
  }

  /// 折线图区域：没有采样点时不占版面（旧的单次测速数据没有序列）。
  List<Widget> _chartRows(List<double> down, List<double> up) {
    if (down.isEmpty && up.isEmpty) return const <Widget>[];
    return <Widget>[
      const SizedBox(height: 10),
      SpeedChart(down: down, up: up),
    ];
  }

  String _phaseText(DiagnosisPhase phase) => switch (phase) {
        DiagnosisPhase.intel => tr('正在获取 IP 情报…'),
        DiagnosisPhase.latency => tr('正在测延迟…'),
        DiagnosisPhase.speed => tr('正在测速…'),
        DiagnosisPhase.done => tr('诊断完成'),
      };

  String _formatTime(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  /// 统一的结果行：有值显示值，失败显示「不可用（原因）」，
  /// 并把来源标注放在 secondary 里（逐项标注，单项失败不影响其它项）。
  Widget _row(
    String label,
    String? value, {
    String? error,
    String? source,
    String? secondary,
    bool emphasize = false,
  }) {
    final text = value ?? trf('不可用（{r}）', {'r': error ?? tr('获取失败')});
    final parts = <String>[
      if (source != null && source.isNotEmpty)
        trf('来源：{s}', {'s': source}),
      if (secondary != null && secondary.isNotEmpty) secondary,
    ];
    return StatRow(
      label: tr(label),
      value: text,
      secondary: parts.isEmpty ? null : parts.join(' · '),
      emphasize: emphasize,
      // 长 IP / DNS / 情报来源列表允许换行，否则右侧会把标签挤成一个字一行。
      flexibleValue: true,
    );
  }

  List<Widget> _overviewRows(DiagnosisResult r) {
    final n = r.networkInfo;
    final available = n.systemAvailable;
    final source = available ? 'MethodChannel' : 'dart:io';
    final missing = available
        ? tr('数据来源未提供该项')
        : tr('系统网络信息不可用');
    return <Widget>[
      _row(
        '联网状态',
        available
            ? (n.type == 'none' ? tr('未连接') : tr('已连接'))
            : tr('系统网络信息不可用'),
        source: source,
      ),
      _row(
        '网络类型',
        available ? _networkTypeLabel(n) : null,
        error: missing,
        source: source,
      ),
      _row(
        '是否计费',
        available && n.metered != null
            ? (n.metered! ? tr('是') : tr('否'))
            : null,
        error: missing,
        source: source,
      ),
      _row(
        '系统估计下行带宽',
        available && n.downstreamKbps > 0
            ? formatBandwidthKbps(n.downstreamKbps)
            : null,
        error: missing,
        source: source,
      ),
      _row(
        '系统估计上行带宽',
        available && n.upstreamKbps > 0
            ? formatBandwidthKbps(n.upstreamKbps)
            : null,
        error: missing,
        source: source,
      ),
      _row(
        '本机 IP',
        n.localAddresses.isEmpty ? null : n.localAddresses.join('、'),
        error: missing,
        source: source,
      ),
      _row(
        '网关',
        n.gateway.isEmpty ? null : n.gateway,
        error: missing,
        source: source,
      ),
      _row(
        'DNS',
        n.dns.isEmpty ? null : n.dns.join('、'),
        error: missing,
        source: source,
      ),
      _row(
        '接口名',
        n.interfaceNames.isEmpty ? null : n.interfaceNames.join('、'),
        error: missing,
        source: source,
      ),
    ];
  }

  String _networkTypeLabel(NetworkInfo n) {
    final label = switch (n.type) {
      'wifi' => tr('WLAN'),
      'cellular' => tr('移动数据'),
      'ethernet' => tr('以太网'),
      'vpn' => tr('VPN'),
      'none' => tr('无网络'),
      _ => tr('未知'),
    };
    if (n.typeName.isNotEmpty &&
        n.typeName.toLowerCase() != n.type.toLowerCase()) {
      return '$label · ${n.typeName}';
    }
    return label;
  }

  List<Widget> _intelRows(DiagnosisResult r) {
    final intel = r.intel;
    String? value(Probe<String> p) => p.ok ? p.value : null;
    String? source(Probe<String> p) => p.ok ? p.source : null;
    String? reason(Probe<String> p) => p.error;
    return <Widget>[
      if (intel.multiExitDetected) ...<Widget>[
        HintBanner(
          icon: Icons.call_split_outlined,
          text: tr('检测到多出口 / 代理分流，公网 IP 可能不唯一'),
        ),
        const SizedBox(height: 8),
        _row(
          '观测到的 IP',
          intel.observedIps.join('、'),
          source: intel.succeededSources.join('、'),
        ),
      ],
      _row(
        '公网 IP',
        value(intel.publicIp),
        error: reason(intel.publicIp),
        source: source(intel.publicIp),
        emphasize: true,
      ),
      _row('国家', value(intel.country),
          error: reason(intel.country), source: source(intel.country)),
      _row('省份', value(intel.region),
          error: reason(intel.region), source: source(intel.region)),
      _row('城市', value(intel.city),
          error: reason(intel.city), source: source(intel.city)),
      _row('ISP', value(intel.isp),
          error: reason(intel.isp), source: source(intel.isp)),
      _row('组织', value(intel.org),
          error: reason(intel.org), source: source(intel.org)),
      _row('ASN', value(intel.asn),
          error: reason(intel.asn), source: source(intel.asn)),
      _row('时区', value(intel.timezone),
          error: reason(intel.timezone), source: source(intel.timezone)),
      _row(
        '出口类型判定',
        _categoryLabel(r.classification.category),
        secondary: _basisText(r.classification),
      ),
      _row(
        '情报来源',
        intel.allSourcesFailed
            ? tr('全部情报源均失败')
            : intel.succeededSources.join('、'),
      ),
    ];
  }

  String _categoryLabel(IpCategory c) => tr(switch (c) {
        IpCategory.datacenter => '机房 / 云服务商',
        IpCategory.broadband => '家庭 / 企业宽带',
        IpCategory.mobile => '移动网络',
        IpCategory.vpnProxy => 'VPN / 代理 / 匿名',
        IpCategory.unknown => '未知',
      });

  String _basisText(IpClassification c) => c.keywords.isNotEmpty
      ? trf('匹配关键词：{kw}', {'kw': c.keywords.join('、')})
      : tr(c.basis);

  List<Widget> _trustRows(BuildContext context, DiagnosisResult r) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onCard = AppTheme.readableOn(scheme.primary);
    final trust = r.trust;
    final levelLabel = switch (trust.level) {
      TrustLevel.high => tr('高'),
      TrustLevel.medium => tr('中'),
      TrustLevel.low => tr('低'),
    };
    return <Widget>[
      Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              scheme.primary,
              Color.lerp(scheme.primary, Colors.black, 0.2)!,
            ],
          ),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    tr('可信度评分'),
                    style: TextStyle(
                        color: onCard.withOpacity(0.85), fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${trust.score}',
                    style: TextStyle(
                      color: onCard,
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures()
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(' / 100',
                    style: TextStyle(color: onCard.withOpacity(0.7))),
                const SizedBox(height: 8),
                Text(
                  trf('等级：{v}', {'v': levelLabel}),
                  style: TextStyle(
                    color: onCard,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      Text(tr('扣分理由'), style: theme.textTheme.titleSmall),
      const SizedBox(height: 6),
      if (trust.reasons.isEmpty)
        Text(
          tr('未发现明显扣分项'),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        )
      else
        for (final reason in trust.reasons)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.remove_circle_outline,
                    size: 15, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(tr(reason), style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
          ),
    ];
  }

  List<Widget> _qualityRows(DiagnosisResult r) {
    final l = r.latency;
    final down = r.downstream;
    final up = r.upstream;
    return <Widget>[
      _row(
        '平均延迟',
        l.hasData ? formatMs(l.avgMs) : null,
        error: tr('数据来源未提供该项'),
        source: 'Socket.connect',
      ),
      _row('最小延迟', l.hasData ? formatMs(l.minMs) : null,
          error: tr('数据来源未提供该项'), source: 'Socket.connect'),
      _row('最大延迟', l.hasData ? formatMs(l.maxMs) : null,
          error: tr('数据来源未提供该项'), source: 'Socket.connect'),
      _row('抖动', l.hasData ? formatMs(l.jitterMs) : null,
          error: tr('数据来源未提供该项'), source: 'Socket.connect'),
      _row('失败率', l.hasData ? formatPercent(l.failureRate) : null,
          error: tr('数据来源未提供该项'), source: 'Socket.connect'),
      _row(
        '下行速率',
        down.ok ? formatMBs(down.megabytesPerSec) : null,
        error: down.error,
        source: down.node,
        secondary: down.ok ? formatMbps(down.megabitsPerSec) : null,
      ),
      _row(
        '上行速率',
        up.ok ? formatMBs(up.megabytesPerSec) : null,
        error: up.error,
        source: up.node,
        secondary: up.ok ? formatMbps(up.megabitsPerSec) : null,
      ),
      _row(
        '测速节点',
        _nodeLabel(down, up),
        secondary: r.latencyTargets.isEmpty
            ? null
            : r.latencyTargets.join('、'),
      ),
    ];
  }

  String _nodeLabel(SpeedStats down, SpeedStats up) {
    final nodes = <String>{down.node, up.node}
      ..removeWhere((n) => n.isEmpty || n == '测速节点');
    return nodes.isEmpty ? '测速节点' : nodes.join(' / ');
  }
}
