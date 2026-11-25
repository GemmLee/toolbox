import 'dart:convert';

import 'package:http/http.dart' as http;

import 'share_link.dart';
import 'share_models.dart';

/// 115 网盘：share/snap 列目录 + share/downurl 取直链。
/// user_id 必须是分享者 UID（从 snap 的 userinfo 取，随 stoken 一起带走）。
/// 端点、字段、UA 要求取自 YunX `Pan115Api` / `Pan115ResolveRepository`。
class Pan115Resolver implements ShareResolver {
  static const String _apiBase = 'https://webapi.115.com';
  static const String _snap = '$_apiBase/share/snap';
  static const String _downurl = '$_apiBase/share/downurl';
  static const String _shareHost = 'https://115cdn.com';
  static const String _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36';
  static String _clientUa = 'Mozilla/5.0 115Browser/36.0.1';
  static const int _pageLimit = 100;

  @override
  SharePlatform get platform => SharePlatform.pan115;

  @override
  bool get requiresLogin => false;

  @override
  Future<void> cleanup(
    DownloadLink link, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {}

  static String _referer(String code, String pwd) => pwd.isEmpty
      ? '$_shareHost/s/$code'
      : '$_shareHost/s/$code?password=$pwd&';

  static (String, String) _decodeToken(String token) {
    final parts = token.split('|');
    return (
      parts.isNotEmpty ? parts[0] : '',
      parts.length > 1 ? parts[1] : '',
    );
  }

  Map<String, String> _headers(String referer, String ua, String cookie) =>
      <String, String>{
        'User-Agent': ua,
        'Accept': 'application/json, text/plain, */*',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': referer,
        if (cookie.isNotEmpty) 'Cookie': cookie,
      };

  static void _checkState(Map<String, dynamic> json, String fallback) {
    if (json['state'] == true || strOf(json, 'state') == 'true') return;
    final errno = intOf(json, 'errno') == 0 ? intOf(json, 'errNo') : intOf(json, 'errno');
    final raw = strOf(json, 'error').isEmpty ? strOf(json, 'msg') : strOf(json, 'error');
    final message = switch (errno) {
      4100012 => '分享需要提取码',
      4100008 => '提取码错误',
      4100026 => '分享已失效',
      50029 => '文件过大，电脑端接口暂不支持，请用 115 官方客户端',
      _ => raw.isEmpty ? fallback : raw,
    };
    throw ShareResolveException(message, code: '$errno');
  }

  Future<Map<String, dynamic>> _get(
    String url,
    String referer,
    String ua,
    String cookie,
    ShareHttp helper,
  ) async {
    final response = await helper.get(url, _headers(referer, ua, cookie));
    return helper.jsonOf(response);
  }

  Future<_Page> _sharePage(
    String shareCode,
    String receiveCode,
    String cid,
    int offset,
    String cookie,
    ShareHttp helper,
  ) async {
    final params = <String, String>{
      'share_code': shareCode,
      'receive_code': receiveCode,
      'offset': '$offset',
      'limit': '$_pageLimit',
      'asc': '0',
      'cid': cid.isEmpty ? '0' : cid,
      'format': 'json',
    };
    final url = '$_snap?${params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
    final json = await _get(url, _referer(shareCode, receiveCode), _webUa, cookie, helper);
    _checkState(json, '获取分享列表失败');
    final data = (json['data'] is Map)
        ? (json['data'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final shareInfo = (data['shareinfo'] is Map)
        ? (data['shareinfo'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final userInfo = (data['userinfo'] is Map)
        ? (data['userinfo'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    return _Page(
      files: _filesOf(data),
      total: intOf(data, 'count'),
      userId: strOf(userInfo, 'user_id'),
      title: strOf(shareInfo, 'share_title'),
    );
  }

  List<ShareFile> _filesOf(Map<String, dynamic> data) {
    final list = listOf(data, 'list');
    final files = <ShareFile>[];
    for (final item in list) {
      final fid = strOf(item, 'fid');
      final fcValue = item['fc'];
      final fc = fcValue is num
          ? fcValue.toInt()
          : int.tryParse(fcValue?.toString() ?? '') ?? (fid.isEmpty ? 0 : 1);
      final isDir = fc == 0;
      final id = isDir ? strOf(item, 'cid') : fid;
      if (id.isEmpty) continue;
      files.add(ShareFile(
        fid: id,
        name: strOf(item, 'n'),
        size: isDir ? 0 : intOf(item, 's'),
        isDir: isDir,
        pdirFid: isDir ? strOf(item, 'pid') : strOf(item, 'cid'),
        modifiedAt: strOf(item, 't'),
      ));
    }
    return files;
  }

  @override
  Future<ShareSession> createSession(
    ParsedShare share, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final helper = ShareHttp(client, timeout: timeout);
    final pwd = share.pwd ?? '';
    final page = await _sharePage(share.shareId, pwd, '0', 0, cookie, helper);
    return ShareSession(
      platform: platform,
      shareId: share.shareId,
      // stoken 带「提取码|分享者UID」，取直链时必须用分享者 UID。
      token: '$pwd|${page.userId}',
      title: page.title.isEmpty ? share.shareId : page.title,
    );
  }

  @override
  Future<List<ShareFile>> listFiles(
    ShareSession session, {
    required String dirFid,
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final helper = ShareHttp(client, timeout: timeout);
    final (pwd, _) = _decodeToken(session.token);
    final all = <ShareFile>[];
    var offset = 0;
    while (true) {
      final page = await _sharePage(
        session.shareId,
        pwd,
        dirFid.isEmpty ? '0' : dirFid,
        offset,
        cookie,
        helper,
      );
      all.addAll(page.files);
      offset += page.files.length;
      final done = page.files.isEmpty ||
          page.files.length < _pageLimit ||
          (page.total > 0 && all.length >= page.total);
      if (done) break;
    }
    return all;
  }

  @override
  Future<DownloadLink> downloadLink(
    ShareSession session,
    ShareFile file, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final (pwd, userId) = _decodeToken(session.token);
    if (userId.isEmpty) {
      throw const ShareResolveException('拿不到分享者标识，请重新解析');
    }
    await _refreshClientVersion(client, timeout);
    final helper = ShareHttp(client, timeout: timeout);
    final params = <String, String>{
      'dl': '1',
      'user_id': userId,
      'share_code': session.shareId,
      'file_id': file.fid,
      if (pwd.isNotEmpty) 'receive_code': pwd,
    };
    final url = '$_downurl?${params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
    final response = await helper.get(
      url,
      _headers(_referer(session.shareId, pwd), _clientUa, cookie),
    );
    final json = helper.jsonOf(response);
    _checkState(json, '获取下载直链失败');
    final data = (json['data'] is Map)
        ? (json['data'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    var fileUrl = strOf(data, 'file_url_302');
    if (fileUrl.isEmpty) fileUrl = strOf(data, 'file_url');
    if (fileUrl.isEmpty) {
      final nested = (data['url'] is Map)
          ? (data['url'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      fileUrl = strOf(nested, 'url');
    }
    if (fileUrl.isEmpty) {
      throw const ShareResolveException('服务端没有返回下载直链');
    }
    final cdnCookie = _downloadCookie(response.headers);
    final name = strOf(data, 'fn').isEmpty ? file.name : strOf(data, 'fn');
    final size = intOf(data, 'fs') == 0 ? file.size : intOf(data, 'fs');
    return DownloadLink(
      url: fileUrl,
      filename: name,
      size: size,
      cookie: cdnCookie,
      referer: _referer(session.shareId, pwd),
      userAgent: _clientUa,
    );
  }

  /// 直链 CDN 只认 path 绑定的那条 Cookie，其余（WAF 的 acw_tc）不是它。
  static String _downloadCookie(Map<String, String> headers) {
    final values = headers['set-cookie'];
    if (values == null) return '';
    String? fallback;
    for (final raw in values.split(',')) {
      final pair = raw.trim().split(';').first.trim();
      if (!pair.contains('=')) continue;
      final name = pair.split('=').first.trim().toLowerCase();
      if (name.isEmpty || const <String>['expires', 'path', 'domain'].contains(name)) {
        continue;
      }
      fallback ??= pair;
      final path = RegExp(r'[;\s]path=([^;]+)', caseSensitive: false)
          .firstMatch(raw)
          ?.group(1)
          ?.trim();
      if (path != null && path.isNotEmpty && path != '/') return pair;
    }
    return fallback ?? '';
  }

  Future<void> _refreshClientVersion(http.Client client, Duration timeout) async {
    try {
      final response = await client
          .get(Uri.parse('https://appversion.115.com/1/web/1.0/api/chrome'))
          .timeout(timeout);
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final data = json['data'];
      if (data is! Map) return;
      final version = strOf(data.cast<String, dynamic>(), 'win');
      final versionMap = data['version'];
      String? code;
      if (versionMap is Map) {
        code = strOf(versionMap.cast<String, dynamic>(), 'version_code');
      }
      final candidate = code ?? version;
      if (candidate.isNotEmpty &&
          candidate.length <= 16 &&
          RegExp(r'^[0-9.]+$').hasMatch(candidate)) {
        _clientUa = 'Mozilla/5.0 115Browser/$candidate';
      }
    } catch (_) {
      // 拉不到版本号就用兜底值。
    }
  }
}

class _Page {
  const _Page({
    required this.files,
    required this.total,
    required this.userId,
    required this.title,
  });

  final List<ShareFile> files;
  final int total;
  final String userId;
  final String title;
}
