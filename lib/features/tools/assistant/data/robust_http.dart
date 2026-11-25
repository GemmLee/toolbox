import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 基于阿里公共 DNS 的 DoH 解析器。
///
/// 直接用 IP 访问 DoH 接口，因此**不依赖系统 DNS**：即使手机 DNS 异常
/// （典型表现 `Failed host lookup ... errno = 7`），也还能拿到域名地址。
class DohResolver {
  DohResolver._();

  /// 阿里 DoH 的 IP 直连地址（证书包含 IP SAN，可正常通过校验）。
  static const List<String> endpoints = <String>[
    'https://223.5.5.5/resolve',
    'https://223.6.6.6/resolve',
  ];

  static final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  /// 解析域名的 A 记录；失败返回空列表（不抛异常）。
  static Future<List<String>> resolve(
    String host, {
    Duration ttl = const Duration(minutes: 5),
  }) async {
    if (host.isEmpty) return const <String>[];
    if (InternetAddress.tryParse(host) != null) return <String>[host];

    final cached = _cache[host];
    if (cached != null && DateTime.now().isBefore(cached.expireAt)) {
      return cached.ips;
    }

    for (final endpoint in endpoints) {
      try {
        final ips = await _query(endpoint, host);
        if (ips.isNotEmpty) {
          _cache[host] = _CacheEntry(ips, DateTime.now().add(ttl));
          return ips;
        }
      } catch (_) {
        // 换下一个 DoH 服务
      }
    }
    return const <String>[];
  }

  static Future<List<String>> _query(String endpoint, String host) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (_) => 'DIRECT';
    try {
      final uri = Uri.parse(
        '$endpoint?name=${Uri.encodeQueryComponent(host)}&type=A',
      );
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final response = await request.close().timeout(const Duration(seconds: 8));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return const <String>[];
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const <String>[];
      final answers = decoded['Answer'];
      final ips = <String>[];
      if (answers is List) {
        for (final answer in answers) {
          if (answer is Map && answer['type'] == 1) {
            final data = answer['data'];
            if (data is String && InternetAddress.tryParse(data) != null) {
              ips.add(data);
            }
          }
        }
      }
      return ips;
    } finally {
      client.close(force: true);
    }
  }
}

class _CacheEntry {
  _CacheEntry(this.ips, this.expireAt);

  final List<String> ips;
  final DateTime expireAt;
}

/// 是否属于「域名解析失败」类错误。
bool isDnsFailure(Object error) {
  if (error is! SocketException) return false;
  final message = error.message.toLowerCase();
  return message.contains('failed host lookup') ||
      message.contains('no address associated') ||
      error.osError?.errorCode == 7;
}

/// 创建带 DNS 兜底的 HTTP 客户端。
///
/// 连接时先走系统解析；若解析失败，改用 [DohResolver] 得到的 IP 直连，
/// 再按原域名完成 TLS 握手（SNI 与证书校验仍针对域名），对调用方透明。
http.Client createRobustHttpClient({
  Duration connectTimeout = const Duration(seconds: 20),
}) {
  final io = HttpClient()
    ..connectionTimeout = connectTimeout
    ..findProxy = (_) => 'DIRECT';

  io.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
    // 配了代理时保持原有行为（CONNECT 隧道由 HttpClient 自己处理）。
    if (proxyHost != null && proxyPort != null) {
      final socket = await Socket.connect(proxyHost, proxyPort,
          timeout: connectTimeout);
      return ConnectionTask.fromSocket(
          Future<Socket>.value(socket), socket.destroy);
    }

    final socket = await _connectWithFallback(uri.host, uri.port, connectTimeout);
    if (uri.scheme == 'https') {
      // connectionFactory 返回的 socket 不会被 HttpClient 再包一层 TLS，
      // 这里必须自己完成安全连接，host 传入域名以保证 SNI 与证书校验正确。
      final secure = await SecureSocket.secure(socket, host: uri.host)
          .timeout(connectTimeout);
      return ConnectionTask.fromSocket(
          Future<Socket>.value(secure), () => secure.destroy());
    }
    return ConnectionTask.fromSocket(
        Future<Socket>.value(socket), socket.destroy);
  };

  return IOClient(io);
}

Future<Socket> _connectWithFallback(
  String host,
  int port,
  Duration timeout,
) async {
  try {
    return await Socket.connect(host, port, timeout: timeout);
  } on SocketException catch (error) {
    if (!isDnsFailure(error)) rethrow;
    final ips = await DohResolver.resolve(host);
    if (ips.isEmpty) rethrow;
    SocketException? lastError;
    for (final ip in ips) {
      try {
        return await Socket.connect(ip, port, timeout: timeout);
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? error;
  }
}
