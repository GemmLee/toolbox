import 'dart:convert';

import 'package:http/http.dart' as http;

import 'share_crypto.dart';
import 'share_link.dart';
import 'share_models.dart';

/// 蓝奏云优享版：分享列表 /unproved/share/list 与取链 /unproved/file/redirect
/// 均匿名可用；downloadId、auth 是 AES-ECB(密钥 lanZouY-disk-app) 的 hex。
/// 取自 YunX `ILanzouApi` / `ILanzouResolveRepository` / `ILanzouConstants`。
class ILanzouResolver implements ShareResolver {
  static const String _apiBase = 'https://apix.ilanzou.com';
  static const String _webSite = 'https://www.ilanzou.com';
  static const String _shareList = '$_apiBase/unproved/share/list';
  static const String _shareRedirect = '$_apiBase/unproved/file/redirect';
  static const String _getUuid = 'https://apis.ilanzou.com/unproved/getUuid';
  static const String _aesKey = 'lanZouY-disk-app';
  static const String _devType = '6';
  static const String _devModel = 'Chrome';
  static const String _devVersion = '125';
  static const int _pageSize = 60;
  static const String _referer = '$_webSite/';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const String _folderPrefix = 'd:';
  static const String _filePrefix = 'f:';

  @override
  SharePlatform get platform => SharePlatform.ilanzou;

  @override
  bool get requiresLogin => false;

  @override
  Future<void> cleanup(
    DownloadLink link, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {}

  String? _uuid;

  static String _aes(String plain) => ShareCrypto.aesEcbHex(plain, _aesKey);

  /// appToken 特殊编码：标准 query 编码后把 %3A 还原为字面冒号。
  static String _encodeToken(String value) =>
      Uri.encodeComponent(value).replaceAll('%3A', ':');

  static Map<String, String> _headers() => <String, String>{
        'User-Agent': _ua,
        'Origin': _webSite,
        'Referer': _referer,
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'sec-ch-ua':
            '"Google Chrome";v="131", "Chromium";v="131", "Not_A Brand";v="24"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"Windows"',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-site',
      };

  Future<String> _uuidOf(ShareHttp helper) async {
    final cached = _uuid;
    if (cached != null && cached.isNotEmpty) return cached;
    final params = <String, String>{
      'uuid': '',
      'devType': _devType,
      'devCode': '',
      'devModel': _devModel,
      'devVersion': _devVersion,
      'appVersion': '',
      'timestamp': _aes(DateTime.now().millisecondsSinceEpoch.toString()),
      'extra': '2',
    };
    final response = await helper.get('$_getUuid?${_query(params)}', _headers());
    final json = helper.jsonOf(response);
    final uuid = strOf(json, 'uuid');
    if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(uuid)) {
      throw const ShareResolveException('没拿到设备标识，稍后重试');
    }
    _uuid = uuid;
    return uuid;
  }

  static String _query(Map<String, String> params) => params.entries
      .map((e) => '${e.key}=${_encodeToken(e.value)}')
      .join('&');

  @override
  Future<ShareSession> createSession(
    ParsedShare share, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    // 优享用 shareId 作为会话标识，列目录/取链时再补 uuid。
    return ShareSession(
      platform: platform,
      shareId: share.shareId,
      token: share.shareId,
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
    final uuid = await _uuidOf(helper);
    final folderId = _folderIdOf(dirFid);
    final all = <ShareFile>[];
    final seen = <String>{};
    var page = 1;
    while (page <= 1000) {
      final params = <String, String>{
        'uuid': uuid,
        'devType': _devType,
        'devCode': uuid,
        'devModel': _devModel,
        'devVersion': _devVersion,
        'appVersion': '',
        'timestamp': _aes(DateTime.now().millisecondsSinceEpoch.toString()),
        'extra': '2',
        'shareId': session.shareId,
        if (folderId != null) 'folderId': folderId,
        'offset': '$page',
        'limit': '$_pageSize',
      };
      final response =
          await helper.get('$_shareList?${_query(params)}', _headers());
      final json = helper.jsonOf(response);
      _checkCode(json);
      final list = listOf(json, 'list');
      if (list.isEmpty) break;
      var added = 0;
      for (final item in list) {
        final file = _fileOf(item);
        if (file != null && seen.add(file.fid)) {
          all.add(file);
          added++;
        }
      }
      if (added == 0) break;
      final totalPage = intOf(json, 'totalPage');
      if (totalPage > 0 && page >= totalPage) break;
      if (totalPage <= 0 && list.length < _pageSize) break;
      page++;
    }
    return all;
  }

  static void _checkCode(Map<String, dynamic> json) {
    final code = intOf(json, 'code');
    if (code == 200) return;
    final msg = strOf(json, 'msg');
    throw ShareResolveException(msg.isEmpty ? '分享请求失败' : msg,
        code: '$code');
  }

  static String? _folderIdOf(String dirFid) {
    if (dirFid.isEmpty) return null;
    if (dirFid.startsWith(_folderPrefix)) {
      final id = dirFid.substring(_folderPrefix.length);
      return id.isEmpty ? null : id;
    }
    if (dirFid == '0') return null;
    return dirFid;
  }

  static ShareFile? _fileOf(Map<String, dynamic> item) {
    final isDir = intOf(item, 'fileType') == 2;
    final fid = isDir
        ? strOf(item, 'folderId').isEmpty
            ? intOf(item, 'folderId').toString()
            : strOf(item, 'folderId')
        : strOf(item, 'fileId').isEmpty
            ? intOf(item, 'fileId').toString()
            : strOf(item, 'fileId');
    if (fid.isEmpty || fid == '0') return null;
    final name = isDir ? strOf(item, 'folderName') : strOf(item, 'fileName');
    final time = strOf(item, 'updTime').isEmpty
        ? strOf(item, 'addTime')
        : strOf(item, 'updTime');
    return ShareFile(
      fid: '${isDir ? _folderPrefix : _filePrefix}$fid',
      name: name,
      size: isDir ? 0 : intOf(item, 'fileSize') * 1024,
      isDir: isDir,
      pdirFid: '',
      modifiedAt: time,
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
    if (file.isDir) {
      throw const ShareResolveException('目录不能直接下载');
    }
    final helper = ShareHttp(client, timeout: timeout);
    final uuid = await _uuidOf(helper);
    final fileId = file.fid.startsWith(_filePrefix)
        ? file.fid.substring(_filePrefix.length)
        : file.fid;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final params = <String, String>{
      'downloadId': _aes('$fileId|'),
      'enable': '1',
      'devType': _devType,
      'uuid': uuid,
      'timestamp': _aes('$ts'),
      'auth': _aes('$fileId|$ts'),
      'shareId': session.shareId,
    };
    final url = '$_shareRedirect?${_query(params)}';
    final response = await helper.get(url, _headers());
    // 可能是 302（http 包自动跟随后 request.url 是直链），也可能返回 JSON。
    String? link;
    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('json') || response.body.trimLeft().startsWith('{')) {
      final json = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true))
          as Map<String, dynamic>;
      final data = (json['data'] is Map)
          ? (json['data'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      link = strOf(json, 'url').isEmpty ? strOf(data, 'url') : strOf(json, 'url');
      if (link.isEmpty) {
        final msg = strOf(json, 'msg');
        throw ShareResolveException(msg.isEmpty ? '没拿到下载直链' : msg);
      }
    } else {
      link = response.request?.url.toString();
    }
    if (link == null || link.isEmpty) {
      throw const ShareResolveException('没拿到下载直链');
    }
    return DownloadLink(
      url: link,
      filename: file.name,
      size: file.size,
      referer: _referer,
      userAgent: _ua,
    );
  }
}
