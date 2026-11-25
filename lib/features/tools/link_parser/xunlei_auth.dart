import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'share_crypto.dart';
import 'share_models.dart';

/// 迅雷账号密码登录（对齐 YunX `XunleiApi` 的 App 通道）。
///
/// 迅雷没有「网页 Cookie 就能取链」这条路：直链必须由登录态账号转存后换取，
/// 所以这里把登录做成账号密码 / 短信两种方式，拿到的 access_token 存本机凭证。
///
/// 全流程：captcha/init（设备签名）→ v3/login（密码，可能被风控要求短信）
/// → v3/sendsms → v3/smslogin → v1/auth/signin/token 换 access_token。
class XunleiAuth {
  XunleiAuth({http.Client? client, this.timeout = const Duration(seconds: 15)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  static const String authBase = 'https://xluser-ssl.xunlei.com';
  static const String appClientId = 'Xp6vsxz_7IYVw2BB';
  static const String appClientSecret = 'Xp6vsy4tN9toTVdMSpomVdXpRmES';
  static const String appClientVersion = '8.31.0.9726';
  static const String appPackageName = 'com.xunlei.downloadprovider';
  static const String appUa =
      'ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 '
      'deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC OSVersion/12 '
      'protocolVersion/301 platformVersion/10 sdkVersion/512000 '
      'Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)';

  static const String passwordUa =
      'android-ok-http-client/xl-acc-sdk/version-5.1.3.513006';
  static const String smsUa =
      'android-ok-http-client/xl-acc-sdk/version-5.0.12.512000';

  /// 10 层盐（alist 源码与 YunX 一致），captcha_sign 逐层 md5。
  static const List<String> captchaSalts = <String>[
    '9uJNVj/wLmdwKrJaVj/omlQ',
    'Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf',
    'Eb+L7Ce+Ej48u',
    'jKY0',
    'ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd',
    'wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK',
    'gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O',
    '5IiCoM9B1/788ntB',
    'P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf',
    '+oK0AN',
  ];

  /// `captcha_sign`：client_id + 版本 + 包名 + device_id + 时间戳，再逐层加盐 md5。
  static String captchaSign(String deviceId, int timestampMs) {
    var hash = appClientId + appClientVersion + appPackageName + deviceId +
        timestampMs.toString();
    for (final salt in captchaSalts) {
      hash = ShareCrypto.md5Hex(hash + salt);
    }
    return '1.$hash';
  }

  /// `devicesign`：div101.{deviceId}{md5(sha1(deviceId + 包名 + appid + appkey))}。
  static String deviceSign(String deviceId) {
    const appKey = '34a062aaa22f906fca4fefe9fb3a3021';
    final base = <String>[deviceId, appPackageName, '40', appKey].join();
    final sha1 = ShareCrypto.sha1Hex(base);
    return 'div101.$deviceId${ShareCrypto.md5Hex(sha1)}';
  }

  Map<String, String> get _json => const <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json;charset=UTF-8',
      };

  /// 登录请求公共体：字段与官方 App 抓包一致，peerID / devicesign 用本机指纹。
  Map<String, dynamic> _loginBody(
    XunleiDevice device,
    String clientVersion,
    String sdkVersion, {
    String creditKey = '',
  }) =>
      <String, dynamic>{
        'protocolVersion': '301',
        'sequenceNo': (_random.nextInt(90000000) + 10000000).toString(),
        'platformVersion': '10',
        'isCompressed': '0',
        'appid': '40',
        'clientVersion': clientVersion,
        'peerID': device.peerId,
        'appName': 'ANDROID-$appPackageName',
        'sdkVersion': sdkVersion,
        'devicesign': device.sign,
        'netWorkType': 'WIFI',
        'providerName': 'NONE',
        'deviceModel': 'M2004J7AC',
        'deviceName': 'Xiaomi_M2004j7ac',
        'OSVersion': '12',
        'creditkey': creditKey,
        'hl': 'zh-CN',
      };

  static final Random _random = Random();

  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> body, {
    required String ua,
    Map<String, String> extra = const <String, String>{},
  }) async {
    final http.Response response;
    try {
      response = await _client
          .post(Uri.parse(url), headers: {..._json, 'User-Agent': ua, ...extra}, body: jsonEncode(body))
          .timeout(timeout);
    } catch (e) {
      throw ShareResolveException('连不上迅雷服务器（$e）');
    }
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    final json = _tryJson(text);
    if (json == null) {
      throw ShareResolveException('迅雷返回了非 JSON 内容（HTTP ${response.statusCode}）');
    }
    return json;
  }

  static Map<String, dynamic>? _tryJson(String text) {
    final start = text.indexOf('{');
    if (start < 0) return null;
    try {
      final decoded = jsonDecode(text.substring(start));
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// 密码登录：`creditkey` 留空，新设备大概率返回 review_panel（需要短信验证）。
  Future<XunleiLoginStep> loginWithPassword({
    required XunleiDevice device,
    required String username,
    required String password,
  }) async {
    final body = _loginBody(device, '25.0.5.25', '513006')
      ..['userName'] = username
      ..['passWord'] = password
      ..['verifyKey'] = ''
      ..['verifyCode'] = ''
      ..['isMd5Pwd'] = '0';
    final json = await _post('$authBase/xluser.core.login/v3/login', body,
        ua: passwordUa);
    return _stepOf(json);
  }

  /// 发送短信验证码（密码登录被风控拦下、或直接用短信登录）。
  Future<XunleiLoginStep> sendSms({
    required XunleiDevice device,
    required String mobile,
  }) async {
    final body = _loginBody(device, appClientVersion, '231500')
      ..['mobile'] = mobile
      ..['register'] = '0';
    final json = await _post('$authBase/xluser.core.login/v3/sendsms', body,
        ua: smsUa);
    return XunleiLoginStep(
      needSms: true,
      smsCreditKey: (json['creditkey'] ?? '').toString(),
      smsToken: (json['token'] ?? '').toString(),
      message: (json['errorDesc'] ?? '').toString().isEmpty
          ? '验证码已发送'
          : (json['errorDesc'] ?? '').toString(),
    );
  }

  /// 短信验证码登录，成功后 [XunleiLoginStep.sessionId] 用于换 access_token。
  Future<XunleiLoginStep> loginWithSms({
    required XunleiDevice device,
    required String mobile,
    required String code,
    required String creditKey,
    required String smsToken,
  }) async {
    final body = _loginBody(device, appClientVersion, '231500',
        creditKey: creditKey)
      ..['mobile'] = mobile
      ..['smsCode'] = code
      ..['token'] = smsToken
      ..['register'] = '0';
    final json = await _post('$authBase/xluser.core.login/v3/smslogin', body,
        ua: smsUa);
    return _stepOf(json);
  }

  /// 验证码盾初始化：拿到 X-Captcha-Token（换 token 与 POST 类 pan 接口都要）。
  ///
  /// [userId] 必须是本次登录返回的真实用户 ID，留空会拿到降级 token，
  /// 换 access_token 时被拒（表现为「验证通过但没登录上」）。
  Future<String> initCaptcha({
    required XunleiDevice device,
    required String action,
    String username = '',
    String userId = '',
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final body = <String, dynamic>{
      'action': action,
      'captcha_token': '',
      'client_id': appClientId,
      'device_id': device.id,
      'meta': <String, dynamic>{
        'username': username,
        'client_version': appClientVersion,
        'package_name': appPackageName,
        'timestamp': timestamp.toString(),
        'captcha_sign': captchaSign(device.id, timestamp),
        'user_id': userId,
      },
      'redirect_uri': 'xlaccsdk01://xunlei.com/callback?state=harbor',
    };
    final json = await _post('$authBase/v1/shield/captcha/init', body,
        ua: appUa,
        extra: <String, String>{
          'X-Client-Id': appClientId,
          'X-Device-Id': device.id,
          'X-Client-Version': appClientVersion,
        });
    final token = (json['captcha_token'] ?? '').toString();
    if (token.isEmpty) {
      throw const ShareResolveException('迅雷验证码初始化失败，请重试');
    }
    return token;
  }

  /// 用登录返回的 sessionID 换 access_token / refresh_token。
  Future<XunleiTokenPair> exchangeToken({
    required XunleiDevice device,
    required String sessionId,
    required String userId,
    required String username,
  }) async {
    final captcha = await initCaptcha(
      device: device,
      action: 'POST:/auth/signin/token',
      username: username,
      userId: userId,
    );
    final body = <String, dynamic>{
      'client_id': appClientId,
      'client_secret': appClientSecret,
      'provider': 'access_end_point_token',
      'signin_token': sessionId,
    };
    final json = await _post('$authBase/v1/auth/signin/token', body,
        ua: appUa,
        extra: <String, String>{
          'X-Client-Id': appClientId,
          'X-Device-Id': device.id,
          'X-Client-Version': appClientVersion,
          'X-Captcha-Token': captcha,
        });
    final access = (json['access_token'] ?? json['accessToken'] ?? '').toString();
    final refresh =
        (json['refresh_token'] ?? json['refreshToken'] ?? '').toString();
    if (access.isEmpty) {
      final message = (json['error_description'] ??
              json['message'] ??
              json['error'] ??
              '')
          .toString();
      throw ShareResolveException(
        message.isEmpty ? '迅雷登录未返回访问令牌' : '迅雷登录失败：$message',
      );
    }
    return XunleiTokenPair(accessToken: access, refreshToken: refresh);
  }

  /// 用 refresh_token 续期；过期或没配 refresh_token 时返回 null。
  Future<XunleiTokenPair?> refresh({
    required XunleiDevice device,
    required String refreshToken,
  }) async {
    if (refreshToken.isEmpty) return null;
    try {
      final response = await _client.post(
        Uri.parse('$authBase/v1/auth/token'),
        headers: {
          ..._json,
          'User-Agent': appUa,
          'X-Client-Id': appClientId,
          'X-Device-Id': device.id,
        },
        body: jsonEncode(<String, dynamic>{
          'client_id': appClientId,
          'client_secret': appClientSecret,
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
        }),
      ).timeout(timeout);
      final json = _tryJson(utf8.decode(response.bodyBytes, allowMalformed: true));
      if (json == null) return null;
      final access =
          (json['access_token'] ?? json['accessToken'] ?? '').toString();
      if (access.isEmpty) return null;
      final next =
          (json['refresh_token'] ?? json['refreshToken'] ?? '').toString();
      return XunleiTokenPair(
        accessToken: access,
        refreshToken: next.isEmpty ? refreshToken : next,
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 v3/login / v3/smslogin 的响应。
  XunleiLoginStep _stepOf(Map<String, dynamic> json) {
    final errorCode = (json['errorCode'] ?? '').toString();
    final error = (json['error'] ?? '').toString();
    if (errorCode == '0' || error == 'success') {
      return XunleiLoginStep(
        ok: true,
        sessionId: (json['sessionID'] ?? '').toString(),
        nickname: (json['nickName'] ?? '').toString(),
        userId: (json['userID'] ?? '').toString(),
        message: '登录成功',
      );
    }
    final verifyType = (json['verifyType'] ?? '').toString();
    final needSms = error == 'review_panel' ||
        errorCode == '1007' ||
        verifyType.isNotEmpty;
    final desc = (json['errorDesc'] ?? json['error_description'] ?? '').toString();
    return XunleiLoginStep(
      needSms: needSms,
      reviewUrl: (json['reviewurl'] ?? '').toString(),
      message: desc.isEmpty ? (needSms ? '需要短信验证' : '登录失败（$errorCode）') : desc,
    );
  }
}

/// 一次登录请求的结果：成功带回 sessionID，被风控拦下时标记需要短信。
class XunleiLoginStep {
  const XunleiLoginStep({
    this.ok = false,
    this.needSms = false,
    this.smsCreditKey = '',
    this.smsToken = '',
    this.sessionId = '',
    this.nickname = '',
    this.userId = '',
    this.reviewUrl = '',
    this.message = '',
  });

  final bool ok;
  final bool needSms;
  final String smsCreditKey;
  final String smsToken;
  final String sessionId;
  final String nickname;
  final String userId;
  final String reviewUrl;
  final String message;
}

/// access_token + refresh_token。
class XunleiTokenPair {
  const XunleiTokenPair({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

/// 已登录的迅雷账号：设备指纹 + 令牌，存进本机凭证的 `storage` 字段。
class XunleiAccount {
  const XunleiAccount({
    required this.device,
    required this.accessToken,
    required this.refreshToken,
    this.userId = '',
    this.nickname = '',
  });

  final XunleiDevice device;
  final String accessToken;
  final String refreshToken;
  final String userId;
  final String nickname;

  String get label => nickname.isEmpty ? '迅雷账号' : nickname;

  Map<String, String> toStorage() => <String, String>{
        'access_token': accessToken,
        if (refreshToken.isNotEmpty) 'refresh_token': refreshToken,
        if (userId.isNotEmpty) 'user_id': userId,
        if (nickname.isNotEmpty) 'nickname': nickname,
        'device_id': device.id,
        'peer_id': device.peerId,
        'device_sign': device.sign,
        'kind': 'xunlei_account',
      };

  /// 从凭证 storage 还原；缺少 access_token 或设备号时返回 null。
  static XunleiAccount? fromStorage(Map<String, String> storage) {
    final access = storage['access_token'] ?? '';
    final deviceId = storage['device_id'] ?? '';
    if (access.isEmpty || deviceId.isEmpty) return null;
    return XunleiAccount(
      device: XunleiDevice(
        id: deviceId,
        peerId: storage['peer_id'] ?? '',
        sign: storage['device_sign'] ?? XunleiAuth.deviceSign(deviceId),
      ),
      accessToken: access,
      refreshToken: storage['refresh_token'] ?? '',
      userId: storage['user_id'] ?? '',
      nickname: storage['nickname'] ?? '',
    );
  }

  XunleiAccount copyWith({String? accessToken, String? refreshToken}) =>
      XunleiAccount(
        device: device,
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken ?? this.refreshToken,
        userId: userId,
        nickname: nickname,
      );
}

/// 本机迅雷设备指纹：首次生成后长期复用，避免所有安装共用同一个官方指纹。
class XunleiDevice {
  const XunleiDevice({
    required this.id,
    required this.peerId,
    required this.sign,
  });

  final String id;
  final String peerId;
  final String sign;

  static const String storeKey = 'xunlei_device_fp_v2';

  /// 读缓存；没有就生成一份并落盘（异常路径回落到固定指纹，不让请求缺字段）。
  static Future<XunleiDevice> load({
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    try {
      final prefs = await (prefsLoader ?? SharedPreferences.getInstance)();
      final raw = prefs.getString(storeKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final id = (decoded['id'] ?? '').toString();
          final peer = (decoded['peer'] ?? '').toString();
          final sign = (decoded['sign'] ?? '').toString();
          if (id.isNotEmpty && peer.isNotEmpty && sign.isNotEmpty) {
            return XunleiDevice(id: id, peerId: peer, sign: sign);
          }
        }
      }
      final created = create();
      await prefs.setString(
        storeKey,
        jsonEncode(<String, String>{
          'id': created.id,
          'peer': created.peerId,
          'sign': created.sign,
        }),
      );
      return created;
    } catch (_) {
      return create();
    }
  }

  /// 生成一份新的随机指纹（32 位 hex + 由它派生的 devicesign）。
  static XunleiDevice create({Random? random}) {
    final rng = random ?? Random.secure();
    String hex(int length) =>
        List<String>.generate(length, (_) => rng.nextInt(16).toRadixString(16))
            .join();
    final id = hex(32);
    return XunleiDevice(
      id: id,
      peerId: hex(32),
      sign: XunleiAuth.deviceSign(id),
    );
  }
}
