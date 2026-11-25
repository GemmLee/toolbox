import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

import 'share_link.dart';
import 'share_models.dart';

/// 139（和彩云）分享解析：getOutLinkInfoV6 列目录 + dlFromOutLinkV3 取 OBS 直链。
/// 7.13+ 的请求/响应都是 base64(IV ‖ AES-CBC)，IV 随机 16 字节。
class C139Resolver implements ShareResolver {
  static const String _shareBase = 'https://share-kd-njs.yun.139.com';
  static const String _listUrl =
      '$_shareBase/yun-share/richlifeApp/devapp/IOutLink/getOutLinkInfoV6';
  static const String _linkUrl =
      '$_shareBase/yun-share/richlifeApp/devapp/IOutLink/dlFromOutLinkV3';
  static const String _shareKey = 'PVGDwmcvfs1uV3d1';
  static const String _mobileUa =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36';

  @override
  SharePlatform get platform => SharePlatform.c139;

  @override
  bool get requiresLogin => false;

  static String _md5Hex(String text) {
    final digest = MD5Digest().process(utf8.encode(text));
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _randomAlphaNum(int length) {
    const pool =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List<int>.generate(
      length,
      (_) => pool.codeUnitAt(random.nextInt(pool.length)),
      growable: false,
    ).map((code) => String.fromCharCode(code)).join();
  }

  /// body' 单字符 ASCII 升序 → base64 → md5(base64) + md5(ts:rand) → md5 → 大写。
  static String calSign(String body, String ts, String rand) {
    final encoded = Uri.encodeComponent(body);
    final sorted = encoded.split('').toList()..sort();
    final b64 = base64.encode(utf8.encode(sorted.join()));
    return _md5Hex('${_md5Hex(b64)}${_md5Hex('$ts:$rand')}').toUpperCase();
  }

  static String signHeader(String body) {
    final now = DateTime.now();
    final ts = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    final rand = _randomAlphaNum(16);
    return '$ts,$rand,${calSign(body, ts, rand)}';
  }

  /// 请求体加密，公开给单测做 round-trip 校验。
  static String encryptBody(String plain) {
    final iv = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      true,
      PaddedBlockCipherParameters(
        ParametersWithIV(
            KeyParameter(utf8.encode(_shareKey)), Uint8List.fromList(iv)),
        null,
      ),
    );
    final encrypted = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    return base64.encode(<int>[...iv, ...encrypted]);
  }

  /// 响应体解密；网关透传明文时会原样返回。
  static String decryptBody(String raw) {
    final bytes = base64.decode(raw.trim());
    if (bytes.length < 32) return raw;
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      false,
      PaddedBlockCipherParameters(
        ParametersWithIV(
          KeyParameter(utf8.encode(_shareKey)),
          Uint8List.fromList(bytes.sublist(0, 16)),
        ),
        null,
      ),
    );
    var plain = cipher.process(Uint8List.fromList(bytes.sublist(16)));
    if (plain.length >= 2 && plain[0] == 0x1f && plain[1] == 0x8b) {
      plain = const GZipDecoder().decodeBytes(plain);
    }
    return utf8.decode(plain, allowMalformed: true);
  }

  Map<String, String> _headers({String? authorization, String? sign}) =>
      <String, String>{
        'hcy-cool-flag': '1',
        'x-deviceinfo': '||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||',
        'x-huawei-channelsrc': '10245500',
        'x-mm-source': '0002',
        'Content-Type': 'application/json;charset=UTF-8',
        'User-Agent': _mobileUa,
        'Origin': 'https://yun.139.com',
        'Referer': 'https://yun.139.com/',
        'Accept': 'application/json, text/plain, */*',
        if (authorization != null && authorization.isNotEmpty)
          'Authorization': authorization,
        if (sign != null) 'mcloud-sign': sign,
      };

  Future<Map<String, dynamic>> _post(
    String url,
    String plainBody,
    ShareHttp helper, {
    String? authorization,
    bool signed = false,
  }) async {
    final headers = _headers(
      authorization: authorization,
      sign: signed ? signHeader(plainBody) : null,
    );
    final response = await helper.post(url, headers, encryptBody(plainBody));
    final text = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(decryptBody(text)) as Map<String, dynamic>;
    } catch (_) {
      // 少数网关直接透传明文 JSON。
      decoded = jsonDecode(text) as Map<String, dynamic>;
    }
    final code = strOf(decoded, 'resultCode');
    if (code.isNotEmpty && code != '0') {
      final desc = strOf(decoded, 'desc');
      throw ShareResolveException(
        desc.isEmpty ? '139 接口返回错误' : desc,
        code: code,
      );
    }
    if (decoded['success'] == false) {
      throw ShareResolveException(
        strOf(decoded, 'desc').isEmpty ? '139 解析失败' : strOf(decoded, 'desc'),
      );
    }
    return decoded;
  }

  @override
  Future<ShareSession> createSession(
    ParsedShare share, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final cleaned = ShareLinkParser.c139Cookies(cookie);
    return ShareSession(
      platform: platform,
      shareId: share.shareId,
      token: share.pwd ?? '',
      extra: <String, dynamic>{
        'cookies': cleaned,
        'account': ShareLinkParser.c139Account(cleaned) ?? '',
        'authorization': ShareLinkParser.c139Authorization(cleaned) ?? '',
      },
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
    final req = <String, dynamic>{
      'account': '',
      'linkID': session.shareId,
      'passwd': session.token,
      'caSrt': 1,
      'coSrt': 1,
      'srtDr': 0,
      'bNum': 1,
      'pCaID': dirFid.isEmpty ? 'root' : dirFid,
      'eNum': 200,
    };
    final json = await _post(
      _listUrl,
      jsonEncode(<String, dynamic>{'getOutLinkInfoReq': req}),
      helper,
    );
    final data = (json['data'] is Map)
        ? (json['data'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final parent = dirFid.isEmpty ? 'root' : dirFid;
    final result = <ShareFile>[];
    // 139 把子文件夹放在 caLst，文件放在 coLst（coType==2 也可能是文件夹）。
    for (final item in listOf(data, 'caLst')) {
      result.add(ShareFile(
        fid: strOf(item, 'caID'),
        name: strOf(item, 'caName'),
        size: 0,
        isDir: true,
        pdirFid: parent,
        modifiedAt: strOf(item, 'udTime').isEmpty
            ? strOf(item, 'ctTime')
            : strOf(item, 'udTime'),
      ));
    }
    for (final item in listOf(data, 'coLst')) {
      final isDir = boolOf(item, 'isdir') || intOf(item, 'coType') == 2;
      result.add(ShareFile(
        fid: strOf(item, 'coID'),
        name: strOf(item, 'coName'),
        size: intOf(item, 'coSize'),
        isDir: isDir,
        pdirFid: parent,
        modifiedAt: strOf(item, 'udTime').isEmpty
            ? strOf(item, 'ctTime')
            : strOf(item, 'udTime'),
      ));
    }
    return result;
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
    final account = strOf(session.extra, 'account');
    final authorization = strOf(session.extra, 'authorization');
    final req = <String, dynamic>{
      'account': account,
      'linkID': session.shareId,
      'coIDLst': <String, dynamic>{
        'item': <String>[file.fid]
      },
      'commonAccountInfo': <String, dynamic>{
        'account': account,
        'accountType': 1,
      },
    };
    final json = await _post(
      _linkUrl,
      jsonEncode(<String, dynamic>{'dlFromOutLinkReqV3': req}),
      helper,
      authorization: authorization,
      signed: true,
    );
    final data = (json['data'] is Map)
        ? (json['data'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final url = strOf(data, 'redrUrl');
    if (url.isEmpty) throw const ShareResolveException('139 没有返回下载直链');
    final name = strOf(data, 'fileName').isEmpty
        ? (strOf(data, 'coName').isEmpty ? file.name : strOf(data, 'coName'))
        : strOf(data, 'fileName');
    return DownloadLink(
      url: url,
      filename: name,
      size: intOf(data, 'coSize') == 0
          ? intOf(data, 'size')
          : intOf(data, 'coSize'),
      referer: 'https://yun.139.com/',
      userAgent: _mobileUa,
    );
  }
}
