import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'robust_http.dart';

/// 一条诊断结果。
class DiagItem {
  const DiagItem({
    required this.title,
    required this.ok,
    required this.detail,
    this.hint,
  });

  final String title;
  final bool ok;
  final String detail;

  /// 失败时的修复建议。
  final String? hint;

  String get line {
    final mark = ok ? '✓' : '✗';
    final tail = hint == null || hint!.isEmpty ? '' : '\n   → $hint';
    return '$mark $title\n   $detail$tail';
  }
}

/// 逐层网络诊断：IP 直连 → 系统 DNS → 对照域名 → DoH → HTTPS 请求。
///
/// 目的是把「连不上」拆成可定位的环节，而不是只丢一个 SocketException。
class NetDiagnostics {
  NetDiagnostics._();

  static Future<List<DiagItem>> run({required String baseUrl}) async {
    final items = <DiagItem>[];
    final base = baseUrl.trim();
    String host = '';
    try {
      host = Uri.parse(base).host;
    } catch (_) {
      host = '';
    }

    // 1. 纯 IP 直连：绕开 DNS，验证「有没有网 / 有没有联网权限」。
    final ipOk = await _tcpProbe('223.5.5.5', 443);
    items.add(DiagItem(
      title: '基础网络（直连 IP 223.5.5.5:443，不经过 DNS）',
      ok: ipOk.ok,
      detail: ipOk.detail,
      hint: ipOk.ok
          ? null
          : 'IP 都连不上，说明手机没有可用网络，或系统禁止本应用联网'
              '（部分机型在「联网控制 / 流量管理」里单独限制应用联网）。',
    ));

    // 2. 系统 DNS 解析目标域名
    if (host.isEmpty) {
      items.add(const DiagItem(
        title: '系统 DNS 解析',
        ok: false,
        detail: '接口地址里没有解析出域名，请检查 Base URL 填写是否正确',
        hint: 'Base URL 应形如 https://open.bigmodel.cn/api/paas/v4',
      ));
    } else {
      final dns = await _lookup(host);
      items.add(DiagItem(
        title: '系统 DNS 解析 $host',
        ok: dns.ok,
        detail: dns.detail,
        hint: dns.ok
            ? null
            : '系统 DNS 无法解析该域名；若下面「DoH 解析」成功，'
                '应用已可自动兜底访问，无需额外处理。',
      ));
    }

    // 3. 对照域名，区分「整机 DNS 坏了」还是「只有该域名解析不到」
    final control = await _lookup('www.baidu.com');
    items.add(DiagItem(
      title: '对照 DNS 解析 www.baidu.com',
      ok: control.ok,
      detail: control.detail,
      hint: control.ok
          ? null
          : '连常用域名也解析不了，属于整机 DNS/网络问题，建议切换网络或重开飞行模式。',
    ));

    // 4. DoH 兜底解析
    if (host.isNotEmpty) {
      final doh = await DohResolver.resolve(host);
      items.add(DiagItem(
        title: 'DoH 解析（阿里 223.5.5.5）',
        ok: doh.isNotEmpty,
        detail: doh.isEmpty ? '未获取到地址' : doh.join(', '),
        hint: doh.isEmpty
            ? 'DoH 也失败，通常是 IP 层面被拦截或网络不可用。'
            : null,
      ));
    }

    // 5. 实际 HTTPS 请求
    if (host.isNotEmpty) {
      final https = await _httpsProbe(base);
      items.add(DiagItem(
        title: 'HTTPS 请求 $base',
        ok: https.ok,
        detail: https.detail,
        hint: https.ok ? null : 'Base URL 是否正确、平台是否可访问请一并核对。',
      ));
    }

    return items;
  }

  /// 汇总成可复制的文本。
  static String report(List<DiagItem> items) =>
      items.map((i) => i.line).join('\n\n');

  static Future<({bool ok, String detail})> _tcpProbe(
      String host, int port) async {
    final start = DateTime.now();
    try {
      final socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 8));
      final ms = DateTime.now().difference(start).inMilliseconds;
      socket.destroy();
      return (ok: true, detail: '已连接，耗时 $ms ms');
    } on SocketException catch (e) {
      return (ok: false, detail: _describe(e));
    } catch (e) {
      return (ok: false, detail: '$e');
    }
  }

  static Future<({bool ok, String detail})> _lookup(String host) async {
    try {
      final addresses = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 8));
      if (addresses.isEmpty) {
        return (ok: false, detail: '返回 0 个地址（域名无 A/AAAA 记录）');
      }
      return (
        ok: true,
        detail: addresses.map((a) => a.address).join(', '),
      );
    } on SocketException catch (e) {
      return (ok: false, detail: _describe(e));
    } catch (e) {
      return (ok: false, detail: '$e');
    }
  }

  static Future<({bool ok, String detail})> _httpsProbe(String baseUrl) async {
    final client = createRobustHttpClient(
      connectTimeout: const Duration(seconds: 10),
    );
    try {
      final response = await client
          .get(Uri.parse(baseUrl))
          .timeout(const Duration(seconds: 15));
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      final preview = body.length > 120 ? '${body.substring(0, 120)}…' : body;
      return (
        ok: response.statusCode < 500,
        detail: 'HTTP ${response.statusCode}'
            '${preview.isEmpty ? '' : '：$preview'}',
      );
    } on SocketException catch (e) {
      return (ok: false, detail: _describe(e));
    } on TimeoutException {
      return (ok: false, detail: '请求超时（15s）');
    } on http.ClientException catch (e) {
      return (ok: false, detail: e.message);
    } catch (e) {
      return (ok: false, detail: '$e');
    } finally {
      client.close();
    }
  }

  static String _describe(SocketException e) {
    final code = e.osError?.errorCode;
    final message = e.message;
    if (isDnsFailure(e)) return '域名解析失败（errno = $code）：$message';
    if (message.toLowerCase().contains('operation not permitted') || code == 13) {
      return '操作不被允许（errno = $code），通常是应用缺少联网权限';
    }
    if (message.toLowerCase().contains('connection refused')) {
      return '连接被拒绝（errno = $code）';
    }
    if (message.toLowerCase().contains('network is unreachable')) {
      return '网络不可达（errno = $code）';
    }
    return 'errno = $code：$message';
  }
}
