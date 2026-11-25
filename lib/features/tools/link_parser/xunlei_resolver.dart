import 'dart:convert';

import 'package:http/http.dart' as http;

import 'share_link.dart';
import 'share_models.dart';
import 'xunlei_auth.dart';

/// 迅雷网盘：分享列目录匿名可用；登录后走「转存临时目录 → 取详情直链 → 删临时文件」。
///
/// 端点、请求头、字段取自 YunX `XunleiApi` / `XunleiResolveRepository`。
/// 迅雷的鉴权是 Bearer access_token（不是 Cookie），游客态绝不能带空的 Authorization，
/// 否则会被判 unauthenticated。
class XunleiResolver implements ShareResolver {
  XunleiResolver({this.account})
      : _deviceId = account?.device.id ?? _newDeviceId();

  /// 本机登录的迅雷账号；为空时按游客处理（列目录可以，取直链不行）。
  final XunleiAccount? account;

  static const String _panBase = 'https://api-pan.xunlei.com';
  static const String _share = '$_panBase/drive/v1/share';
  static const String _detail = '$_panBase/drive/v1/share/detail';
  static const String _files = '$_panBase/drive/v1/files';
  static const String _tempDirName = '迅雷临时转存';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
  static const String _clientVersion = '8.31.0.9726';

  @override
  SharePlatform get platform => SharePlatform.xunlei;

  @override
  bool get requiresLogin => false;

  final String _deviceId;

  /// 进程内复用：同一账号 + 同一 action 的验证码 300 秒有效。
  final Map<String, _Captcha> _captchas = <String, _Captcha>{};
  XunleiAccount? _live;

  static String _newDeviceId() {
    const hex = '0123456789abcdef';
    final millis = DateTime.now().microsecondsSinceEpoch;
    return List<int>.generate(
      32,
      (i) => hex.codeUnitAt((millis ~/ (i + 1) + i * 7) & 15),
    ).join();
  }

  String get _token => (_live ?? account)?.accessToken ?? '';

  Map<String, String> _headers(String token, {String captcha = ''}) =>
      <String, String>{
        'User-Agent': _ua,
        'X-Device-Id': _deviceId,
        'X-Client-Version': _clientVersion,
        'Content-Type': 'application/json',
        'Origin': 'https://pan.xunlei.com',
        'Referer': 'https://pan.xunlei.com/',
        // 游客模式绝不带空的 Bearer，否则被判 unauthenticated。
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        if (captcha.isNotEmpty) 'X-Captcha-Token': captcha,
      };

  /// 取（或复用）一个 action 对应的验证码；失败返回空串，让请求照常发出。
  Future<String> _captcha(String action, http.Client client) async {
    final current = (_live ?? account);
    if (current == null) return '';
    final cached = _captchas[action];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.value;
    }
    try {
      final auth = XunleiAuth(client: client);
      final value = await auth.initCaptcha(
        device: current.device,
        action: action,
        userId: current.userId,
      );
      _captchas[action] =
          _Captcha(value, DateTime.now().add(const Duration(seconds: 270)));
      return value;
    } catch (_) {
      return '';
    }
  }

  /// 登录态下 token 过期时自动续期一次，写回本机凭证。
  Future<void> _refreshIfNeeded(http.Client client) async {
    final current = _live ?? account;
    if (current == null || current.refreshToken.isEmpty) return;
    final auth = XunleiAuth(client: client);
    final pair =
        await auth.refresh(device: current.device, refreshToken: current.refreshToken);
    if (pair == null) return;
    _live = current.copyWith(
      accessToken: pair.accessToken,
      refreshToken: pair.refreshToken,
    );
  }

  static void _checkShareStatus(Map<String, dynamic> json) {
    switch (strOf(json, 'share_status')) {
      case 'PASS_CODE_EMPTY':
        throw const ShareResolveException('该分享需要提取码');
      case 'PASS_CODE_ERROR':
        throw const ShareResolveException('提取码错误');
      case 'PASS_CODE_NEED':
        throw const ShareResolveException('该分享需要提取码');
    }
  }

  /// 统一读 JSON：HTTP 失败或 `error` 字段有值都翻成能看懂的中文。
  static Map<String, dynamic> _body(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    Map<String, dynamic>? json;
    final start = text.indexOf('{');
    if (start >= 0) {
      try {
        final decoded = jsonDecode(text.substring(start));
        json = decoded is Map ? decoded.cast<String, dynamic>() : null;
      } catch (_) {
        json = null;
      }
    }
    if (json == null) {
      throw ShareResolveException('迅雷返回了非 JSON 内容（HTTP ${response.statusCode}）');
    }
    final error = strOf(json, 'error');
    if (error.isNotEmpty && error != 'success') {
      final desc = strOf(json, 'error_description');
      throw ShareResolveException(
        desc.isEmpty ? '迅雷请求失败：$error' : '迅雷请求失败：$desc',
      );
    }
    final data = json['data'];
    return data is Map ? data.cast<String, dynamic>() : json;
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
    final json = await _getShare(helper, share.shareId, pwd, '', '');
    _checkShareStatus(json);
    final title = strOf(json, 'title');
    return ShareSession(
      platform: platform,
      shareId: share.shareId,
      // stoken 带 pass_code_token，子目录列表与转存要用。
      token: strOf(json, 'pass_code_token'),
      title: title.isEmpty ? share.shareId : title,
      extra: <String, dynamic>{'pwd': pwd},
    );
  }

  Future<Map<String, dynamic>> _getShare(
    ShareHttp helper,
    String shareId,
    String pwd,
    String pageToken,
    String token,
  ) async {
    final params = <String, String>{
      'share_id': shareId,
      'pass_code': pwd,
      'limit': '100',
      'page_token': pageToken,
      'thumbnail_size': 'SIZE_SMALL',
    };
    final url = '$_share?${_query(params)}';
    final response = await helper.get(url, _headers(_token));
    return _body(response);
  }

  Future<Map<String, dynamic>> _getDetail(
    ShareHttp helper,
    String shareId,
    String parentId,
    String passCodeToken,
    String pageToken,
    String token,
  ) async {
    final params = <String, String>{
      'share_id': shareId,
      'parent_id': parentId,
      'pass_code_token': passCodeToken,
      'limit': '100',
      'page_token': pageToken,
      'thumbnail_size': 'SIZE_SMALL',
    };
    final url = '$_detail?${_query(params)}';
    final response = await helper.get(url, _headers(_token));
    return _body(response);
  }

  static String _query(Map<String, String> params) => params.entries
      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
      .join('&');

  static List<ShareFile> _filesOf(Map<String, dynamic> json) {
    final list = listOf(json, 'files');
    return list.map(_fileOf).toList();
  }

  static ShareFile _fileOf(Map<String, dynamic> item) => ShareFile(
        fid: strOf(item, 'id'),
        name: strOf(item, 'name'),
        size: intOf(item, 'size'),
        isDir: strOf(item, 'kind') == 'drive#folder',
        pdirFid: strOf(item, 'parent_id'),
        modifiedAt: strOf(item, 'modified_time'),
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
    final pwd = strOf(session.extra, 'pwd');
    final all = <ShareFile>[];
    var pageToken = '';
    for (var page = 0; page < 100; page++) {
      final Map<String, dynamic> json;
      if (dirFid.isEmpty || dirFid == '0') {
        json = await _getShare(helper, session.shareId, pwd, pageToken, '');
      } else {
        json = await _getDetail(
            helper, session.shareId, dirFid, session.token, pageToken, '');
      }
      _checkShareStatus(json);
      all.addAll(_filesOf(json));
      final next = strOf(json, 'next_page_token');
      if (next.isEmpty) break;
      pageToken = next;
    }
    return all;
  }

  /// 带验证码的 pan 请求：`captcha_invalid` / 401 时换新令牌各重试一次。
  Future<Map<String, dynamic>> _panCall(
    http.Client client,
    Duration timeout,
    String action,
    String url, {
    String? body,
  }) async {
    var captcha = await _captcha(action, client);
    for (var attempt = 0; attempt < 2; attempt++) {
      final http.Response response;
      try {
        response = body == null
            ? await client
                .get(Uri.parse(url), headers: _headers(_token, captcha: captcha))
                .timeout(timeout)
            : await client
                .post(
                  Uri.parse(url),
                  headers: _headers(_token, captcha: captcha),
                  body: body,
                )
                .timeout(timeout);
      } catch (e) {
        throw ShareResolveException('迅雷请求超时（$e）');
      }
      try {
        return _body(response);
      } on ShareResolveException {
        final expired = response.statusCode == 401 ||
            utf8.decode(response.bodyBytes, allowMalformed: true)
                .contains('captcha_invalid');
        if (!expired || attempt > 0) rethrow;
        _captchas.remove(action);
        if (response.statusCode == 401) {
          await _refreshIfNeeded(client);
        } else {
          captcha = await _captcha(action, client);
        }
      }
    }
    throw const ShareResolveException('迅雷验证码刷新失败，请稍后重试');
  }

  /// 确保「迅雷临时转存」目录存在，返回目录 id。
  Future<String> _ensureTempDir(
      http.Client client, Duration timeout) async {
    const url = '$_files?parent_id=&page_token=&limit=100&with_audit=true';
    final root = await _panCall(
        client, timeout, 'GET:/drive/v1/files', url);
    for (final file in _filesOf(root)) {
      if (file.isDir && file.name == _tempDirName) return file.fid;
    }
    final created = await _panCall(
      client,
      timeout,
      'POST:/drive/v1/files',
      _files,
      body: jsonEncode(<String, dynamic>{
        'kind': 'drive#folder',
        'name': _tempDirName,
        'parent_id': '',
        'space': '',
      }),
    );
    final id = strOf(created, 'id');
    if (id.isEmpty) {
      throw const ShareResolveException('迅雷临时目录创建失败（可能是网盘空间不足）');
    }
    return id;
  }

  /// 转存分享里的一个文件，返回转存后的新文件 id。
  Future<String> _restore(
    http.Client client,
    Duration timeout,
    ShareSession session,
    ShareFile file,
    String dirFid,
  ) async {
    final json = await _panCall(
      client,
      timeout,
      'POST:/drive/v1/share/restore',
      '$_panBase/drive/v1/share/restore',
      body: jsonEncode(<String, dynamic>{
        'share_id': session.shareId,
        'pass_code_token': session.token,
        'parent_id': dirFid,
        'ancestor_ids': <String>[],
        'file_ids': <String>[file.fid],
        'specify_parent_id': true,
      }),
    );
    // params.trace_file_ids 是 JSON 字符串：{"分享文件id":"转存后新id"}
    final params = json['params'];
    if (params is Map) {
      final trace = (params['trace_file_ids'] ?? '').toString();
      if (trace.isNotEmpty) {
        try {
          final map = jsonDecode(trace);
          if (map is Map && map[file.fid] != null) {
            final id = map[file.fid].toString();
            if (id.isNotEmpty) return id;
          }
        } catch (_) {}
      }
    }
    final id = strOf(json, 'file_id');
    if (id.isEmpty) {
      throw const ShareResolveException('转存失败（可能是分享已失效或账号已被限流）');
    }
    return id;
  }

  Future<DownloadLink> _fileDetail(
    http.Client client,
    Duration timeout,
    String fid,
  ) async {
    final url = '$_files/$fid?_magic=2021&usage=PLAY'
        '&thumbnail_size=SIZE_LARGE&with=hdr10&with=subtitle_files'
        '&with=task&with=public_share_tag';
    final json = await _panCall(
        client, timeout, 'GET:/drive/v1/files/$fid', url);
    final links = json['links'];
    var link = '';
    if (links is Map) {
      final octet = links['application/octet-stream'];
      if (octet is Map) link = (octet['url'] ?? '').toString();
      if (link.isEmpty) {
        for (final value in links.values) {
          if (value is Map) {
            final url = (value['url'] ?? '').toString();
            if (url.isNotEmpty) {
              link = url;
              break;
            }
          }
        }
      }
    }
    if (link.isEmpty) link = strOf(json, 'web_content_link');
    if (link.isEmpty) {
      throw const ShareResolveException('迅雷没有返回直链，请稍后重试');
    }
    return DownloadLink(
      url: link,
      filename: strOf(json, 'name'),
      size: intOf(json, 'size'),
      userAgent: _ua,
      referer: 'https://pan.xunlei.com/',
      // 直链自带签名，删除临时文件不影响下载；留个标记给 cleanup 用。
      cleanupDirFid: fid,
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
    if (account == null) {
      throw const ShareResolveException(
          '迅雷取直链需要账号登录：先在「网盘登录」里用迅雷账号密码登录');
    }
    if (file.isDir) {
      throw const ShareResolveException('目录不能直接下载，请先打开进入子文件');
    }
    final dirFid = await _ensureTempDir(client, timeout);
    final savedId = await _restore(client, timeout, session, file, dirFid);
    return _fileDetail(client, timeout, savedId);
  }

  /// 删除转存到网盘的临时文件（直链已签名，删掉不影响正在下载的文件）。
  @override
  Future<void> cleanup(
    DownloadLink link, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final fid = link.cleanupDirFid;
    if (fid.isEmpty || account == null) return;
    try {
      await _panCall(
        client,
        timeout,
        'POST:/drive/v1/files:batchDelete',
        '$_files:batchDelete',
        body: jsonEncode(<String, dynamic>{
          'ids': <String>[fid],
          'space': '',
        }),
      );
    } catch (_) {
      // 清理失败不打扰用户：临时文件留在网盘里，下次覆盖前会被忽略。
    }
  }
}

class _Captcha {
  const _Captcha(this.value, this.expiresAt);

  final String value;
  final DateTime expiresAt;
}
