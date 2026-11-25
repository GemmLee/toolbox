import 'dart:math' as math;

import '../data/ip_models.dart';

/// 出口类型。
enum IpCategory { datacenter, broadband, mobile, vpnProxy, unknown }

/// 出口分类结果。
class IpClassification {
  const IpClassification({
    required this.category,
    required this.keywords,
    required this.basis,
  });

  final IpCategory category;

  /// 命中的关键词（原样展示，不翻译）。
  final List<String> keywords;

  /// 无关键词时的判定依据（简中原文，UI 用 tr()）。
  final String basis;
}

const List<String> _datacenterKeywords = <String>[
  'cloud', 'alibaba', 'tencent', 'huawei', 'amazon', 'aws', 'azure',
  'google', 'idc', 'datacenter', 'data center', 'hosting',
  '数据中心', '云', '机房', '服务器',
];
const List<String> _vpnKeywords = <String>[
  'vpn', 'proxy', 'tor', 'anonym', '代理',
];
const List<String> _mobileKeywords = <String>[
  'cmnet', 'cmiot', '3g', '4g', '5g', '移动数据',
];
const List<String> _broadbandKeywords = <String>[
  '联通', '电信', '移动', '广电', '长城',
  'china unicom', 'china telecom', 'china mobile',
];

List<String> _match(String haystack, List<String> keywords) =>
    keywords.where((k) => haystack.contains(k)).toList(growable: false);

/// 私有 / 保留 / 环回 / 链路本地 / 组播地址判定。
bool isPrivateOrReserved(String ip) {
  final s = ip.trim().toLowerCase();
  if (s.isEmpty) return false;
  if (s == '::1' ||
      s.startsWith('fc') ||
      s.startsWith('fd') ||
      s.startsWith('fe80')) {
    return true;
  }
  final parts = s.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]) ?? -1;
  final b = int.tryParse(parts[1]) ?? -1;
  if (a == 0 || a == 10 || a == 127) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  if (a == 169 && b == 254) return true;
  if (a >= 224) return true;
  return false;
}

/// 依据 org / isp / asn / 运营商名称 / IP 类型 / 网络类型把出口归类。
///
/// 判定优先级：私有地址 → VPN/代理 → 机房/云 → 移动网络 → 宽带 → 未知。
IpClassification classifyExit({
  required String org,
  required String isp,
  required String asn,
  required String ip,
  required String networkType,
}) {
  if (isPrivateOrReserved(ip)) {
    return const IpClassification(
      category: IpCategory.unknown,
      keywords: <String>[],
      basis: '公网 IP 为私有 / 保留地址',
    );
  }

  final haystack = <String>[org, isp, asn, networkType]
      .where((s) => s.isNotEmpty)
      .join(' ')
      .toLowerCase();

  final vpn = _match(haystack, _vpnKeywords);
  if (vpn.isNotEmpty) {
    return IpClassification(
      category: IpCategory.vpnProxy,
      keywords: vpn,
      basis: '依据 ISP / 组织名称',
    );
  }
  final dc = _match(haystack, _datacenterKeywords);
  if (dc.isNotEmpty) {
    return IpClassification(
      category: IpCategory.datacenter,
      keywords: dc,
      basis: '依据 ISP / 组织名称',
    );
  }
  final mobile = _match(haystack, _mobileKeywords);
  if (mobile.isNotEmpty) {
    return IpClassification(
      category: IpCategory.mobile,
      keywords: mobile,
      basis: '依据 ISP / 组织名称',
    );
  }
  final broadband = _match(haystack, _broadbandKeywords);
  if (broadband.isNotEmpty) {
    return IpClassification(
      category: IpCategory.broadband,
      keywords: broadband,
      basis: '依据 ISP / 组织名称',
    );
  }
  return const IpClassification(
    category: IpCategory.unknown,
    keywords: <String>[],
    basis: '信息不足，无法归类',
  );
}

/// 可信度等级。
enum TrustLevel { high, medium, low }

/// 启发式可信度评估。
class TrustAssessment {
  const TrustAssessment({
    required this.score,
    required this.level,
    required this.reasons,
  });

  /// 0~100。
  final int score;
  final TrustLevel level;

  /// 扣分理由（简中原文，UI 用 tr()）。
  final List<String> reasons;
}

/// 基于公开情报的启发式可信度评估（不是安全结论）。
TrustAssessment assessTrust({
  required IpClassification classification,
  required IpIntelReport intel,
  required NetworkInfo network,
}) {
  var score = 100;
  final reasons = <String>[];
  void deduct(String reason, int points) {
    score -= points;
    reasons.add(reason);
  }

  if (classification.category == IpCategory.datacenter) {
    deduct('机房 / 云 / 托管出口', 25);
  }
  if (classification.category == IpCategory.vpnProxy) {
    deduct('存在 VPN / 代理特征', 20);
  }
  if (intel.multiExitDetected) {
    deduct('检测到多出口 IP 不一致', 20);
  }
  if (isPrivateOrReserved(intel.publicIp.value ?? '')) {
    deduct('公网 IP 为私有 / 保留地址', 25);
  }
  if (intel.allSourcesFailed) {
    deduct('情报源全部失败', 35);
  }
  if (network.validated == false) {
    deduct('系统报告网络未验证', 10);
  }
  if ((intel.org.value ?? '').isEmpty && (intel.asn.value ?? '').isEmpty) {
    deduct('ASN / 组织信息缺失', 8);
  }

  final clamped = score.clamp(0, 100);
  final level = clamped >= 75
      ? TrustLevel.high
      : clamped >= 45
          ? TrustLevel.medium
          : TrustLevel.low;
  return TrustAssessment(
    score: clamped,
    level: level,
    reasons: List<String>.unmodifiable(reasons),
  );
}

/// 由原始 TCP 采样计算平均/最小/最大 RTT、抖动（相邻 RTT 差绝对值平均）
/// 与失败率（近似丢包）。
LatencyStats summarizeLatency(LatencyProbeResult probe) {
  final okSamples = probe.samples
      .where((s) => s.ok)
      .map((s) => s.rttMs)
      .toList(growable: false);
  final attempts = probe.samples.length;
  if (okSamples.isEmpty) {
    return LatencyStats(
      avgMs: null,
      minMs: null,
      maxMs: null,
      jitterMs: null,
      failureRate: attempts == 0 ? null : 1.0,
      attempts: attempts,
      successes: 0,
      targets: probe.targets,
    );
  }
  final sum = okSamples.reduce((a, b) => a + b);
  var jitter = 0.0;
  for (var i = 1; i < okSamples.length; i++) {
    jitter += (okSamples[i] - okSamples[i - 1]).abs();
  }
  if (okSamples.length > 1) jitter /= okSamples.length - 1;
  return LatencyStats(
    avgMs: sum / okSamples.length,
    minMs: okSamples.reduce(math.min),
    maxMs: okSamples.reduce(math.max),
    jitterMs: jitter,
    failureRate: (attempts - okSamples.length) / attempts,
    attempts: attempts,
    successes: okSamples.length,
    targets: probe.targets,
  );
}

/// 由字节数与耗时计算十进制 MB/s 与 Mbps。
SpeedStats summarizeSpeed(TransferResult result) {
  if (!result.ok) {
    return SpeedStats(
      megabytesPerSec: null,
      megabitsPerSec: null,
      node: result.node,
      error: result.error ?? '测速失败',
    );
  }
  final seconds = result.elapsed.inMicroseconds / 1000000.0;
  final bytesPerSec = result.bytes / seconds;
  return SpeedStats(
    megabytesPerSec: bytesPerSec / 1000000.0,
    megabitsPerSec: bytesPerSec * 8 / 1000000.0,
    node: result.node,
  );
}

String formatMbps(double? value) =>
    value == null ? '--' : '${value.toStringAsFixed(2)} Mbps';

String formatMBs(double? value) =>
    value == null ? '--' : '${value.toStringAsFixed(2)} MB/s';

String formatMs(double? value) =>
    value == null ? '--' : '${value.toStringAsFixed(1)} ms';

String formatPercent(double? value) =>
    value == null ? '--' : '${(value * 100).toStringAsFixed(0)}%';

/// 系统估计带宽（Kbps → Mbps）。
String formatBandwidthKbps(int kbps) => kbps <= 0
    ? '--'
    : '${(kbps / 1000).toStringAsFixed(1)} Mbps';
