import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/widgets/app_widgets.dart';
import 'package:toolbox/features/tools/device_status/ip_diagnosis_card.dart';
import 'package:toolbox/features/tools/device_status/network_detail_pages.dart';
import 'package:toolbox/features/tools/device_status/speed_chart.dart';
import 'package:toolbox/features/tools/ip_diagnosis/data/ip_models.dart';
import 'package:toolbox/features/tools/ip_diagnosis/logic/ip_diagnosis_service.dart';
import '../support/test_env.dart';

IpIntelReport _intel({
  bool allFailed = false,
  String longSource = '',
}) {
  if (allFailed) return IpIntelReport.allFailed();
  Probe<String> p(String v, String s) => Probe<String>(value: v, source: s);
  return IpIntelReport(
    publicIp: p('1.2.3.4', 'ipip.net'),
    country: p('中国', 'ipip.net'),
    region: p('浙江', 'ipip.net'),
    city: p('杭州', 'ipip.net'),
    isp: p('中国联通', 'ipip.net'),
    org: p('China Unicom', 'ipwho.is'),
    asn: p('4837', 'ipwho.is'),
    timezone: p('Asia/Shanghai', 'ipwho.is'),
    observedIps: const <String>['1.2.3.4'],
    succeededSources: longSource.isEmpty
        ? const <String>['ipip.net', 'ipwho.is']
        : <String>[longSource],
    failedSources: const <String>[],
  );
}

/// 全假 service：五个采集器都注入，不触发任何真实网络 / socket。
IpDiagnosisService _service({
  bool allIntelFailed = false,
  bool networkUnavailable = false,
  void Function()? onIntel,
  List<double> downSamples = const <double>[],
  List<double> upSamples = const <double>[],
  String longSource = '',
}) {
  return IpDiagnosisService(
    networkInfo: () async => networkUnavailable
        ? const NetworkInfo(systemAvailable: false)
        : NetworkInfo.fromMap(<String, dynamic>{
            'type': 'wifi',
            'typeName': 'WIFI',
            'metered': false,
            'validated': true,
            'downstreamKbps': 50000,
            'upstreamKbps': 10000,
            'dns': <String>['223.5.5.5'],
            'gateway': '192.168.1.1',
            'localAddresses': <String>['192.168.1.5'],
            'interfaceNames': <String>['wlan0'],
          }),
    intel: () async {
      onIntel?.call();
      return _intel(allFailed: allIntelFailed, longSource: longSource);
    },
    latency: () async => const LatencyProbeResult(
      samples: <LatencySample>[
        LatencySample('223.5.5.5:53', 12, true),
        LatencySample('223.5.5.5:53', 18, true),
      ],
      targets: <String>[
        '223.5.5.5:53',
        '119.29.29.29:53',
        'www.baidu.com:443',
      ],
    ),
    downstream: () async => TransferResult(
      bytes: 1000000,
      elapsed: const Duration(seconds: 1),
      node: 'speed.cloudflare.com',
      mbpsSamples: downSamples,
    ),
    upstream: () async => TransferResult(
      bytes: 500000,
      elapsed: const Duration(seconds: 1),
      node: 'speed.cloudflare.com',
      mbpsSamples: upSamples,
    ),
  );
}

/// 把卡片放进 ListView 里，模拟监控页的滚动容器（靠下的分区需要滚动）。
Future<void> _pumpCard(
  WidgetTester tester,
  IpDiagnosisController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: <Widget>[IpDiagnosisCard(controller: controller)],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// ListView 懒加载：把目标滚进视口后再断言，避免下方分区尚未构建。
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.dragUntilVisible(
    finder,
    find.byType(ListView),
    const Offset(0, -300),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  installCleanEnv();

  testWidgets('空闲态显示「开始诊断」且不发网络', (tester) async {
    var calls = 0;
    final controller = IpDiagnosisController(
      service: _service(onIntel: () => calls++),
    );
    await _pumpCard(tester, controller);

    expect(find.text('网络诊断'), findsOneWidget);
    expect(find.text('开始诊断'), findsOneWidget);
    // 不自动跑诊断，避免监控页每秒刷新时反复消耗外网流量。
    expect(calls, 0);
    expect(find.text('连接概览'), findsNothing);
    expect(find.byKey(const ValueKey('ip-refresh')), findsOneWidget);
  });

  testWidgets('点击开始诊断后四个分区标题与公网 IP 都渲染', (tester) async {
    final controller = IpDiagnosisController(service: _service());
    await _pumpCard(tester, controller);

    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();

    expect(find.text('连接概览'), findsOneWidget);
    expect(find.textContaining('数据来源：ipip.net'), findsOneWidget);

    await _scrollTo(tester, find.text('公网 IP 与属地'));
    expect(find.text('公网 IP 与属地'), findsOneWidget);
    await _scrollTo(tester, find.text('1.2.3.4'));
    expect(find.text('1.2.3.4'), findsOneWidget);

    await _scrollTo(tester, find.text('可信度'));
    expect(find.text('可信度'), findsOneWidget);
    await _scrollTo(
      tester,
      find.text('基于公开情报的启发式评估，不是安全结论'),
    );
    expect(
      find.text('基于公开情报的启发式评估，不是安全结论'),
      findsOneWidget,
    );

    await _scrollTo(tester, find.text('网络质量'));
    expect(find.text('网络质量'), findsOneWidget);
    await _scrollTo(
      tester,
      find.text('延迟为 TCP 握手耗时，非 ICMP ping；速率为多次采样平均'),
    );
    expect(
      find.text('延迟为 TCP 握手耗时，非 ICMP ping；速率为多次采样平均'),
      findsOneWidget,
    );
  });

  testWidgets('右上角「重新诊断」可再次采集', (tester) async {
    var calls = 0;
    final controller = IpDiagnosisController(
      service: _service(onIntel: () => calls++),
    );
    await _pumpCard(tester, controller);

    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byTooltip('重新诊断'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ip-refresh')));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('情报全失败 + 系统信息不可用时页面不崩', (tester) async {
    final controller = IpDiagnosisController(
      service: _service(allIntelFailed: true, networkUnavailable: true),
    );
    await _pumpCard(tester, controller);
    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('连接概览'), findsOneWidget);
    expect(find.textContaining('系统网络信息不可用'), findsWidgets);
    expect(find.textContaining('不可用（'), findsWidgets);
    await _scrollTo(tester, find.text('全部情报源均失败'));
    expect(find.text('全部情报源均失败'), findsOneWidget);
  });

  testWidgets('单项采集抛异常时 service 兜底，页面不崩', (tester) async {
    final service = IpDiagnosisService(
      networkInfo: () async => throw StateError('network boom'),
      intel: () async => throw StateError('intel boom'),
      latency: () async => throw StateError('latency boom'),
      downstream: () async => throw StateError('down boom'),
      upstream: () async => throw StateError('up boom'),
    );
    final controller = IpDiagnosisController(service: service);
    await _pumpCard(tester, controller);
    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('连接概览'), findsOneWidget);
    expect(find.textContaining('不可用'), findsWidgets);
    await _scrollTo(tester, find.text('网络质量'));
    expect(find.text('网络质量'), findsOneWidget);
  });

  testWidgets('多点测速结果在网络质量分区画出上下行折线图', (tester) async {
    final controller = IpDiagnosisController(
      service: _service(
        downSamples: const <double>[12, 15, 9, 14, 11],
        upSamples: const <double>[3, 4, 2, 5],
      ),
    );
    await _pumpCard(tester, controller);
    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.byType(SpeedChart));
    expect(find.byType(SpeedChart), findsOneWidget);
    expect(find.text('下行速率'), findsWidgets);
    expect(find.text('上行速率'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单次测速（无采样序列）不画空折线图', (tester) async {
    final controller = IpDiagnosisController(service: _service());
    await _pumpCard(tester, controller);
    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();

    expect(find.byType(SpeedChart), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('超长情报来源不会把左侧标签挤成单字一行', (tester) async {
    final longSource = List<String>.generate(
      6,
      (i) => 'myip.ipip.net.$i.example.com',
    ).join('、');
    final controller = IpDiagnosisController(
      service: _service(longSource: longSource),
    );
    await _pumpCard(tester, controller);
    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('情报来源'));
    final row = find.ancestor(
      of: find.text('情报来源'),
      matching: find.byType(StatRow),
    );
    expect(row, findsOneWidget);
    expect(tester.widget<StatRow>(row).flexibleValue, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('IP 检测详情只发 IP 请求，测速详情只发测速请求', (tester) async {
    var intel = 0;
    var latency = 0;
    var speed = 0;
    IpDiagnosisService build() => IpDiagnosisService(
          networkInfo: () async => const NetworkInfo(),
          intel: () async {
            intel++;
            return _intel();
          },
          latency: () async {
            latency++;
            return const LatencyProbeResult(
              samples: <LatencySample>[LatencySample('a:53', 10, true)],
              targets: <String>['a:53'],
            );
          },
          downstream: () async {
            speed++;
            return TransferResult.failed('n', 'x');
          },
          upstream: () async {
            speed++;
            return TransferResult.failed('n', 'x');
          },
        );

    final ip =
        IpDiagnosisController(service: build(), scope: DiagnosisScope.ip);
    await tester.pumpWidget(MaterialApp(home: IpDetailPage(controller: ip)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ip-start')));
    await tester.pumpAndSettle();
    expect(intel, 1);
    expect(latency, 0, reason: 'IP 检测不测延迟');
    expect(speed, 0, reason: 'IP 检测不测速');
    expect(find.text('公网 IP 与属地'), findsOneWidget);
    expect(find.text('网络质量'), findsNothing);
    ip.dispose();

    final spd =
        IpDiagnosisController(service: build(), scope: DiagnosisScope.speed);
    await tester.pumpWidget(MaterialApp(home: SpeedDetailPage(controller: spd)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ip-start')));
    await tester.pumpAndSettle();
    expect(intel, 1, reason: '测速页不再请求 IP 情报');
    expect(latency, 1);
    expect(speed, 2);
    expect(find.text('网络质量'), findsOneWidget);
    expect(find.text('公网 IP 与属地'), findsNothing);
    spd.dispose();
  });
}
