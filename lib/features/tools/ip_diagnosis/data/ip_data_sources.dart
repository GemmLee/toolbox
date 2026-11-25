import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ip_models.dart';

/// 单个公网 IP 情报源。
abstract class IpIntelSource {
  const IpIntelSource(this.id);

  /// 技术来源标识，逐项标注时原样展示。
  final String id;

  Future<IntelSnapshot> fetch(http.Client client, Duration timeout);
}

void _ensureOk(http.Response resp) {
  if (resp.statusCode != 200) {
    throw http.ClientException('HTTP ${resp.statusCode}', resp.request?.url);
  }
}

String _body(http.Response resp) =>
    utf8.decode(resp.bodyBytes, allowMalformed: true);

bool _looksLikeIp(String s) {
  if (s.isEmpty || s.length > 45) return false;
  return RegExp(r'^[0-9a-fA-F:.]+$').hasMatch(s) &&
      (s.contains('.') || s.contains(':'));
}

/// 国内最稳：中文属地 + 运营商。
class IpipJsonSource extends IpIntelSource {
  const IpipJsonSource() : super('ipip.net');

  static const String url = 'https://myip.ipip.net/json';

  @override
  Future<IntelSnapshot> fetch(http.Client client, Duration timeout) async {
    final resp = await client
        .get(Uri.parse(url),
            headers: const <String, String>{'Accept': 'application/json'})
        .timeout(timeout);
    _ensureOk(resp);
    final decoded = jsonDecode(_body(resp));
    if (decoded is! Map) throw const FormatException('返回格式异常');
    final map = Map<String, dynamic>.from(decoded);
    final ret = map['ret'];
    if (ret != null && ret.toString() != 'ok') {
      throw FormatException('接口返回 $ret');
    }
    final snap = IntelSnapshot.fromIpipJson(map);
    if (!snap.hasIp) throw const FormatException('未返回 IP');
    return snap;
  }
}

/// 英文情报：含 ASN / 组织 / 时区 / 经纬度。
class IpwhoIsSource extends IpIntelSource {
  const IpwhoIsSource() : super('ipwho.is');

  static const String url = 'https://ipwho.is/';

  @override
  Future<IntelSnapshot> fetch(http.Client client, Duration timeout) async {
    final resp = await client
        .get(Uri.parse(url),
            headers: const <String, String>{'Accept': 'application/json'})
        .timeout(timeout);
    _ensureOk(resp);
    final decoded = jsonDecode(_body(resp));
    if (decoded is! Map) throw const FormatException('返回格式异常');
    final map = Map<String, dynamic>.from(decoded);
    if (map['success'] == false) {
      throw FormatException('接口提示：${map['message'] ?? '查询失败'}');
    }
    final snap = IntelSnapshot.fromIpwhoIs(map);
    if (!snap.hasIp) throw const FormatException('未返回 IP');
    return snap;
  }
}

/// 纯文本 IP（icanhazip.com）。
class PlainIpSource extends IpIntelSource {
  const PlainIpSource(super.id, this.url);

  final String url;

  @override
  Future<IntelSnapshot> fetch(http.Client client, Duration timeout) async {
    final resp = await client.get(Uri.parse(url)).timeout(timeout);
    _ensureOk(resp);
    final ip = _body(resp).trim();
    if (!_looksLikeIp(ip)) throw const FormatException('返回内容不是 IP');
    return IntelSnapshot.fromPlainIp(id, ip);
  }
}

/// myip.ipip.net 纯文本：`当前 IP：… 来自于：…`。
class IpipTextSource extends IpIntelSource {
  const IpipTextSource() : super('myip.ipip.net');

  static const String url = 'https://myip.ipip.net';

  @override
  Future<IntelSnapshot> fetch(http.Client client, Duration timeout) async {
    final resp = await client.get(Uri.parse(url)).timeout(timeout);
    _ensureOk(resp);
    final snap = IntelSnapshot.fromIpipText(_body(resp));
    if (!snap.hasIp) throw const FormatException('未解析出 IP');
    return snap;
  }
}

class _SourceOutcome {
  const _SourceOutcome(this.source, this.snapshot, this.error);

  final IpIntelSource source;
  final IntelSnapshot? snapshot;
  final String? error;
}

/// 并发请求所有情报源，逐项标注来源，单项失败不影响其它项。
class IpIntelAggregator {
  const IpIntelAggregator({
    this.sources = const <IpIntelSource>[
      IpipJsonSource(),
      IpwhoIsSource(),
      PlainIpSource('icanhazip.com', 'https://icanhazip.com'),
      IpipTextSource(),
    ],
  });

  final List<IpIntelSource> sources;

  Future<IpIntelReport> collect(
    http.Client client, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final outcomes = await Future.wait<_SourceOutcome>(
      <Future<_SourceOutcome>>[
        for (final source in sources) _run(source, client, timeout),
      ],
    );
    final snapshots = <IntelSnapshot>[];
    final succeeded = <String>[];
    final failed = <String>[];
    for (final outcome in outcomes) {
      final snap = outcome.snapshot;
      if (snap != null) {
        snapshots.add(snap);
        if (!succeeded.contains(outcome.source.id)) {
          succeeded.add(outcome.source.id);
        }
      } else {
        failed.add('${outcome.source.id}：${outcome.error ?? '失败'}');
      }
    }
    return _merge(snapshots, succeeded, failed);
  }

  Future<_SourceOutcome> _run(
    IpIntelSource source,
    http.Client client,
    Duration timeout,
  ) async {
    try {
      return _SourceOutcome(source, await source.fetch(client, timeout), null);
    } catch (e) {
      return _SourceOutcome(source, null, briefError(e));
    }
  }

  IpIntelReport _merge(
    List<IntelSnapshot> snapshots,
    List<String> succeeded,
    List<String> failed,
  ) {
    Probe<String> pick(
      String Function(IntelSnapshot snapshot) getter,
      List<String> prefer,
    ) {
      for (final id in prefer) {
        for (final snapshot in snapshots) {
          if (snapshot.source != id) continue;
          final value = getter(snapshot).trim();
          if (value.isNotEmpty) {
            return Probe<String>(value: value, source: id);
          }
        }
      }
      for (final snapshot in snapshots) {
        final value = getter(snapshot).trim();
        if (value.isNotEmpty) {
          return Probe<String>(value: value, source: snapshot.source);
        }
      }
      return const Probe<String>(source: '全部情报源', error: '未提供该字段');
    }

    const ipPrefer = <String>[
      'ipip.net',
      'ipwho.is',
      'icanhazip.com',
      'myip.ipip.net',
    ];
    const geoPrefer = <String>['ipip.net', 'myip.ipip.net', 'ipwho.is'];
    const orgPrefer = <String>['ipwho.is'];

    final observedIps = <String>[];
    for (final snapshot in snapshots) {
      if (snapshot.ip.isNotEmpty && !observedIps.contains(snapshot.ip)) {
        observedIps.add(snapshot.ip);
      }
    }

    return IpIntelReport(
      publicIp: pick((s) => s.ip, ipPrefer),
      country: pick((s) => s.country, geoPrefer),
      region: pick((s) => s.region, geoPrefer),
      city: pick((s) => s.city, geoPrefer),
      isp: pick((s) => s.isp, geoPrefer),
      org: pick((s) => s.org, orgPrefer),
      asn: pick((s) => s.asn, orgPrefer),
      timezone: pick((s) => s.timezone, orgPrefer),
      observedIps: List<String>.unmodifiable(observedIps),
      succeededSources: List<String>.unmodifiable(succeeded),
      failedSources: List<String>.unmodifiable(failed),
    );
  }
}
