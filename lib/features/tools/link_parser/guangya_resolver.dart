import 'dart:convert';

import 'package:http/http.dart' as http;

import 'share_link.dart';
import 'share_models.dart';

/// 光鸭云盘：摘要取标题 → 提取码换 accessToken → 游标翻页列目录 → 分享取直链。
/// 列目录与取链匿名可用；业务码 207 表示分享者要求登录转存，给出明确提示。
/// 端点、字段、业务码取自 YunX `GuangYaApi` / `GuangYaResolveRepository`。
class GuangYaResolver implements ShareResolver {
  static const String _apiBase = 'https://api.guangyapan.com';
  static const String _summary = '$_apiBase/userres/v1/get_share_summary';
  static const String _accessToken =
      '$_apiBase/userres/v1/get_share_access_token';
  static const String _files =
      '$_apiBase/userres/v1/get_share_page_files_list';
  static const String _download = '$_apiBase/userres/v1/get_share_download_url';
  static const String _webSite = 'https://www.guangyapan.com';
  static const String _referer = '$_webSite/';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const int _pageSize = 100;

  @override
  SharePlatform get platform => SharePlatform.guangya;

  @override
  bool get requiresLogin => false;

  @override
  Future<void> cleanup(
    DownloadLink link, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {}

  Map<String, String> _headers({String? token}) => <String, String>{
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'application/json',
        'User-Agent': _ua,
        'Origin': _webSite,
        'Referer': _referer,
        'dt': '4',
        'traceparent': _traceparent(),
        'did': '0a1b2c3d4e5f60718293a4b5c6d7e8f9',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  static String _traceparent() {
    const hex = '0123456789abcdef';
    String rand(int n) => List<int>.generate(
          n,
          (_) => hex.codeUnitAt(DateTime.now().microsecondsSinceEpoch.remainder(16)),
        ).join();
    return '00-${rand(32)}-${rand(16)}-01';
  }

  static bool _isSuccess(Map<String, dynamic> json) {
    final success = json['success'];
    if (success is bool && !success) return false;
    final error = strOf(json, 'error');
    if (error.isNotEmpty) return false;
    final code = strOf(json, 'code');
    return code.isEmpty || code == '0';
  }

  static void _check(Map<String, dynamic> json, String fallback) {
    if (_isSuccess(json)) return;
    final code = strOf(json, 'code');
    final msg = strOf(json, 'msg').isEmpty
        ? strOf(json, 'message')
        : strOf(json, 'msg');
    final mapped = switch (code) {
      '209' => '提取码错误',
      '200' || '201' || '202' => '分享已失效',
      '205' || '206' || '207' || '504' => '该分享需登录转存后下载',
      '157' => '对方空间不足',
      _ => msg.isEmpty ? fallback : msg,
    };
    throw ShareResolveException(mapped, code: code);
  }

  static Map<String, dynamic> _dataOf(Map<String, dynamic> json) =>
      (json['data'] is Map)
          ? (json['data'] as Map).cast<String, dynamic>()
          : json;

  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> body,
    ShareHttp helper, {
    String? token,
  }) async {
    final response = await helper.post(
      url,
      _headers(token: token),
      jsonEncode(body),
    );
    return helper.jsonOf(response);
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
    final json = await _post(
      _accessToken,
      <String, dynamic>{'shareId': share.shareId, 'code': pwd},
      helper,
    );
    _check(json, '获取分享令牌失败');
    final data = _dataOf(json);
    final token = strOf(data, 'accessToken').isEmpty
        ? strOf(data, 'access_token')
        : strOf(data, 'accessToken');
    if (token.isEmpty) {
      throw const ShareResolveException('分享链接无效或提取码错误');
    }
    String title = '';
    try {
      final summary = await _post(
        _summary,
        <String, dynamic>{'shareId': share.shareId},
        helper,
      );
      if (_isSuccess(summary)) {
        final s = _dataOf(summary);
        title = strOf(s, 'title').isEmpty ? strOf(s, 'shareName') : strOf(s, 'title');
      }
    } catch (_) {
      // 标题拿不到不影响解析。
    }
    return ShareSession(
      platform: platform,
      shareId: share.shareId,
      token: token,
      title: title.isEmpty ? share.shareId : title,
      extra: <String, dynamic>{'pwd': pwd},
    );
  }

  Future<String> _freshToken(ShareSession session, ShareHttp helper) async {
    final pwd = strOf(session.extra, 'pwd');
    final json = await _post(
      _accessToken,
      <String, dynamic>{'shareId': session.shareId, 'code': pwd},
      helper,
    );
    if (!_isSuccess(json)) return session.token;
    final data = _dataOf(json);
    final token = strOf(data, 'accessToken').isEmpty
        ? strOf(data, 'access_token')
        : strOf(data, 'accessToken');
    return token.isEmpty ? session.token : token;
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
    final token = await _freshToken(session, helper);
    final all = <ShareFile>[];
    final seen = <String>{};
    String? cursor;
    for (var page = 0; page < 1000; page++) {
      final body = <String, dynamic>{
        'parentId': dirFid,
        'pageSize': _pageSize,
        'orderBy': 0,
        'sortType': 0,
        'accessToken': token,
        if (cursor != null && cursor.isNotEmpty)
          'cursor': int.tryParse(cursor) ?? cursor,
      };
      final json = await _post(_files, body, helper);
      _check(json, '获取分享文件列表失败');
      final data = _dataOf(json);
      final list = _listOf(data);
      for (final item in list) {
        final file = _fileOf(item);
        if (seen.add(file.fid)) all.add(file);
      }
      final next = strOf(data, 'cursor');
      final hasMore = data.containsKey('hasMore')
          ? boolOf(data, 'hasMore')
          : data.containsKey('total')
              ? (intOf(data, 'total') > 0 &&
                  (int.tryParse(next) ?? list.length) < intOf(data, 'total'))
              : (list.length >= _pageSize && next.isNotEmpty);
      if (!hasMore || next.isEmpty) break;
      cursor = next;
    }
    return all;
  }

  static List<Map<String, dynamic>> _listOf(Map<String, dynamic> data) {
    for (final key in <String>['list', 'items', 'files', 'records', 'content']) {
      final value = data[key];
      if (value is List) {
        return value
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList();
      }
    }
    return const <Map<String, dynamic>>[];
  }

  static String _first(Map<String, dynamic> item, List<String> keys) {
    for (final key in keys) {
      final value = strOf(item, key);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static ShareFile _fileOf(Map<String, dynamic> item) {
    final fid = _first(
        item, <String>['fileId', 'file_id', 'id', 'resId', 'resourceId']);
    final name = _first(item, <String>[
      'fileName',
      'name',
      'filename',
      'dirName',
      'title',
    ]);
    final sizeRaw = _first(item, <String>['fileSize', 'size', 'file_size']);
    final resType = strOf(item, 'resType');
    final isDir = resType == '2'
        ? true
        : resType == '1'
            ? false
            : (boolOf(item, 'isDir') ||
                boolOf(item, 'isdir') ||
                boolOf(item, 'dir') ||
                boolOf(item, 'isFolder') ||
                boolOf(item, 'folder') ||
                strOf(item, 'dirName').isNotEmpty ||
                const <String>['folder', 'dir', 'directory', '0']
                    .contains(strOf(item, 'type').toLowerCase()) ||
                const <String>['folder', 'dir', 'directory', '0']
                    .contains(strOf(item, 'fileType').toLowerCase()));
    return ShareFile(
      fid: fid,
      name: name,
      size: int.tryParse(sizeRaw) ?? 0,
      isDir: isDir,
      pdirFid: _first(item, <String>['parentId', 'parentFileId', 'parent_id']),
      modifiedAt: _first(item, <String>[
        'updatedAt',
        'updateAt',
        'updated_at',
        'updateTime',
        'mtime',
        'utime',
      ]),
    );
  }

  @override
  Future<DownloadLink> downloadLink(
    ShareSession session,
    ShareFile file, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final helper = ShareHttp(client, timeout: timeout);
    final token = await _freshToken(session, helper);
    final json = await _post(
      _download,
      <String, dynamic>{'fileId': file.fid, 'accessToken': token},
      helper,
    );
    _check(json, '获取下载直链失败');
    final data = _dataOf(json);
    final url = _first(data, <String>[
      'signedURL',
      'signedUrl',
      'downloadUrl',
      'download_url',
      'url',
      'cdnUrl',
    ]);
    if (url.isEmpty) throw const ShareResolveException('没拿到下载直链');
    final sizeRaw = strOf(data, 'size');
    return DownloadLink(
      url: url,
      filename: file.name,
      size: int.tryParse(sizeRaw) ?? file.size,
      referer: _referer,
      userAgent: _ua,
    );
  }
}
