import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ip_models.dart';

/// TCP 延迟探测目标。
class LatencyTarget {
  const LatencyTarget(this.host, this.port, this.label);

  final String host;
  final int port;
  final String label;
}

const List<LatencyTarget> kDefaultLatencyTargets = <LatencyTarget>[
  LatencyTarget('223.5.5.5', 53, '223.5.5.5:53'),
  LatencyTarget('119.29.29.29', 53, '119.29.29.29:53'),
  LatencyTarget('www.baidu.com', 443, 'www.baidu.com:443'),
];

/// 对固定目标做多次 TCP 连接计时（只是握手耗时，不是 ICMP ping）。
class LatencyProber {
  const LatencyProber({
    this.targets = kDefaultLatencyTargets,
    this.samplesPerTarget = 6,
    this.connectTimeout = const Duration(seconds: 2),
  });

  final List<LatencyTarget> targets;
  final int samplesPerTarget;
  final Duration connectTimeout;

  Future<LatencyProbeResult> run() async {
    final groups = await Future.wait<List<LatencySample>>(
      <Future<List<LatencySample>>>[
        for (final target in targets) _probeTarget(target),
      ],
    );
    return LatencyProbeResult(
      samples: groups.expand((g) => g).toList(growable: false),
      targets: targets.map((t) => t.label).toList(growable: false),
    );
  }

  Future<List<LatencySample>> _probeTarget(LatencyTarget target) async {
    final samples = <LatencySample>[];
    for (var i = 0; i < samplesPerTarget; i++) {
      final sw = Stopwatch()..start();
      try {
        // 只需要握手耗时，连上立即销毁，不读写数据。
        final socket = await Socket.connect(
          target.host,
          target.port,
          timeout: connectTimeout,
        );
        sw.stop();
        socket.destroy();
        samples.add(
          LatencySample(target.label, sw.elapsedMicroseconds / 1000.0, true),
        );
      } catch (_) {
        sw.stop();
        samples.add(LatencySample(target.label, 0, false));
      }
    }
    return samples;
  }
}

const int _downloadBytes = 500000;
const int _uploadBytes = 200000;
const String _downUrl = 'https://speed.cloudflare.com/__down?bytes=500000';
const String _downFallbackUrl =
    'https://mirrors.cloud.tencent.com/flutter/flutter_infra_release/releases/stable/windows/flutter_windows_3.24.3-stable.zip';
const String _upUrl = 'https://speed.cloudflare.com/__up';

/// 下载 / 上传测速：每个方向连续多次采样，逐点回调给折线图。
///
/// 单点太快、抖动太大，用连续 5 次采样画折线更能看出速率变化；最终数值用
/// 总字节 / 总时长（等价于按时间加权的平均速率），不会因某一次尖峰失真。
class SpeedTester {
  SpeedTester({
    http.Client? client,
    this.timeout = const Duration(seconds: 6),
    this.samplesPerDirection = 5,
    this.totalBudget = const Duration(seconds: 18),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  /// 单次请求超时。多点采样时每次都重新计时。
  final Duration timeout;
  final int samplesPerDirection;

  /// 单个方向的总时限，避免弱网下每个采样点都拖满超时。
  final Duration totalBudget;

  /// 每完成一次采样回调一次；由诊断服务在 diagnose 开始时设置。
  SpeedSampleCallback? onSample;

  void dispose() {
    if (_ownsClient) _client.close();
  }

  Future<TransferResult> downstream() => _series(SpeedDirection.down);

  Future<TransferResult> upstream() => _series(SpeedDirection.up);

  Future<TransferResult> _series(SpeedDirection direction) async {
    final samples = <double>[];
    var totalBytes = 0;
    var totalUs = 0;
    var node = '测速节点';
    var consecutiveFailures = 0;
    final budget = Stopwatch()..start();
    for (var i = 0; i < samplesPerDirection; i++) {
      if (budget.elapsed >= totalBudget) break;
      final r = await _once(direction);
      if (!r.ok) {
        // 节点连不上就别把剩下的点全耗在超时上。
        consecutiveFailures++;
        if (consecutiveFailures >= 2) break;
        continue;
      }
      consecutiveFailures = 0;
      node = r.node;
      totalBytes += r.bytes;
      totalUs += r.elapsed.inMicroseconds;
      final mbps = r.mbps;
      samples.add(mbps);
      onSample?.call(direction, mbps);
    }
    if (samples.isEmpty) {
      return TransferResult.failed(node, '全部采样失败');
    }
    return TransferResult(
      bytes: totalBytes,
      elapsed: Duration(microseconds: totalUs),
      node: node,
      mbpsSamples: samples,
    );
  }

  Future<TransferResult> _once(SpeedDirection direction) async {
    try {
      return direction == SpeedDirection.down
          ? await _downloadOnce()
          : await _uploadOnce();
    } catch (e) {
      return TransferResult.failed('测速节点', briefError(e));
    }
  }

  Future<TransferResult> _downloadOnce() async {
    try {
      return await _download(_downUrl, null, 'speed.cloudflare.com');
    } catch (_) {
      // 主节点失败回退腾讯镜像，带 Range 只取前 500000 字节。
      return _download(
        _downFallbackUrl,
        'bytes=0-${_downloadBytes - 1}',
        'mirrors.cloud.tencent.com',
      );
    }
  }

  Future<TransferResult> _download(
    String url,
    String? range,
    String node,
  ) async {
    final sw = Stopwatch()..start();
    final resp = await _client
        .get(
          Uri.parse(url),
          headers: <String, String>{
            if (range != null) 'Range': range,
            'Cache-Control': 'no-cache',
          },
        )
        .timeout(timeout);
    sw.stop();
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw http.ClientException('HTTP ${resp.statusCode}', Uri.parse(url));
    }
    final bytes = resp.bodyBytes.length;
    if (bytes <= 0) throw const FormatException('未收到数据');
    return TransferResult(bytes: bytes, elapsed: sw.elapsed, node: node);
  }

  Future<TransferResult> _uploadOnce() async {
    final payload = Uint8List(_uploadBytes);
    final sw = Stopwatch()..start();
    try {
      final resp = await _client
          .post(
            Uri.parse(_upUrl),
            headers: const <String, String>{
              'Content-Type': 'application/octet-stream',
            },
            body: payload,
          )
          .timeout(timeout);
      sw.stop();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw http.ClientException(
            'HTTP ${resp.statusCode}', Uri.parse(_upUrl));
      }
      return TransferResult(
        bytes: payload.length,
        elapsed: sw.elapsed,
        node: 'speed.cloudflare.com',
      );
    } catch (e) {
      sw.stop();
      return TransferResult.failed('speed.cloudflare.com', briefError(e));
    }
  }
}
