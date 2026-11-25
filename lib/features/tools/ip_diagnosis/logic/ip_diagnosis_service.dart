import 'package:http/http.dart' as http;

import '../data/ip_data_sources.dart';
import '../data/ip_models.dart';
import '../data/network_info_provider.dart';
import '../data/network_quality.dart';
import 'ip_classifier.dart';

/// 诊断阶段（UI 据此显示分阶段进度文案）。
enum DiagnosisPhase { intel, latency, speed, done }

/// 一次诊断只跑其中一部分：IP 检测不测速，网络测速不查 IP 情报。
///
/// 两项都是多次外网请求，合在一起跑既慢又浪费流量；两个详情页各自独立触发。
enum DiagnosisScope { all, ip, speed }

typedef ProgressCallback = void Function(DiagnosisPhase phase);

typedef NetworkInfoLoader = Future<NetworkInfo> Function();
typedef IntelLoader = Future<IpIntelReport> Function();
typedef LatencyLoader = Future<LatencyProbeResult> Function();
typedef TransferLoader = Future<TransferResult> Function();

/// 一次诊断的聚合结果（纯数据，UI 直接消费）。
class DiagnosisResult {
  const DiagnosisResult({
    required this.networkInfo,
    required this.intel,
    required this.classification,
    required this.trust,
    required this.latency,
    required this.downstream,
    required this.upstream,
    required this.latencyTargets,
    required this.diagnosedAt,
    this.downSamples = const <double>[],
    this.upSamples = const <double>[],
    this.scope = DiagnosisScope.all,
  });

  final NetworkInfo networkInfo;
  final IpIntelReport intel;
  final IpClassification classification;
  final TrustAssessment trust;
  final LatencyStats latency;
  final SpeedStats downstream;
  final SpeedStats upstream;
  final List<String> latencyTargets;
  final DateTime diagnosedAt;

  /// 逐次采样速率（Mbps），用于画折线；老的单次测速最多只有 1 个点。
  final List<double> downSamples;
  final List<double> upSamples;

  /// 本次跑了哪一部分（IP 检测 / 测速 / 全部），UI 据此提示数据来源。
  final DiagnosisScope scope;
}

/// 编排：系统信息 + 情报 → 延迟 → 测速 → 分类 / 可信度 / 统计。
///
/// 每一段采集器都可通过构造函数注入，widget 测试可给一份全假数据，
/// 不触发任何真实网络 / socket；单项失败由 [_safe] 兜底，不会整页失败。
class IpDiagnosisService {
  IpDiagnosisService({
    http.Client? client,
    NetworkInfoLoader? networkInfo,
    IntelLoader? intel,
    LatencyLoader? latency,
    TransferLoader? downstream,
    TransferLoader? upstream,
    this.timeout = const Duration(seconds: 8),
    this.speedTimeout = const Duration(seconds: 6),
  }) {
    // 只有在需要默认 HTTP 采集器时才创建 client，便于测试全量注入假数据。
    final needsDefaultHttp =
        intel == null || downstream == null || upstream == null;
    _client = needsDefaultHttp ? (client ?? http.Client()) : client;
    _ownsClient = needsDefaultHttp && client == null;

    final c = _client;
    _networkInfoLoader = networkInfo ?? NetworkInfoProvider().fetch;
    _intelLoader = intel ??
        () => const IpIntelAggregator().collect(c!, timeout: timeout);
    _latencyLoader = latency ?? (() => const LatencyProber().run());
    final SpeedTester? tester = (downstream == null || upstream == null)
        ? SpeedTester(client: c, timeout: speedTimeout)
        : null;
    _tester = tester;
    _downstreamLoader = downstream ?? tester!.downstream;
    _upstreamLoader = upstream ?? tester!.upstream;
  }

  late final http.Client? _client;
  late final bool _ownsClient;
  late final SpeedTester? _tester;
  final Duration timeout;
  final Duration speedTimeout;

  late final NetworkInfoLoader _networkInfoLoader;
  late final IntelLoader _intelLoader;
  late final LatencyLoader _latencyLoader;
  late final TransferLoader _downstreamLoader;
  late final TransferLoader _upstreamLoader;

  void dispose() {
    if (_ownsClient) _client!.close();
  }

  Future<DiagnosisResult> diagnose({
    ProgressCallback? onProgress,
    SpeedSampleCallback? onSpeedSample,
    DiagnosisScope scope = DiagnosisScope.all,
  }) async {
    final wantIntel = scope != DiagnosisScope.speed;
    final wantSpeed = scope != DiagnosisScope.ip;
    // 每次诊断重新绑定回调，避免上一次的订阅把曲线画到新结果里。
    _tester?.onSample = onSpeedSample;
    onProgress?.call(DiagnosisPhase.intel);
    final network = await _safe(
      _networkInfoLoader,
      const NetworkInfo(),
    );
    final intel = wantIntel
        ? await _safe(_intelLoader, IpIntelReport.allFailed())
        : IpIntelReport.allFailed();

    var latencyRaw = const LatencyProbeResult(
      samples: <LatencySample>[],
      targets: <String>[],
    );
    var downRaw = TransferResult.failed('测速节点', '未测速');
    var upRaw = TransferResult.failed('测速节点', '未测速');
    if (wantSpeed) {
      onProgress?.call(DiagnosisPhase.latency);
      latencyRaw = await _safe(
        _latencyLoader,
        const LatencyProbeResult(
          samples: <LatencySample>[],
          targets: <String>[],
        ),
      );

      onProgress?.call(DiagnosisPhase.speed);
      downRaw = await _safe(
        _downstreamLoader,
        TransferResult.failed('测速节点', '未执行'),
      );
      upRaw = await _safe(
        _upstreamLoader,
        TransferResult.failed('测速节点', '未执行'),
      );
    }

    onProgress?.call(DiagnosisPhase.done);

    final classification = classifyExit(
      org: intel.org.value ?? '',
      isp: intel.isp.value ?? '',
      asn: intel.asn.value ?? '',
      ip: intel.publicIp.value ?? '',
      networkType: network.systemAvailable ? network.type : '',
    );
    final trust = assessTrust(
      classification: classification,
      intel: intel,
      network: network,
    );

    return DiagnosisResult(
      networkInfo: network,
      intel: intel,
      classification: classification,
      trust: trust,
      latency: summarizeLatency(latencyRaw),
      downstream: summarizeSpeed(downRaw),
      upstream: summarizeSpeed(upRaw),
      latencyTargets: latencyRaw.targets,
      diagnosedAt: DateTime.now(),
      downSamples: downRaw.mbpsSamples,
      upSamples: upRaw.mbpsSamples,
      scope: scope,
    );
  }

  Future<T> _safe<T>(Future<T> Function() loader, T fallback) async {
    try {
      return await loader();
    } catch (_) {
      return fallback;
    }
  }
}
