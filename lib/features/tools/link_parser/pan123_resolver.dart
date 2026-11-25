import 'dart:convert';

import 'package:http/http.dart' as http;

import 'share_crypto.dart';
import 'share_link.dart';
import 'share_models.dart';

/// 123 云盘：分享列表匿名无签名，取链需登录 + auth-key/auth-value 签名。
/// 端点、签名算法与 token 解码取自 YunX `Pan123Api` / `Pan123Constants`（文档 §5/§6）。
class Pan123Resolver implements ShareResolver {
  static const String _apiBase = 'https://yun.123pan.cn';
  static const String _downloadBase = 'https://www.123865.com';
  static const String _shareGetUrl = '$_apiBase/b/api/share/get';
  static const String _downloadInfoUrl =
      '$_downloadBase/b/api/share/download/info';
  static const String _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36';
  static const String _dartUa = 'Dart/3.12 (dart:io)';
  static const String _downloadReferer = 'https://yun.123pan.cn/';
  static const String _signTable = 'adefghlmyijnopkqrstubcvwsz';

  @override
  SharePlatform get platform => SharePlatform.pan123;

  @override
  bool get requiresLogin => true;

  @override
  Future<void> cleanup(
    DownloadLink link, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {}

  /// 生成签名头，返回 (auth-key, auth-value)。
  /// auth-key = crc32(UTC(ts+57600) 的 YYYYMMDDHHmm 逐数字替换表)；
  /// auth-value = "$ts-$random-crc32(ts|random|path|web|3|authKey)"。
  static Map<String, String> sign(String path, {int? nowSeconds}) {
    final ts = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final utc = DateTime.fromMillisecondsSinceEpoch(
      (ts + 57600) * 1000,
      isUtc: true,
    );
    final minute = '${utc.year.toString().padLeft(4, '0')}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}';
    final substituted = minute.split('').map((c) {
      final digit = c.codeUnitAt(0) - '0'.codeUnitAt(0);
      return digit >= 0 && digit < 10 ? _signTable[digit] : c;
    }).join();
    final authKey = ShareCrypto.crc32Hex(substituted);
    final random = DateTime.now().microsecondsSinceEpoch.remainder(10000000);
    final data = '$ts|$random|$path|web|3|$authKey';
    final authValue = '$ts-$random-${ShareCrypto.crc32Hex(data)}';
    return <String, String>{'auth-key': authKey, 'auth-value': authValue};
  }

  static void _checkOk(Map<String, dynamic> json, String fallback) {
    final code = intOf(json, 'code');
    if (code == 0) return;
    final msg = strOf(json, 'message');
    throw ShareResolveException(msg.isEmpty ? fallback : '$msg（$code）',
        code: '$code');
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
    final files = await _shareFiles(
      helper,
      shareId: share.shareId,
      pwd: pwd,
      parentFileId: '0',
      page: 1,
    );
    final title = files.isEmpty ? '' : files.first.name;
    return ShareSession(
      platform: platform,
      shareId: share.shareId,
      token: pwd,
      title: title.isEmpty ? share.shareId : title,
    );
  }

  Future<List<ShareFile>> _shareFiles(
    ShareHttp helper, {
    required String shareId,
    required String pwd,
    required String parentFileId,
    required int page,
    String next = '0',
  }) async {
    final params = <String, String>{
      'limit': '100',
      'next': next,
      'orderBy': 'file_name',
      'orderDirection': 'asc',
      'shareKey': shareId,
      'ParentFileId': parentFileId,
      'Page': '$page',
      if (pwd.isNotEmpty) 'SharePwd': pwd,
    };
    final url = '$_shareGetUrl?${_query(params)}';
    final response = await helper.get(url, <String, String>{
      'User-Agent': _dartUa,
      'Accept': 'application/json, text/plain, */*',
    });
    final json = helper.jsonOf(response);
    _checkOk(json, '获取分享文件列表失败');
    final data = (json['data'] is Map)
        ? (json['data'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    if (boolOf(data, 'Expired')) {
      throw const ShareResolveException('分享链接已失效');
    }
    return listOf(data, 'InfoList').map(_fileOf).toList();
  }

  static String _query(Map<String, String> params) => params.entries
      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
      .join('&');

  ShareFile _fileOf(Map<String, dynamic> item) => ShareFile(
        fid: strOf(item, 'FileId'),
        name: strOf(item, 'FileName'),
        size: intOf(item, 'Size'),
        isDir: intOf(item, 'Type') == 1,
        pdirFid: strOf(item, 'ParentFileId'),
        // S3KeyFlag|Etag|StorageNode，取链时要拆开。
        fidToken: <String>[
          strOf(item, 'S3KeyFlag'),
          strOf(item, 'Etag'),
          strOf(item, 'StorageNode'),
        ].join('|'),
        modifiedAt: strOf(item, 'UpdateAt'),
      );

  @override
  Future<List<ShareFile>> listFiles(
    ShareSession session, {
    required String dirFid,
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final helper = ShareHttp(client, timeout: timeout);
    final all = <ShareFile>[];
    var page = 1;
    while (page < 50) {
      final batch = await _shareFiles(
        helper,
        shareId: session.shareId,
        pwd: session.token,
        parentFileId: dirFid.isEmpty ? '0' : dirFid,
        page: page,
      );
      all.addAll(batch);
      if (batch.length < 100) break;
      page++;
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
    final token = cookie.trim();
    if (token.isEmpty) {
      throw const ShareResolveException('123 云盘取直链需要登录，请先保存登录凭证');
    }
    final parts = file.fidToken.split('|');
    final s3KeyFlag = parts.isNotEmpty ? parts[0] : '';
    final etag = parts.length > 1 ? parts[1] : '';
    final body = <String, dynamic>{
      'ShareKey': session.shareId,
      'FileID': file.fid,
      'S3KeyFlag': s3KeyFlag,
      'Size': file.size,
      'Etag': etag,
    };
    final helper = ShareHttp(client, timeout: timeout);
    const path = '/b/api/share/download/info';
    final response = await helper.post(
      _downloadInfoUrl,
      <String, String>{
        ...sign(path),
        'platform': 'android',
        'app-version': '39',
        'authorization': 'Bearer $token',
        'Content-Type': 'application/json;charset=UTF-8',
        'User-Agent': _webUa,
        'Accept': 'application/json, text/plain, */*',
      },
      jsonEncode(body),
    );
    final json = helper.jsonOf(response);
    _checkOk(json, '获取下载直链失败');
    final data = (json['data'] is Map)
        ? (json['data'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final raw = strOf(data, 'DownloadURL');
    if (raw.isEmpty) throw const ShareResolveException('服务端没有返回下载直链');
    final url = _decodeDownloadUrl(raw) ?? raw;
    final real = await _followRedirect(url, helper);
    return DownloadLink(
      url: real,
      filename: file.name,
      size: intOf(data, 'Size') == 0 ? file.size : intOf(data, 'Size'),
      referer: _downloadReferer,
      userAgent: _dartUa,
    );
  }

  /// 兼容两种直链形态：整段 base64，或 download-v2?params=<base64 url-safe>。
  static String? _decodeDownloadUrl(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.contains('://')) {
      try {
        final decoded = utf8.decode(base64.decode(trimmed));
        return decoded.toLowerCase().startsWith('http') ? decoded : null;
      } catch (_) {
        return null;
      }
    }
    final idx = trimmed.indexOf('params=');
    if (idx < 0) return null;
    final params = trimmed.substring(idx + 7).split('&').first;
    try {
      final normalized = params.replaceAll('-', '+').replaceAll('_', '/');
      return utf8.decode(base64.decode(normalized));
    } catch (_) {
      return null;
    }
  }

  /// 123 直链带 auto_redirect=0 时返回小 JSON（data.redirect_url），循环跟随最多 5 跳。
  Future<String> _followRedirect(String url, ShareHttp helper) async {
    var current = url;
    for (var i = 0; i < 5; i++) {
      try {
        final response = await helper.get(current, <String, String>{
          'Referer': _downloadReferer,
          'User-Agent': _dartUa,
        });
        final length = int.tryParse(
                response.headers['content-length']?.toString() ?? '') ??
            -1;
        if (length >= 0 && length <= 8192) {
          final body = response.body.trimLeft();
          if (body.startsWith('{')) {
            final json = jsonDecode(body) as Map<String, dynamic>;
            final data = json['data'];
            if (data is Map) {
              final next = strOf(data.cast<String, dynamic>(), 'redirect_url');
              if (next.isNotEmpty) {
                current = next;
                continue;
              }
            }
          }
        }
      } catch (_) {
        // 探测失败就当当前 URL 可用。
      }
      break;
    }
    return current;
  }
}
