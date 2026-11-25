import 'dart:async';

/// IP 诊断的数据结构与解析。
///
/// 只放「数据」，不含 IO 与业务判定，便于单元测试直接构造与断言。

/// 把异常压缩成可展示的短原因（失败项会显示「不可用（原因）」）。
String briefError(Object e) {
  if (e is TimeoutException) return '请求超时';
  final s = e.toString();
  return s.length > 90 ? '${s.substring(0, 90)}…' : s;
}

/// 单项探测结果：值 + 来源 + 失败原因。
///
/// [source] 是技术来源标识（如 `ipip.net`、`MethodChannel`），原样展示不翻译。
class Probe<T> {
  const Probe({this.value, required this.source, this.error});

  final T? value;
  final String source;
  final String? error;

  bool get ok => error == null && value != null;
  bool get failed => error != null;
}

/// 单个情报源解析出的快照。
class IntelSnapshot {
  const IntelSnapshot({
    required this.source,
    required this.ip,
    this.country = '',
    this.region = '',
    this.city = '',
    this.isp = '',
    this.org = '',
    this.asn = '',
    this.timezone = '',
    this.latitude,
    this.longitude,
  });

  final String source;
  final String ip;
  final String country;
  final String region;
  final String city;
  final String isp;
  final String org;
  final String asn;
  final String timezone;
  final double? latitude;
  final double? longitude;

  bool get hasIp => ip.isNotEmpty;

  /// 解析 `https://myip.ipip.net/json` 的返回。
  factory IntelSnapshot.fromIpipJson(Map<String, dynamic> json) {
    final raw = json['data'];
    final data =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final rawLocation = data['location'];
    final parts = rawLocation is List
        ? rawLocation.map((e) => e.toString().trim()).toList()
        : <String>[];
    String part(int i) => i < parts.length ? parts[i] : '';
    // location 形如 [国家, 省, 市, '', 运营商]；运营商取第 3 位之后最后一个非空值。
    var isp = '';
    for (var i = 3; i < parts.length; i++) {
      if (parts[i].isNotEmpty) isp = parts[i];
    }
    return IntelSnapshot(
      source: 'ipip.net',
      ip: (data['ip'] ?? '').toString().trim(),
      country: part(0),
      region: part(1),
      city: part(2),
      isp: isp,
    );
  }

  /// 解析 `https://ipwho.is/` 的返回。
  factory IntelSnapshot.fromIpwhoIs(Map<String, dynamic> json) {
    final rawConn = json['connection'];
    final conn = rawConn is Map
        ? Map<String, dynamic>.from(rawConn)
        : <String, dynamic>{};
    final rawTz = json['timezone'];
    final tzId = rawTz is Map ? (rawTz['id'] ?? '').toString() : '';
    double? numOrNull(Object? v) {
      if (v is num) return v.toDouble();
      return double.tryParse('$v');
    }

    return IntelSnapshot(
      source: 'ipwho.is',
      ip: (json['ip'] ?? '').toString().trim(),
      country: (json['country'] ?? '').toString(),
      region: (json['region'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      isp: (conn['isp'] ?? '').toString(),
      org: (conn['org'] ?? '').toString(),
      asn: (conn['asn'] ?? '').toString(),
      timezone: tzId,
      latitude: numOrNull(json['latitude']),
      longitude: numOrNull(json['longitude']),
    );
  }

  factory IntelSnapshot.fromPlainIp(String source, String ip) =>
      IntelSnapshot(source: source, ip: ip.trim());

  /// 解析 `当前 IP：1.2.3.4  来自于：中国 浙江 杭州  联通`。
  factory IntelSnapshot.fromIpipText(String text) {
    final ipMatch = RegExp(r'当前\s*IP[：:]\s*(\S+)').firstMatch(text);
    final ip = ipMatch?.group(1) ?? '';
    final fromMatch =
        RegExp(r'来自于[：:]\s*(.+)$').firstMatch(text.trim());
    final tail = fromMatch?.group(1)?.trim() ?? '';
    final parts = tail.isEmpty
        ? <String>[]
        : tail.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    String part(int i) => i < parts.length ? parts[i] : '';
    var isp = '';
    for (var i = 3; i < parts.length; i++) {
      if (parts[i].isNotEmpty) isp = parts[i];
    }
    return IntelSnapshot(
      source: 'myip.ipip.net',
      ip: ip,
      country: part(0),
      region: part(1),
      city: part(2),
      isp: isp,
    );
  }
}

/// 多源聚合后的公网情报。每个字段独立带来源，单项失败不影响其它项。
class IpIntelReport {
  const IpIntelReport({
    required this.publicIp,
    required this.country,
    required this.region,
    required this.city,
    required this.isp,
    required this.org,
    required this.asn,
    required this.timezone,
    required this.observedIps,
    required this.succeededSources,
    required this.failedSources,
  });

  final Probe<String> publicIp;
  final Probe<String> country;
  final Probe<String> region;
  final Probe<String> city;
  final Probe<String> isp;
  final Probe<String> org;
  final Probe<String> asn;
  final Probe<String> timezone;

  /// 各源返回的 IP（去重），用于检测多出口 / 代理分流。
  final List<String> observedIps;
  final List<String> succeededSources;
  final List<String> failedSources;

  bool get allSourcesFailed => succeededSources.isEmpty;
  bool get multiExitDetected => observedIps.length > 1;

  /// 全部失败时用于兜底的空报告。
  factory IpIntelReport.allFailed() {
    Probe<String> fail() => const Probe<String>(
          source: '全部情报源',
          error: '未获取到数据',
        );
    return IpIntelReport(
      publicIp: fail(),
      country: fail(),
      region: fail(),
      city: fail(),
      isp: fail(),
      org: fail(),
      asn: fail(),
      timezone: fail(),
      observedIps: const <String>[],
      succeededSources: const <String>[],
      failedSources: const <String>['未执行'],
    );
  }
}

/// 系统网络信息。
class NetworkInfo {
  const NetworkInfo({
    this.type = 'unknown',
    this.typeName = '',
    this.metered,
    this.validated,
    this.downstreamKbps = 0,
    this.upstreamKbps = 0,
    this.dns = const <String>[],
    this.gateway = '',
    this.localAddresses = const <String>[],
    this.interfaceNames = const <String>[],
    this.systemAvailable = false,
  });

  final String type;
  final String typeName;
  final bool? metered;
  final bool? validated;
  final int downstreamKbps;
  final int upstreamKbps;
  final List<String> dns;
  final String gateway;
  final List<String> localAddresses;
  final List<String> interfaceNames;

  /// 原生通道是否返回了有效数据。false 时 UI 明确提示「系统网络信息不可用」。
  final bool systemAvailable;

  factory NetworkInfo.fromMap(Map<String, dynamic> map) {
    String str(String key) {
      final v = map[key];
      return v is String ? v : '';
    }

    // 任何字段类型不符都回退默认值，避免个别机型字段异常导致整页崩溃。
    List<String> strList(String key) {
      final raw = map[key];
      if (raw is! List) return const <String>[];
      return raw
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }

    int intOf(String key) {
      final v = map[key];
      return v is num ? v.toInt() : 0;
    }

    bool? boolOf(String key) {
      final v = map[key];
      return v is bool ? v : null;
    }

    return NetworkInfo(
      type: str('type').isEmpty ? 'unknown' : str('type'),
      typeName: str('typeName'),
      metered: boolOf('metered'),
      validated: boolOf('validated'),
      downstreamKbps: intOf('downstreamKbps'),
      upstreamKbps: intOf('upstreamKbps'),
      dns: strList('dns'),
      gateway: str('gateway'),
      localAddresses: strList('localAddresses'),
      interfaceNames: strList('interfaceNames'),
      systemAvailable: true,
    );
  }
}

/// 单次 TCP 握手采样。
class LatencySample {
  const LatencySample(this.target, this.rttMs, this.ok);

  final String target;
  final double rttMs;
  final bool ok;
}

/// 延迟探测的原始采样（统计在 logic 层做）。
class LatencyProbeResult {
  const LatencyProbeResult({required this.samples, required this.targets});

  final List<LatencySample> samples;
  final List<String> targets;
}

/// 测速方向。
enum SpeedDirection { down, up }

/// 每完成一次测速采样就回调一次，用于画出实时折线。
typedef SpeedSampleCallback = void Function(SpeedDirection direction, double mbps);

/// 单次传输测速结果。
class TransferResult {
  const TransferResult({
    required this.bytes,
    required this.elapsed,
    required this.node,
    this.error,
    this.mbpsSamples = const <double>[],
  });

  final int bytes;
  final Duration elapsed;
  final String node;
  final String? error;

  /// 逐次采样的瞬时速率（Mbps）。老的单次测速为空列表。
  final List<double> mbpsSamples;

  bool get ok => error == null && bytes > 0 && elapsed.inMicroseconds > 0;

  /// bits / µs 恰好等于 Mbit/s，避免两次 1e6 换算相互抵消后写错。
  double get mbps => ok ? bytes * 8.0 / elapsed.inMicroseconds : 0.0;

  factory TransferResult.failed(String node, String error) => TransferResult(
        bytes: 0,
        elapsed: Duration.zero,
        node: node,
        error: error,
      );
}

/// 延迟 / 抖动统计结果。
class LatencyStats {
  const LatencyStats({
    required this.avgMs,
    required this.minMs,
    required this.maxMs,
    required this.jitterMs,
    required this.failureRate,
    required this.attempts,
    required this.successes,
    required this.targets,
  });

  final double? avgMs;
  final double? minMs;
  final double? maxMs;
  final double? jitterMs;
  final double? failureRate;
  final int attempts;
  final int successes;
  final List<String> targets;

  bool get hasData => successes > 0;
}

/// 速率统计结果（十进制 MB/s 与 Mbps）。
class SpeedStats {
  const SpeedStats({
    required this.megabytesPerSec,
    required this.megabitsPerSec,
    required this.node,
    this.error,
  });

  final double? megabytesPerSec;
  final double? megabitsPerSec;
  final String node;
  final String? error;

  bool get ok => error == null && megabitsPerSec != null;
}
