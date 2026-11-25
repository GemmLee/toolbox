import 'package:http/http.dart' as http;

import 'share_link.dart';
import 'share_models.dart';

/// 夸克 / UC 共用同一套 clouddrive 协议：域名与少数参数不同。
/// 常量与调用顺序参照 YunX `QuarkApi` / `UCApi` 与对应 `*ResolveRepository`。
abstract class _QuarkUcResolver implements ShareResolver {
  String get apiBase;
  String get apiUa;
  String get downloadReferer;
  String get tokenUrl;
  String get detailUrl;
  String get downloadUrl;
  String get fileUrl;
  String get saveUrl;
  String get taskUrl;
  String get deleteUrl;
  String get detailOrigin;
  String get detailReferer;
  int get detailPageSize;
  bool get tokenUsesTransferFlag;

  @override
  bool get requiresLogin => false;

  Map<String, String> get _apiHeaders => <String, String>{
        'User-Agent': apiUa,
        'Accept': 'application/json, text/plain, */*',
      };

  @override
  Future<ShareSession> createSession(
    ParsedShare share, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final httpHelper = ShareHttp(client, timeout: timeout);
    final body = <String, dynamic>{
      'pwd_id': share.shareId,
      'passcode': share.pwd ?? '',
      if (tokenUsesTransferFlag)
        'share_for_transfer': true
      else
        'support_visit_limit_private_share': true,
    };
    final response = await httpHelper.post(
      tokenUrl,
      httpHelper.headersWith(_apiHeaders,
          cookie: cookie, contentType: 'application/json'),
      body,
    );
    final data = httpHelper.jsonOf(response);
    _checkStatus(data);
    final payload = (data['data'] is Map)
        ? (data['data'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final stoken = strOf(payload, 'stoken');
    if (stoken.isEmpty) {
      throw ShareResolveException('分享需要提取码或已失效',
          code: '${intOf(data, 'code')}');
    }
    return ShareSession(
      platform: platform,
      shareId: share.shareId,
      token: stoken,
      title: strOf(payload, 'title'),
      extra: <String, dynamic>{'firstFid': strOf(payload, 'first_fid')},
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
    final httpHelper = ShareHttp(client, timeout: timeout);
    final all = <ShareFile>[];
    for (var page = 1; page <= 100; page++) {
      final url = _detailUrl(session, dirFid, page);
      final response = await httpHelper.get(
        url,
        httpHelper.headersWith(
          _apiHeaders,
          cookie: cookie,
          // 官方详情页需要这两个头，否则可能 400。
        ),
      );
      final json = httpHelper.jsonOf(response);
      _checkStatus(json);
      final data = (json['data'] is Map)
          ? (json['data'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      final batch = listOf(data, 'list').map(_fileOf).toList();
      all.addAll(batch);
      if (batch.length < detailPageSize) break;
    }
    return all;
  }

  String _detailUrl(ShareSession session, String dirFid, int page);

  ShareFile _fileOf(Map<String, dynamic> item) => ShareFile(
        fid: strOf(item, 'fid'),
        name: strOf(item, 'file_name'),
        size: intOf(item, 'size'),
        isDir: boolOf(item, 'dir'),
        pdirFid: strOf(item, 'pdir_fid'),
        fidToken: strOf(item, 'share_fid_token'),
        modifiedAt: strOf(item, 'updated_at'),
      );

  void _checkStatus(Map<String, dynamic> json) {
    final status = intOf(json, 'status');
    final code = intOf(json, 'code');
    if (status == 200 || code == 0) return;
    final message = strOf(json, 'message');
    throw ShareResolveException(
      message.isEmpty ? '解析失败，请检查提取码或稍后重试' : message,
      code: '$code',
    );
  }

  DownloadLink _linkOf(Map<String, dynamic> item, {String guestCookie = ''}) {
    final url = strOf(item, 'download_url');
    if (url.isEmpty) throw const ShareResolveException('服务端没有返回下载直链');
    return DownloadLink(
      url: url,
      filename: strOf(item, 'file_name').isEmpty
          ? strOf(item, 'filename')
          : strOf(item, 'file_name'),
      size: intOf(item, 'size'),
      cookie: guestCookie,
      referer: downloadReferer,
      userAgent: apiUa,
    );
  }

  Future<DownloadLink> _downloadByBody(
    ShareHttp httpHelper,
    Map<String, dynamic> body, {
    required String cookie,
    bool guest = false,
  }) async {
    final headers = <String, String>{
      ..._apiHeaders,
      if (guest) 'Content-Type': 'application/json',
    };
    final response = await httpHelper.post(
      downloadUrl,
      httpHelper.headersWith(headers,
          cookie: guest ? '' : cookie, contentType: 'application/json'),
      body,
    );
    final guestCookie = guest ? (ShareHttp.pugsOf(response) ?? '') : '';
    final json = httpHelper.jsonOf(response);
    _checkStatus(json);
    final list = listOf(json, 'data');
    if (list.isEmpty) throw const ShareResolveException('没有拿到下载直链');
    return _linkOf(list.first, guestCookie: guestCookie);
  }

  /// 登录态：先走「免转存取链」，个别分享类型服务端要求转存时自动回退。
  Future<DownloadLink> _loggedInLink(
    ShareSession session,
    ShareFile file,
    String cookie,
    ShareHttp httpHelper,
  ) async {
    try {
      return await _downloadByBody(
        httpHelper,
        <String, dynamic>{
          'fids': <String>[file.fid],
          'fids_token': <String>[file.fidToken],
          'pwd_id': session.shareId,
          'stoken': session.token,
          'speedup_session': '',
          'token': '',
        },
        cookie: cookie,
      );
    } on ShareResolveException {
      // 回退：转存到唯一临时子目录 → 取链成功后保留目录，下载完成再删。
      final baseFid = await _ensureTempDir(cookie, httpHelper);
      final subName = 'tr_${DateTime.now().microsecondsSinceEpoch}_'
          '${DateTime.now().millisecond}';
      final subFid = await _createFolder(subName, baseFid, cookie, httpHelper);
      final taskId = await _saveShareFile(
        session,
        file,
        subFid,
        cookie,
        httpHelper,
      );
      final savedFid = await _pollTask(taskId, cookie, httpHelper);
      final link = await _downloadByBody(
        httpHelper,
        <String, dynamic>{
          'fids': <String>[savedFid]
        },
        cookie: cookie,
      );
      return DownloadLink(
        url: link.url,
        filename: link.filename.isEmpty ? file.name : link.filename,
        size: link.size == 0 ? file.size : link.size,
        cookie: link.cookie,
        referer: link.referer,
        userAgent: link.userAgent,
        cleanupDirFid: subFid,
      );
    }
  }

  Future<String> _ensureTempDir(String cookie, ShareHttp httpHelper) async {
    final response = await httpHelper.get(
      '$fileUrl&pdir_fid=0&_page=1&_size=100',
      httpHelper.headersWith(_apiHeaders, cookie: cookie),
    );
    final json = httpHelper.jsonOf(response);
    _checkStatus(json);
    final data = (json['data'] is Map)
        ? (json['data'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    for (final item in listOf(data, 'list')) {
      if (boolOf(item, 'dir') && strOf(item, 'file_name') == 'XMtools临时转存') {
        return strOf(item, 'fid');
      }
    }
    return _createFolder('XMtools临时转存', '0', cookie, httpHelper);
  }

  Future<String> _createFolder(
    String name,
    String parentFid,
    String cookie,
    ShareHttp httpHelper,
  ) async {
    final response = await httpHelper.post(
      fileUrl,
      httpHelper.headersWith(_apiHeaders,
          cookie: cookie, contentType: 'application/json'),
      <String, dynamic>{
        'pdir_fid': parentFid,
        'file_name': name,
        'dir_path': '',
        'dir_init_lock': false,
      },
    );
    final json = httpHelper.jsonOf(response);
    _checkStatus(json);
    final data = (json['data'] is Map)
        ? (json['data'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final fid = strOf(data, 'fid');
    if (fid.isEmpty) throw const ShareResolveException('创建临时目录失败');
    return fid;
  }

  Future<String> _saveShareFile(
    ShareSession session,
    ShareFile file,
    String toDirFid,
    String cookie,
    ShareHttp httpHelper,
  ) async {
    final response = await httpHelper.post(
      saveUrl,
      httpHelper.headersWith(_apiHeaders,
          cookie: cookie, contentType: 'application/json'),
      <String, dynamic>{
        'pwd_id': session.shareId,
        'stoken': session.token,
        'pdir_fid': file.pdirFid,
        'to_pdir_fid': toDirFid,
        'fid_list': <String>[file.fid],
        'fid_token_list': <String>[file.fidToken],
        'scene': 'link',
      },
    );
    final json = httpHelper.jsonOf(response);
    _checkStatus(json);
    final data = (json['data'] is Map)
        ? (json['data'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final taskId = strOf(data, 'task_id');
    if (taskId.isEmpty) throw const ShareResolveException('转存分享文件失败');
    return taskId;
  }

  Future<String> _pollTask(
    String taskId,
    String cookie,
    ShareHttp httpHelper,
  ) async {
    for (var i = 0; i < 10; i++) {
      final response = await httpHelper.get(
        '$taskUrl&task_id=${Uri.encodeComponent(taskId)}&retry_index=0',
        httpHelper.headersWith(_apiHeaders, cookie: cookie),
      );
      final json = httpHelper.jsonOf(response);
      if (intOf(json, 'status') == 200) {
        final data = (json['data'] is Map)
            ? (json['data'] as Map).cast<String, dynamic>()
            : <String, dynamic>{};
        final finished = intOf(data, 'finished_at') > 0 ||
            intOf(data, 'status') == 2 ||
            intOf(data, 'task_status') == 2;
        if (finished) {
          final saveAs = (data['save_as'] is Map)
              ? (data['save_as'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};
          final rawFids = saveAs['save_as_top_fids'];
          if (rawFids is List && rawFids.isNotEmpty) {
            return rawFids.first.toString();
          }
        }
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw const ShareResolveException('转存超时，请重试');
  }

  @override
  Future<void> cleanup(
    DownloadLink link, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (link.cleanupDirFid.isEmpty) return;
    final httpHelper = ShareHttp(client, timeout: timeout);
    try {
      await httpHelper.post(
        deleteUrl,
        httpHelper.headersWith(_apiHeaders,
            cookie: cookie, contentType: 'application/json'),
        <String, dynamic>{
          'action_type': 2,
          'filelist': <String>[link.cleanupDirFid],
          'exclude_fids': <String>[],
        },
      );
    } catch (_) {
      // 清理失败不阻断下载结果。
    }
  }
}

class QuarkResolver extends _QuarkUcResolver {
  static const String _base = 'https://drive-pc.quark.cn';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch';

  @override
  SharePlatform get platform => SharePlatform.quark;

  @override
  String get apiBase => _base;
  @override
  String get apiUa => _ua;
  @override
  String get downloadReferer => 'https://pan.quark.cn/';
  @override
  String get tokenUrl =>
      '$_base/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc';
  @override
  String get detailUrl =>
      '$_base/1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc';
  @override
  String get downloadUrl =>
      '$_base/1/clouddrive/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2';
  @override
  String get fileUrl => '$_base/1/clouddrive/file?pr=ucpro&fr=pc';
  @override
  String get saveUrl =>
      '$_base/1/clouddrive/share/sharepage/save?pr=ucpro&fr=pc';
  @override
  String get taskUrl => '$_base/1/clouddrive/task?pr=ucpro&fr=pc';
  @override
  String get deleteUrl =>
      '$_base/1/clouddrive/file/delete?pr=ucpro&fr=pc&uc_param_str=';
  @override
  String get detailOrigin => 'https://pan.quark.cn';
  @override
  String get detailReferer => 'https://pan.quark.cn/';
  @override
  int get detailPageSize => 100;
  @override
  bool get tokenUsesTransferFlag => false;

  @override
  String _detailUrl(ShareSession session, String dirFid, int page) =>
      '$detailUrl&pwd_id=${Uri.encodeComponent(session.shareId)}'
      '&stoken=${Uri.encodeComponent(session.token)}'
      '&pdir_fid=${Uri.encodeComponent(dirFid)}'
      '&ver=2&force=0&_page=$page&_size=100'
      '&_fetch_banner=0&_fetch_share=0&fetch_relate_conversation=0'
      '&_fetch_total=1&_sort=file_type:asc,file_name:asc';

  @override
  Future<List<ShareFile>> listFiles(
    ShareSession session, {
    required String dirFid,
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    // 夸克详情接口必须带 Origin / Referer，公共父类没有这一层。
    final helper = ShareHttp(client, timeout: timeout);
    final all = <ShareFile>[];
    for (var page = 1; page <= 100; page++) {
      final response = await helper.get(
        _detailUrl(session, dirFid, page),
        <String, String>{
          ..._apiHeaders,
          if (cookie.isNotEmpty) 'Cookie': cookie,
          'Origin': detailOrigin,
          'Referer': detailReferer,
        },
      );
      final json = helper.jsonOf(response);
      _checkStatus(json);
      final data = (json['data'] is Map)
          ? (json['data'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      final batch = listOf(data, 'list').map(_fileOf).toList();
      all.addAll(batch);
      if (batch.length < detailPageSize) break;
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
    final helper = ShareHttp(client, timeout: timeout);
    if (cookie.trim().isEmpty) {
      // 游客链路：不带账号 Cookie，靠响应下发的 __pugs 防盗链（约 50MB 以内）。
      return _downloadByBody(
        helper,
        <String, dynamic>{
          'fids': <String>[file.fid],
          'fids_token': <String>[file.fidToken],
          'pwd_id': session.shareId,
          'stoken': session.token,
          'speedup_session': '',
          'token': '',
        },
        cookie: '',
        guest: true,
      );
    }
    return _loggedInLink(session, file, cookie, helper);
  }
}

class UcResolver extends _QuarkUcResolver {
  static const String _base = 'https://pc-api.uc.cn';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  @override
  SharePlatform get platform => SharePlatform.uc;

  @override
  String get apiBase => _base;
  @override
  String get apiUa => _ua;
  @override
  String get downloadReferer => 'https://drive.uc.cn/';
  @override
  String get tokenUrl =>
      '$_base/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc';
  @override
  String get detailUrl =>
      '$_base/1/clouddrive/transfer_share/detail?entry=ft&fr=pc&pr=UCBrowser';
  @override
  String get downloadUrl =>
      '$_base/1/clouddrive/file/download?entry=ft&fr=pc&pr=UCBrowser';
  @override
  String get fileUrl => '$_base/1/clouddrive/file?pr=UCBrowser&fr=pc';
  @override
  String get saveUrl =>
      '$_base/1/clouddrive/share/sharepage/save?pr=UCBrowser&fr=pc';
  @override
  String get taskUrl => '$_base/1/clouddrive/task?pr=UCBrowser&fr=pc';
  @override
  String get deleteUrl => '$_base/1/clouddrive/file/delete?pr=UCBrowser&fr=pc';
  @override
  String get detailOrigin => 'https://fast.uc.cn';
  @override
  String get detailReferer => 'https://fast.uc.cn/';
  @override
  int get detailPageSize => 50;
  @override
  bool get tokenUsesTransferFlag => true;

  @override
  String _detailUrl(ShareSession session, String dirFid, int page) =>
      '$detailUrl&pwd_id=${Uri.encodeComponent(session.shareId)}'
      '&pdir_fid=${Uri.encodeComponent(dirFid)}&fetch_file_list=1&passcode='
      '&_page=$page&_size=50&_fetch_total=1&_fetch_task=1&_fetch_share=1'
      '&_sort=&stoken=${Uri.encodeComponent(session.token)}';

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
      final response = await helper.get(
        _detailUrl(session, dirFid, page),
        <String, String>{
          ..._apiHeaders,
          if (cookie.isNotEmpty) 'Cookie': cookie,
          'Origin': detailOrigin,
          'Referer': detailReferer,
        },
      );
      final json = helper.jsonOf(response);
      _checkStatus(json);
      final data = (json['data'] is Map)
          ? (json['data'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      final list = data['list'] is List
          ? listOf(data, 'list')
          : listOf(
              (data['detail_info'] is Map)
                  ? (data['detail_info'] as Map).cast<String, dynamic>()
                  : <String, dynamic>{},
              'list',
            );
      final batch = list.map(_fileOf).toList();
      all.addAll(batch);
      if (batch.length < detailPageSize) break;
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
    final helper = ShareHttp(client, timeout: timeout);
    final body = <String, dynamic>{
      'fids': <String>[file.fid],
      'pwd_id': session.shareId,
      'stoken': session.token,
      'fids_token': <String>[file.fidToken],
    };
    // UC 官方流程无需转存：登录态直接带 Cookie，游客态靠 __pugs。
    return _downloadByBody(
      helper,
      body,
      cookie: cookie,
      guest: cookie.trim().isEmpty,
    );
  }
}

/// 供测试定位平台适配器的统一入口。
ShareResolver resolverFor(SharePlatform platform) => switch (platform) {
      SharePlatform.quark => QuarkResolver(),
      SharePlatform.uc => UcResolver(),
      _ => throw ArgumentError('暂不支持的平台：${platform.label}'),
    };
