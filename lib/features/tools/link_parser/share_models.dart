import 'dart:convert';

import 'package:http/http.dart' as http;

import 'share_link.dart';

/// 一次分享解析的会话：不同平台把各自的访问凭证放在 [token] / [extra] 里。
class ShareSession {
  const ShareSession({
    required this.platform,
    required this.shareId,
    required this.token,
    this.title = '',
    this.extra = const <String, dynamic>{},
  });

  final SharePlatform platform;
  final String shareId;
  final String token;
  final String title;
  final Map<String, dynamic> extra;
}

/// 分享里的一个文件或目录。
class ShareFile {
  const ShareFile({
    required this.fid,
    required this.name,
    required this.size,
    required this.isDir,
    required this.pdirFid,
    this.fidToken = '',
    this.modifiedAt = '',
  });

  final String fid;
  final String name;
  final int size;
  final bool isDir;
  final String pdirFid;
  final String fidToken;
  final String modifiedAt;
}

/// 服务端返回的下载直链及配套的防盗链请求头。
class DownloadLink {
  const DownloadLink({
    required this.url,
    required this.filename,
    required this.size,
    this.cookie = '',
    this.referer = '',
    this.userAgent = '',
    this.cleanupDirFid = '',
  });

  final String url;
  final String filename;
  final int size;
  final String cookie;
  final String referer;
  final String userAgent;

  /// 夸克转存到临时目录后的目录 fid：下载完成后再清理，避免下载中途失效。
  final String cleanupDirFid;

  Map<String, String> headers() => <String, String>{
        if (cookie.isNotEmpty) 'Cookie': cookie,
        if (referer.isNotEmpty) 'Referer': referer,
        if (userAgent.isNotEmpty) 'User-Agent': userAgent,
      };
}

/// 平台适配器统一接口，对应 YunX 的 `ShareResolveRepository`。
abstract class ShareResolver {
  SharePlatform get platform;

  /// 是否需要登录凭证才能列出文件。
  bool get requiresLogin;

  Future<ShareSession> createSession(
    ParsedShare share, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  });

  Future<List<ShareFile>> listFiles(
    ShareSession session, {
    required String dirFid,
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  });

  Future<DownloadLink> downloadLink(
    ShareSession session,
    ShareFile file, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 20),
  });

  /// 下载完成后的云端临时文件清理；默认什么都不做。
  Future<void> cleanup(
    DownloadLink link, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {}
}

/// 服务端返回业务码时的统一异常，message 直接给用户看。
class ShareResolveException implements Exception {
  const ShareResolveException(this.message, {this.code = ''});

  final String message;
  final String code;

  @override
  String toString() => code.isEmpty ? message : '$message（$code）';
}

/// 各适配器共用的 HTTP / JSON 小工具。
class ShareHttp {
  ShareHttp(this.client, {this.timeout = const Duration(seconds: 15)});

  final http.Client client;
  final Duration timeout;

  Map<String, String> headersWith(
    Map<String, String> base, {
    String? cookie,
    String? contentType,
  }) =>
      <String, String>{
        ...base,
        if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
        if (contentType != null) 'Content-Type': contentType,
      };

  Future<http.Response> get(
    String url,
    Map<String, String> headers,
  ) =>
      client.get(Uri.parse(url), headers: headers).timeout(timeout);

  Future<http.Response> post(
    String url,
    Map<String, String> headers,
    Object body,
  ) =>
      client
          .post(
            Uri.parse(url),
            headers: headers,
            body: body is String ? body : jsonEncode(body),
          )
          .timeout(timeout);

  /// 解析 JSON 并做基础校验：HTTP 4xx / 非 JSON 都给出能看懂的提示。
  Map<String, dynamic> jsonOf(http.Response response) {
    if (response.statusCode >= 400) {
      throw ShareResolveException('请求失败：HTTP ${response.statusCode}');
    }
    try {
      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      if (decoded is! Map) throw const FormatException('响应不是对象');
      return decoded.cast<String, dynamic>();
    } on FormatException {
      throw const ShareResolveException('服务端返回了非预期内容，请稍后重试');
    }
  }

  /// 从响应头里取游客态令牌（夸克 / UC 的 `__pugs`）。
  static String? pugsOf(http.Response response) {
    final values = response.headers['set-cookie'];
    if (values == null) return null;
    for (final raw in values.split(',')) {
      final pair = raw.trim().split(';').first.trim();
      if (pair.startsWith('__pugs=') && pair.length > 7) return pair;
    }
    return null;
  }
}

/// 从 JSON 里安全取字符串 / 整数，避免某个字段类型变化就把整页解析打挂。
String strOf(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return '';
  return value.toString();
}

int intOf(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool boolOf(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  if (value is num) return value != 0;
  return value == '1' || value == 'true';
}

List<Map<String, dynamic>> listOf(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) return const <Map<String, dynamic>>[];
  return value.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
}
