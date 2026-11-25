import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/features/tools/ip_diagnosis/data/ip_data_sources.dart';
import 'package:toolbox/features/tools/ip_diagnosis/data/ip_models.dart';
import 'package:toolbox/features/tools/ip_diagnosis/data/network_info_provider.dart';
import 'package:toolbox/features/tools/ip_diagnosis/data/network_quality.dart';
import 'package:toolbox/features/tools/ip_diagnosis/logic/ip_classifier.dart';
import 'package:toolbox/features/tools/ip_diagnosis/logic/ip_diagnosis_service.dart';

const String _ipipJson =
    '{"ret":"ok","data":{"ip":"1.2.3.4","location":["中国","浙江","杭州","","联通"]}}';
const String _ipwhoJson = '{"ip":"5.6.7.8","success":true,'
    '"country":"China","region":"Zhejiang","city":"Hangzhou",'
    '"latitude":30.27,"longitude":120.15,'
    '"timezone":{"id":"Asia/Shanghai"},'
    '"connection":{"asn":37963,"org":"Alibaba Cloud","isp":"Alibaba","domain":"example.com"}}';

/// 按 URL 分派四个情报源的假响应。
http.Client _intelClient({
  String ipipIp = '1.1.1.1',
  String ipwhoIp = '2.2.2.2',
  bool ipwhoFails = false,
  bool allFail = false,
}) {
  return MockClient((request) async {
    final url = request.url.toString();
    if (allFail) return http.Response('down', 500);
    if (url.startsWith('https://myip.ipip.net/json')) {
      final body = jsonDecode(_ipipJson) as Map<String, dynamic>;
      (body['data'] as Map<String, dynamic>)['ip'] = ipipIp;
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
    }
    if (url.startsWith('https://ipwho.is')) {
      if (ipwhoFails) return http.Response('down', 500);
      final body = jsonDecode(_ipwhoJson) as Map<String, dynamic>;
      body['ip'] = ipwhoIp;
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
    }
    if (url.startsWith('https://icanhazip.com')) {
      return http.Response.bytes(utf8.encode('$ipipIp\n'), 200);
    }
    if (url.startsWith('https://myip.ipip.net')) {
      return http.Response.bytes(
        utf8.encode('当前 IP：$ipipIp  来自于：中国 浙江 杭州  联通'),
        200,
      );
    }
    return http.Response('not found', 404);
  });
}

IpIntelReport _report({
  String ip = '8.8.8.8',
  List<String> observedIps = const <String>['8.8.8.8'],
  String org = 'Google LLC',
  String asn = '15169',
  List<String> succeeded = const <String>['ipip.net', 'ipwho.is'],
}) {
  Probe<String> ok(String v, String s) =>
      Probe<String>(value: v, source: s);
  return IpIntelReport(
    publicIp: ok(ip, 'ipip.net'),
    country: ok('中国', 'ipip.net'),
    region: ok('浙江', 'ipip.net'),
    city: ok('杭州', 'ipip.net'),
    isp: ok('中国联通', 'ipip.net'),
    org: ok(org, 'ipwho.is'),
    asn: ok(asn, 'ipwho.is'),
    timezone: ok('Asia/Shanghai', 'ipwho.is'),
    observedIps: observedIps,
    succeededSources: succeeded,
    failedSources: const <String>[],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('情报 JSON / 文本解析', () {
    test('ipip.net/json：中文属地与运营商', () {
      final snap = IntelSnapshot.fromIpipJson(
        jsonDecode(_ipipJson) as Map<String, dynamic>,
      );
      expect(snap.source, 'ipip.net');
      expect(snap.ip, '1.2.3.4');
      expect(snap.country, '中国');
      expect(snap.region, '浙江');
      expect(snap.city, '杭州');
      expect(snap.isp, '联通');
    });

    test('ipwho.is：ASN / 组织 / 时区 / 经纬度', () {
      final snap = IntelSnapshot.fromIpwhoIs(
        jsonDecode(_ipwhoJson) as Map<String, dynamic>,
      );
      expect(snap.source, 'ipwho.is');
      expect(snap.ip, '5.6.7.8');
      expect(snap.asn, '37963');
      expect(snap.org, 'Alibaba Cloud');
      expect(snap.isp, 'Alibaba');
      expect(snap.timezone, 'Asia/Shanghai');
      expect(snap.latitude, 30.27);
      expect(snap.longitude, 120.15);
    });

    test('纯文本 IP 与 myip.ipip.net 文本', () {
      expect(IntelSnapshot.fromPlainIp('icanhazip.com', ' 9.9.9.9\n').ip,
          '9.9.9.9');
      final snap = IntelSnapshot.fromIpipText(
        '当前 IP：1.2.3.4  来自于：中国 浙江 杭州  联通',
      );
      expect(snap.ip, '1.2.3.4');
      expect(snap.country, '中国');
      expect(snap.region, '浙江');
      expect(snap.city, '杭州');
      expect(snap.isp, '联通');
    });
  });

  group('多源聚合与多出口检测', () {
    test('多源返回不同 IP 时标记多出口，且逐项标注来源', () async {
      final client = _intelClient();
      final report = await const IpIntelAggregator()
          .collect(client, timeout: const Duration(seconds: 3));
      expect(report.succeededSources.length, 4);
      expect(report.observedIps, containsAll(<String>['1.1.1.1', '2.2.2.2']));
      expect(report.multiExitDetected, isTrue);
      expect(report.publicIp.value, '1.1.1.1');
      expect(report.publicIp.source, 'ipip.net');
      expect(report.isp.value, '联通');
      expect(report.asn.value, '37963');
      expect(report.asn.source, 'ipwho.is');
      expect(report.org.value, 'Alibaba Cloud');
    });

    test('单项源失败不影响其它项', () async {
      final client = _intelClient(ipwhoFails: true);
      final report = await const IpIntelAggregator()
          .collect(client, timeout: const Duration(seconds: 3));
      expect(report.allSourcesFailed, isFalse);
      expect(report.publicIp.ok, isTrue);
      expect(report.country.value, '中国');
      // ASN / 组织只有 ipwho.is 提供，该源失败后这两项单独失败。
      expect(report.asn.failed, isTrue);
      expect(report.org.failed, isTrue);
      expect(report.failedSources, isNotEmpty);
    });

    test('全部源失败返回兜底报告，不抛异常', () async {
      final client = _intelClient(allFail: true);
      final report = await const IpIntelAggregator()
          .collect(client, timeout: const Duration(seconds: 3));
      expect(report.allSourcesFailed, isTrue);
      expect(report.publicIp.failed, isTrue);
      expect(report.observedIps, isEmpty);
    });

    test('各源返回同一 IP 时不判多出口', () async {
      final client = _intelClient(ipwhoIp: '1.1.1.1');
      final report = await const IpIntelAggregator()
          .collect(client, timeout: const Duration(seconds: 3));
      expect(report.multiExitDetected, isFalse);
      expect(report.observedIps, <String>['1.1.1.1']);
    });
  });

  group('出口分类', () {
    test('机房 / 云服务商关键词', () {
      final c = classifyExit(
        org: 'Alibaba Cloud',
        isp: '',
        asn: '37963',
        ip: '1.2.3.4',
        networkType: 'wifi',
      );
      expect(c.category, IpCategory.datacenter);
      expect(c.keywords, contains('cloud'));
      expect(c.keywords, contains('alibaba'));
    });

    test('VPN / 代理特征优先', () {
      final c = classifyExit(
        org: 'VPN Provider',
        isp: '',
        asn: '',
        ip: '8.8.8.8',
        networkType: 'vpn',
      );
      expect(c.category, IpCategory.vpnProxy);
      expect(c.keywords, contains('vpn'));
    });

    test('移动网络与家庭宽带', () {
      expect(
        classifyExit(
          org: '',
          isp: 'CMNET',
          asn: '',
          ip: '1.2.3.4',
          networkType: 'cellular',
        ).category,
        IpCategory.mobile,
      );
      expect(
        classifyExit(
          org: '',
          isp: '中国联通',
          asn: '',
          ip: '1.2.3.4',
          networkType: 'wifi',
        ).category,
        IpCategory.broadband,
      );
    });

    test('私有 / 保留地址与信息不足归为未知', () {
      expect(
        classifyExit(
          org: '',
          isp: '',
          asn: '',
          ip: '192.168.1.5',
          networkType: '',
        ).category,
        IpCategory.unknown,
      );
      expect(
        classifyExit(
          org: '',
          isp: '',
          asn: '',
          ip: '8.8.8.8',
          networkType: '',
        ).category,
        IpCategory.unknown,
      );
    });

    test('私有 / 保留地址判定', () {
      expect(isPrivateOrReserved('10.0.0.1'), isTrue);
      expect(isPrivateOrReserved('172.16.5.4'), isTrue);
      expect(isPrivateOrReserved('192.168.1.1'), isTrue);
      expect(isPrivateOrReserved('127.0.0.1'), isTrue);
      expect(isPrivateOrReserved('169.254.1.1'), isTrue);
      expect(isPrivateOrReserved('::1'), isTrue);
      expect(isPrivateOrReserved('8.8.8.8'), isFalse);
      expect(isPrivateOrReserved('1.1.1.1'), isFalse);
    });
  });

  group('可信度评分与扣分理由', () {
    test('无异常特征：满分 / 高 / 无扣分', () {
      final t = assessTrust(
        classification: classifyExit(
          org: 'China Unicom',
          isp: '中国联通',
          asn: '4837',
          ip: '8.8.8.8',
          networkType: 'wifi',
        ),
        intel: _report(),
        network: const NetworkInfo(validated: true),
      );
      expect(t.score, 100);
      expect(t.level, TrustLevel.high);
      expect(t.reasons, isEmpty);
    });

    test('VPN 特征扣 20 分并给出理由', () {
      final t = assessTrust(
        classification: const IpClassification(
          category: IpCategory.vpnProxy,
          keywords: <String>['vpn'],
          basis: '依据 ISP / 组织名称',
        ),
        intel: _report(),
        network: const NetworkInfo(validated: true),
      );
      expect(t.score, 80);
      expect(t.reasons, contains('存在 VPN / 代理特征'));
    });

    test('多重扣分叠加，分数下限 0 且理由齐全', () {
      final t = assessTrust(
        classification: const IpClassification(
          category: IpCategory.datacenter,
          keywords: <String>['cloud'],
          basis: '依据 ISP / 组织名称',
        ),
        intel: _report(
          ip: '10.0.0.1',
          observedIps: const <String>['10.0.0.1', '9.9.9.9'],
          org: '',
          asn: '',
          succeeded: const <String>[],
        ),
        network: const NetworkInfo(validated: false),
      );
      expect(t.score, 0);
      expect(t.level, TrustLevel.low);
      expect(
        t.reasons,
        containsAll(<String>[
          '机房 / 云 / 托管出口',
          '检测到多出口 IP 不一致',
          '公网 IP 为私有 / 保留地址',
          '情报源全部失败',
          '系统报告网络未验证',
          'ASN / 组织信息缺失',
        ]),
      );
    });

    test('等级阈值随扣分变化：75 高 / 65 中 / 0 低', () {
      const datacenter = IpClassification(
        category: IpCategory.datacenter,
        keywords: <String>['cloud'],
        basis: '依据 ISP / 组织名称',
      );
      final high = assessTrust(
        classification: datacenter,
        intel: _report(),
        network: const NetworkInfo(validated: true),
      );
      expect(high.score, 75);
      expect(high.level, TrustLevel.high);

      final medium = assessTrust(
        classification: datacenter,
        intel: _report(),
        network: const NetworkInfo(validated: false),
      );
      expect(medium.score, 65);
      expect(medium.level, TrustLevel.medium);
    });
  });

  group('抖动 / 速率 / 延迟计算与格式化', () {
    test('延迟统计：平均、最小、最大、抖动、失败率', () {
      final stats = summarizeLatency(
        const LatencyProbeResult(
          samples: <LatencySample>[
            LatencySample('a', 10, true),
            LatencySample('a', 20, true),
            LatencySample('a', 30, true),
            LatencySample('a', 0, false),
          ],
          targets: <String>['a'],
        ),
      );
      expect(stats.avgMs, 20);
      expect(stats.minMs, 10);
      expect(stats.maxMs, 30);
      // 相邻差绝对值平均：(10 + 10) / 2
      expect(stats.jitterMs, 10);
      expect(stats.failureRate, 0.25);
      expect(stats.attempts, 4);
      expect(stats.successes, 3);
      expect(stats.hasData, isTrue);
    });

    test('延迟全失败：无数据、失败率 1', () {
      final stats = summarizeLatency(
        const LatencyProbeResult(
          samples: <LatencySample>[LatencySample('a', 0, false)],
          targets: <String>['a'],
        ),
      );
      expect(stats.hasData, isFalse);
      expect(stats.avgMs, isNull);
      expect(stats.failureRate, 1.0);
    });

    test('速率：1,000,000 字节 / 1 秒 = 1 MB/s = 8 Mbps', () {
      final stats = summarizeSpeed(
        const TransferResult(
          bytes: 1000000,
          elapsed: Duration(seconds: 1),
          node: 'speed.cloudflare.com',
        ),
      );
      expect(stats.ok, isTrue);
      expect(stats.megabytesPerSec, 1.0);
      expect(stats.megabitsPerSec, 8.0);
      expect(formatMBs(stats.megabytesPerSec), '1.00 MB/s');
      expect(formatMbps(stats.megabitsPerSec), '8.00 Mbps');
    });

    test('测速失败带原因', () {
      final stats = summarizeSpeed(
        TransferResult.failed('测速节点', '请求超时'),
      );
      expect(stats.ok, isFalse);
      expect(stats.error, '请求超时');
      expect(stats.megabitsPerSec, isNull);
    });

    test('格式化辅助', () {
      expect(formatMs(12.34), '12.3 ms');
      expect(formatPercent(0.25), '25%');
      expect(formatBandwidthKbps(50000), '50.0 Mbps');
      expect(formatBandwidthKbps(0), '--');
      expect(formatMBs(null), '--');
    });
  });

  group('多点测速', () {
    test('瞬时速率换算：bits / µs 就是 Mbps', () {
      const r = TransferResult(
        bytes: 1000000,
        elapsed: Duration(seconds: 1),
        node: 'n',
      );
      expect(r.mbps, 8.0);
      expect(r.mbpsSamples, isEmpty);
    });

    test('下载连续采样：多个采样点 + 逐点回调 + 总字节累加', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return http.Response.bytes(List<int>.filled(1000, 0), 200);
      });
      final points = <double>[];
      final tester = SpeedTester(
        client: client,
        samplesPerDirection: 4,
        timeout: const Duration(seconds: 2),
      )..onSample = (direction, mbps) {
          expect(direction, SpeedDirection.down);
          points.add(mbps);
        };
      final result = await tester.downstream();
      expect(result.ok, isTrue);
      expect(result.bytes, 4000);
      expect(result.mbpsSamples.length, 4);
      expect(result.mbpsSamples, points);
      expect(points.every((v) => v > 0), isTrue);
      tester.dispose();
    });

    test('节点连续失败时提前收手，不会每个点都等超时', () async {
      final client = MockClient((request) async => throw StateError('offline'));
      final tester = SpeedTester(
        client: client,
        samplesPerDirection: 5,
        timeout: const Duration(seconds: 2),
      );
      final result = await tester.downstream();
      expect(result.ok, isFalse);
      expect(result.mbpsSamples, isEmpty);
      expect(result.error, '全部采样失败');
      tester.dispose();
    });

    test('诊断结果把两个方向的采样序列交给折线图', () async {
      final service = IpDiagnosisService(
        networkInfo: () async => const NetworkInfo(),
        intel: () async => IpIntelReport.allFailed(),
        latency: () async => const LatencyProbeResult(
          samples: <LatencySample>[],
          targets: <String>[],
        ),
        downstream: () async => const TransferResult(
          bytes: 1000,
          elapsed: Duration(seconds: 1),
          node: 'n',
          mbpsSamples: <double>[10, 12, 8],
        ),
        upstream: () async => const TransferResult(
          bytes: 500,
          elapsed: Duration(seconds: 1),
          node: 'n',
          mbpsSamples: <double>[2, 3],
        ),
      );
      final result = await service.diagnose();
      expect(result.downSamples, <double>[10, 12, 8]);
      expect(result.upSamples, <double>[2, 3]);
      expect(result.downstream.ok, isTrue);
      service.dispose();
    });
  });

  group('诊断范围', () {
    test('只做 IP 检测时不跑延迟与测速', () async {
      var intelCalls = 0;
      var latencyCalls = 0;
      var speedCalls = 0;
      final service = IpDiagnosisService(
        networkInfo: () async => const NetworkInfo(),
        intel: () async {
          intelCalls++;
          return IpIntelReport.allFailed();
        },
        latency: () async {
          latencyCalls++;
          return const LatencyProbeResult(
            samples: <LatencySample>[],
            targets: <String>[],
          );
        },
        downstream: () async {
          speedCalls++;
          return TransferResult.failed('n', 'x');
        },
        upstream: () async {
          speedCalls++;
          return TransferResult.failed('n', 'x');
        },
      );
      final result = await service.diagnose(scope: DiagnosisScope.ip);
      expect(intelCalls, 1);
      expect(latencyCalls, 0, reason: 'IP 检测不应测延迟');
      expect(speedCalls, 0, reason: 'IP 检测不应测速');
      expect(result.scope, DiagnosisScope.ip);
      expect(result.latency.hasData, isFalse);
      expect(result.downstream.ok, isFalse);
      service.dispose();
    });

    test('只测速时不查 IP 情报', () async {
      var intelCalls = 0;
      var latencyCalls = 0;
      var speedCalls = 0;
      final service = IpDiagnosisService(
        networkInfo: () async => const NetworkInfo(),
        intel: () async {
          intelCalls++;
          return IpIntelReport.allFailed();
        },
        latency: () async {
          latencyCalls++;
          return const LatencyProbeResult(
            samples: <LatencySample>[],
            targets: <String>[],
          );
        },
        downstream: () async {
          speedCalls++;
          return const TransferResult(
            bytes: 1000,
            elapsed: Duration(seconds: 1),
            node: 'n',
            mbpsSamples: <double>[10],
          );
        },
        upstream: () async {
          speedCalls++;
          return const TransferResult(
            bytes: 500,
            elapsed: Duration(seconds: 1),
            node: 'n',
            mbpsSamples: <double>[2],
          );
        },
      );
      final result = await service.diagnose(scope: DiagnosisScope.speed);
      expect(intelCalls, 0, reason: '测速不应请求 IP 情报');
      expect(latencyCalls, 1);
      expect(speedCalls, 2);
      expect(result.scope, DiagnosisScope.speed);
      expect(result.intel.publicIp.ok, isFalse);
      expect(result.downstream.ok, isTrue);
      service.dispose();
    });
  });

  group('系统网络信息解析', () {
    test('fromMap 正常字段', () {
      final info = NetworkInfo.fromMap(<String, dynamic>{
        'type': 'wifi',
        'typeName': 'WIFI',
        'metered': false,
        'validated': true,
        'downstreamKbps': 50000,
        'upstreamKbps': 10000,
        'dns': <String>['223.5.5.5', '119.29.29.29'],
        'gateway': '192.168.1.1',
        'localAddresses': <String>['192.168.1.5', 'fe80::1'],
        'interfaceNames': <String>['wlan0'],
      });
      expect(info.systemAvailable, isTrue);
      expect(info.type, 'wifi');
      expect(info.typeName, 'WIFI');
      expect(info.metered, isFalse);
      expect(info.validated, isTrue);
      expect(info.downstreamKbps, 50000);
      expect(info.upstreamKbps, 10000);
      expect(info.dns.length, 2);
      expect(info.gateway, '192.168.1.1');
      expect(info.localAddresses, contains('192.168.1.5'));
      expect(info.interfaceNames, <String>['wlan0']);
    });

    test('类型异常 / 缺失字段回退默认值，不抛异常', () {
      final info = NetworkInfo.fromMap(<String, dynamic>{
        'type': 123,
        'dns': 'not-a-list',
        'downstreamKbps': 'x',
        'metered': 'yes',
      });
      expect(info.type, 'unknown');
      expect(info.dns, isEmpty);
      expect(info.downstreamKbps, 0);
      expect(info.metered, isNull);
      expect(info.validated, isNull);
    });

    test('provider 可注入假数据', () async {
      final provider = NetworkInfoProvider(
        invoke: () async => <String, dynamic>{
          'type': 'cellular',
          'validated': true,
          'localAddresses': <String>['10.0.0.2'],
        },
      );
      final info = await provider.fetch();
      expect(info.systemAvailable, isTrue);
      expect(info.type, 'cellular');
      expect(info.localAddresses, <String>['10.0.0.2']);
    });

    test('MissingPluginException 优雅回退且不崩', () async {
      final provider = NetworkInfoProvider(
        invoke: () async => throw MissingPluginException('no plugin'),
      );
      final info = await provider.fetch();
      expect(info.systemAvailable, isFalse);
      expect(info.dns, isEmpty);
      expect(info.validated, isNull);
    });
  });
}
