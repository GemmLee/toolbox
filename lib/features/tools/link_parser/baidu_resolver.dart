import 'package:http/http.dart' as http;

import 'share_link.dart';
import 'share_models.dart';

/// 百度网盘：verify → xpan/share list → transfer → locatedownload。
/// 调用顺序与参数取自 YunX `BaiduApi` / `BaiduResolveRepository`。
class BaiduResolver implements ShareResolver {
  BaiduResolver();

  static const String _appId = '250528';
  static const String _uaWeb =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const String _uaNetdisk =
      'netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0';
  static const String _tempDir = '/XMtools临时转存';

  final Map<String, Map<String, String>> _shareInfos =
      <String, Map<String, String>>{};
  String? _cachedBdstoken;

  @override
  SharePlatform get platform => SharePlatform.baidu;

  @override
  bool get requiresLogin => true;

  Map<String, String> _headers(String ua, String cookie, {String? referer}) =>
      <String, String>{
        'User-Agent': ua,
        if (cookie.isNotEmpty) 'Cookie': cookie,
        if (referer != null) 'Referer': referer,
      };

  void _checkErrno(Map<String, dynamic> json, String fallback) {
    final errno = intOf(json, 'errno');
    if (errno == 0) return;
    final message = strOf(json, 'errmsg');
    throw ShareResolveException(
      message.isEmpty ? fallback : message,
      code: '$errno',
    );
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
    // 公共分享没有提取码：跳过 verify，sekey 留空，列表接口不带该参数。
    if (pwd.isEmpty) {
      return ShareSession(
        platform: platform,
        shareId: share.shareId,
        token: '',
      );
    }
    final response = await helper.post(
      'https://pan.baidu.com/share/verify?surl=${Uri.encodeComponent(share.shareId)}',
      <String, String>{
        ..._headers(_uaWeb, cookie,
            referer: 'https://pan.baidu.com/s/${share.shareId}'),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      'pwd=${Uri.encodeComponent(pwd)}&vcode_str=&vcode=',
    );
    final json = helper.jsonOf(response);
    _checkErrno(json, '提取码验证失败');
    final randsk = strOf(json, 'randsk');
    if (randsk.isEmpty) throw const ShareResolveException('分享没有返回访问凭证');
    return ShareSession(
      platform: platform,
      shareId: share.shareId,
      token: randsk,
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
    final all = <ShareFile>[];
    for (var page = 1; page <= 100; page++) {
      final isRoot = dirFid.isEmpty || dirFid == '/';
      final sekey = session.token;
      final params = <String, String>{
        'method': 'list',
        'shorturl': session.shareId,
        'page': '$page',
        'num': '100',
        'root': isRoot ? '1' : '0',
        'dir': isRoot ? '/' : dirFid,
        if (sekey.isNotEmpty) 'sekey': sekey,
      };
      final url = 'https://pan.baidu.com/rest/2.0/xpan/share?'
          '${params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
      final authCookie = sekey.isNotEmpty && !cookie.contains('BDCLND=')
          ? '$cookie; BDCLND=$sekey'
          : cookie;
      final response = await helper.get(
        url,
        _headers(_uaWeb, authCookie,
            referer: 'https://pan.baidu.com/s/${session.shareId}'),
      );
      final json = helper.jsonOf(response);
      if (intOf(json, 'errno') != 0) {
        final errno = intOf(json, 'errno');
        if (sekey.isEmpty) {
          throw ShareResolveException(
            errno == -6
                ? '分享需要提取码或百度登录态（errno=$errno）'
                : '分享需要提取码（errno=$errno）',
          );
        }
        _checkErrno(json, '获取分享文件列表失败');
      }
      final batch = listOf(json, 'list').map(_fileOf).toList();
      all.addAll(batch);
      _shareInfos[session.shareId] = <String, String>{
        'shareId': strOf(json, 'share_id'),
        'uk': strOf(json, 'uk'),
      };
      if (batch.length < 100) break;
    }
    return all;
  }

  ShareFile _fileOf(Map<String, dynamic> item) {
    final isDir = strOf(item, 'isdir') == '1';
    final path = strOf(item, 'path');
    return ShareFile(
      fid: isDir ? path : strOf(item, 'fs_id'),
      name: strOf(item, 'server_filename'),
      size: intOf(item, 'size'),
      isDir: isDir,
      pdirFid: path,
      modifiedAt: strOf(item, 'server_mtime'),
    );
  }

  Future<String> _bdstoken(String cookie, ShareHttp helper) async {
    final cached = _cachedBdstoken;
    if (cached != null && cached.isNotEmpty) return cached;
    const url = 'https://pan.baidu.com/api/gettemplatevariable'
        '?clienttype=0&app_id=$_appId&web=1'
        '&fields=%5B%22bdstoken%22%5D';
    final response = await helper.get(url, _headers(_uaWeb, cookie));
    final json = helper.jsonOf(response);
    if (intOf(json, 'errno') != 0) {
      throw const ShareResolveException('百度登录态已失效，请重新登录');
    }
    final result = (json['result'] is Map)
        ? (json['result'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final token = strOf(result, 'bdstoken');
    if (token.isEmpty) throw const ShareResolveException('取不到 bdstoken');
    _cachedBdstoken = token;
    return token;
  }

  Future<Map<String, String>> _shareInfo(
    ShareSession session,
    String cookie,
    ShareHttp helper,
  ) async {
    final cached = _shareInfos[session.shareId];
    if (cached != null) return cached;
    await listFiles(session,
        dirFid: '/', cookie: cookie, client: helper.client);
    return _shareInfos[session.shareId] ?? const <String, String>{};
  }

  Future<String> _ensureTempDir(
      String cookie, String token, ShareHttp helper) async {
    const url = 'https://pan.baidu.com/rest/2.0/xpan/file?method=list'
        '&dir=/&start=0&limit=100&web=1&app_id=$_appId';
    try {
      final response = await helper.get(url, _headers(_uaWeb, cookie));
      final json = helper.jsonOf(response);
      for (final item in listOf(json, 'list')) {
        if (strOf(item, 'path') == _tempDir) return _tempDir;
      }
    } catch (_) {
      // 列目录失败就走创建分支，失败再回退根目录。
    }
    final body = 'path=${Uri.encodeComponent(_tempDir)}&isdir=1&size'
        '&block_list=%5B%5D&method=post&dataType=json';
    try {
      final response = await helper.post(
        'https://pan.baidu.com/api/create?a=commit&channel=chunlei&web=1'
        '&app_id=$_appId&clienttype=0&bdstoken=$token',
        <String, String>{
          ..._headers(_uaNetdisk, cookie,
              referer: 'https://yun.baidu.com/disk/main'),
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        },
        body,
      );
      final json = helper.jsonOf(response);
      if (intOf(json, 'errno') == 0) return _tempDir;
    } catch (_) {}
    return '/';
  }

  Future<Map<String, String>> _transfer(
    ShareSession session,
    ShareFile file,
    String toDir,
    String cookie,
    ShareHttp helper,
  ) async {
    final info = await _shareInfo(session, cookie, helper);
    final token = await _bdstoken(cookie, helper);
    final sekey = session.token;
    final url = 'https://pan.baidu.com/share/transfer'
        '?shareid=${info['shareId'] ?? ''}&from=${info['uk'] ?? ''}'
        '&channel=chunlei&sekey=${Uri.encodeComponent(sekey)}'
        '&ondup=newcopy&web=1&app_id=$_appId'
        '&bdstoken=$token&clienttype=0';
    final body = 'fsidlist=${Uri.encodeComponent('["${file.fid}"]')}'
        '&path=${Uri.encodeComponent(toDir)}';
    final authCookie =
        cookie.contains('BDCLND=') ? cookie : '$cookie; BDCLND=$sekey';
    final response = await helper.post(
      url,
      <String, String>{
        ..._headers(_uaWeb, authCookie, referer: 'https://pan.baidu.com/s/'),
        'Origin': 'https://pan.baidu.com',
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      },
      body,
    );
    final json = helper.jsonOf(response);
    _checkErrno(json, '转存分享文件失败');
    final extra = (json['extra'] is Map)
        ? (json['extra'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final list = listOf(extra, 'list');
    if (list.isEmpty) throw const ShareResolveException('转存结果里没有文件');
    return <String, String>{
      'fsId': strOf(list.first, 'to_fs_id'),
      'path':
          strOf(list.first, 'to').isEmpty ? '$toDir/' : strOf(list.first, 'to'),
    };
  }

  Future<String> _locateDownload(
      String path, String cookie, ShareHttp helper) async {
    final params = <String, String>{
      'method': 'locatedownload',
      'app_id': _appId,
      'clienttype': '17',
      'ver': '4.0',
      'ant': '1',
      'check_blue': '1',
      'es': '1',
      'esl': '1',
      'apn_id': '1_-1',
      'freeisp': '0',
      'queryfree': '0',
      'use': '1',
      'dtype': '1',
      'eck': '1',
      'ehps': '1',
      'err_ver': '1.0',
      'network_type': 'WIFI',
      'channel': '0',
      'path': path,
      'time': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'rand': '5ed606e9da222cde0474cdf70eda884b',
      'devuid': '0F1E9FC2E084472DA5A61C4CF4C759AF',
      'cuid': '0F1E9FC2E084472DA5A61C4CF4C759AF',
      'deviceid': '348642637967375013',
      'psign': '860a071f77c860e8cea06e4e54c518f3',
      'version': '2.2.111.34',
      'version_app': '12.24.6',
      'vip': '0',
    };
    final url = 'https://d.pcs.baidu.com/rest/2.0/pcs/file?'
        '${params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
    final response = await helper.post(
      url,
      <String, String>{
        ..._headers(_uaNetdisk, cookie),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      '0',
    );
    final json = helper.jsonOf(response);
    _checkErrno(json, '获取高速下载直链失败');
    final candidates = listOf(json, 'urls')
        .where((item) => strOf(item, 'url').isNotEmpty)
        .toList();

    String? firstWhere(bool Function(Map<String, dynamic>) test) {
      for (final item in candidates) {
        if (test(item)) return strOf(item, 'url');
      }
      return null;
    }

    // 优先 encrypt=0 的 https 明文直链；排开 rank1 的 d2-ant 加密通道。
    final direct = firstWhere((item) =>
            intOf(item, 'encrypt') == 0 &&
            strOf(item, 'url').startsWith('https')) ??
        firstWhere((item) => strOf(item, 'url').startsWith('https')) ??
        (candidates.isEmpty ? null : strOf(candidates.first, 'url'));
    if (direct == null || direct.isEmpty) {
      throw const ShareResolveException('没有拿到可用的下载直链');
    }
    return direct;
  }

  Future<void> _delete(
      String path, String cookie, String token, ShareHttp helper) async {
    final body = 'filelist=${Uri.encodeComponent('["$path"]')}';
    final url = 'https://pan.baidu.com/api/filemanager?async=2&onnest=fail'
        '&opera=delete&bdstoken=$token&newVerify=1&clienttype=0'
        '&app_id=$_appId&web=1';
    try {
      final response = await helper.post(
        url,
        <String, String>{
          ..._headers(_uaNetdisk, cookie),
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        },
        body,
      );
      final json = helper.jsonOf(response);
      if (intOf(json, 'errno') == 0 && path.startsWith('$_tempDir/')) {
        await helper.post(
          url,
          <String, String>{
            ..._headers(_uaNetdisk, cookie),
            'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          },
          'filelist=${Uri.encodeComponent('["$_tempDir"]')}',
        );
      }
    } catch (_) {
      // 云端清理失败不阻断下载。
    }
  }

  @override
  Future<void> cleanup(
    DownloadLink link, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {}

  @override
  Future<DownloadLink> downloadLink(
    ShareSession session,
    ShareFile file, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final helper = ShareHttp(client, timeout: timeout);
    final token = await _bdstoken(cookie, helper);
    final dir = await _ensureTempDir(cookie, token, helper);
    final transferred = await _transfer(session, file, dir, cookie, helper);
    final path = transferred['path']!;
    final url = await _locateDownload(path, cookie, helper);
    // appall 直链自带签名，删掉转存文件后依然有效。
    await _delete(path, cookie, token, helper);
    return DownloadLink(
      url: url,
      filename: file.name,
      size: file.size,
      referer: 'https://pan.baidu.com/',
      userAgent: _uaNetdisk,
    );
  }
}

/// 供解析器调用：判断分享是否需要登录（百度转存必须登录）。
bool baiduNeedsLogin(String cookie) {
  return !cookie.contains('BDUSS=');
}
