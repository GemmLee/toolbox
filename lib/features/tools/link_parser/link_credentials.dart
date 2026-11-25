import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'link_parser.dart';
import 'share_link.dart';

/// 一份网盘登录凭证。
///
/// 明文保存是刻意选择：Android Keystore 的密钥会随系统升级 / 换机失效，
/// 一旦密钥丢了账号也就丢了。这里把凭证当普通用户文件对待——用户能导出、
/// 能导入、也能在「清除该工具数据」时一并删掉。
class LinkCredential {
  const LinkCredential({
    required this.platform,
    required this.loginUrl,
    required this.finalUrl,
    required this.cookies,
    required this.storage,
    required this.savedAt,
  });

  final String platform;
  final String loginUrl;

  /// 登录完成后实际停留的地址，一般才是 Cookie 的归属域。
  final String finalUrl;

  final String cookies;

  /// localStorage 里挑出来的凭证相关键值。
  final Map<String, String> storage;

  final int savedAt;

  bool get isEmpty => cookies.trim().isEmpty && storage.isEmpty;

  /// 转成可直接塞给 http 请求的头。
  Map<String, String> headers() => <String, String>{
        if (cookies.trim().isNotEmpty) 'Cookie': cookies.trim(),
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'platform': platform,
        'loginUrl': loginUrl,
        'finalUrl': finalUrl,
        'cookies': cookies,
        'storage': storage,
        'savedAt': savedAt,
      };

  factory LinkCredential.fromJson(Map<String, dynamic> json) => LinkCredential(
        platform: (json['platform'] ?? '').toString(),
        loginUrl: (json['loginUrl'] ?? '').toString(),
        finalUrl: (json['finalUrl'] ?? '').toString(),
        cookies: (json['cookies'] ?? '').toString(),
        storage: _stringMap(json['storage']),
        savedAt: (json['savedAt'] is num)
            ? (json['savedAt'] as num).toInt()
            : int.tryParse('${json['savedAt'] ?? ''}') ?? 0,
      );

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    return raw.map(
      (key, value) => MapEntry<String, String>(
        key.toString(),
        value?.toString() ?? '',
      ),
    );
  }
}

/// 凭证存储：SharedPreferences 里一个 JSON 数组，按平台去重。
class LinkCredentialStore {
  LinkCredentialStore._();

  static const String storeKey = 'link_credentials_v1';

  static Future<List<LinkCredential>> load({
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    try {
      final prefs = await (prefsLoader ?? SharedPreferences.getInstance)();
      final raw = prefs.getString(storeKey);
      if (raw == null || raw.isEmpty) return const <LinkCredential>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <LinkCredential>[];
      return decoded
          .whereType<Map>()
          .map((m) => LinkCredential.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false);
    } catch (_) {
      return const <LinkCredential>[];
    }
  }

  /// 同一平台只保留最新一份；换账号登录会覆盖旧凭证。
  static Future<void> save(
    LinkCredential credential, {
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    credential = normalize(credential);
    final all = await load(prefsLoader: prefsLoader);
    final next = <LinkCredential>[
      for (final item in all)
        if (item.platform != credential.platform) item,
      credential,
    ];
    await _writeAll(next, prefsLoader: prefsLoader);
  }

  /// 139 的 CookieManager 里混了大量埋点字段，只保留协议真正用到的白名单；
  /// 其他平台原样保存。
  static LinkCredential normalize(LinkCredential item) {
    if (item.platform != '139 云盘' || item.cookies.isEmpty) return item;
    final cookies = ShareLinkParser.c139Cookies(item.cookies);
    if (cookies.isEmpty) return item;
    return LinkCredential(
      platform: item.platform,
      loginUrl: item.loginUrl,
      finalUrl: item.finalUrl,
      cookies: cookies,
      storage: item.storage,
      savedAt: item.savedAt,
    );
  }

  static Future<void> remove(
    String platform, {
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    final all = await load(prefsLoader: prefsLoader);
    await _writeAll(
      all.where((item) => item.platform != platform).toList(),
      prefsLoader: prefsLoader,
    );
  }

  static Future<void> _writeAll(
    List<LinkCredential> all, {
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    final prefs = await (prefsLoader ?? SharedPreferences.getInstance)();
    await prefs.setString(
      storeKey,
      jsonEncode(all.map((item) => item.toJson()).toList()),
    );
  }

  /// 备份格式：带版本号的 JSON，换设备后可原样导入。
  static String exportJson(List<LinkCredential> all) =>
      jsonEncode(<String, dynamic>{
        'format': 'link-credentials',
        'version': 1,
        'items': all.map((item) => item.toJson()).toList(),
      });

  /// 返回导入后的凭证总数；格式不对时抛 [FormatException]。
  static Future<int> importJson(
    String text, {
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    final decoded = jsonDecode(text);
    if (decoded is! Map) throw const FormatException('不是凭证备份文件');
    final items = decoded['items'];
    if (items is! List) throw const FormatException('备份里没有凭证列表');
    final incoming = items
        .whereType<Map>()
        .map((m) => LinkCredential.fromJson(m.cast<String, dynamic>()))
        .where((item) => !item.isEmpty && item.platform.isNotEmpty)
        .map(normalize)
        .toList();
    final all = await load(prefsLoader: prefsLoader);
    final merged = <String, LinkCredential>{
      for (final item in all) item.platform: item,
      for (final item in incoming) item.platform: item,
    };
    await _writeAll(merged.values.toList(), prefsLoader: prefsLoader);
    return merged.length;
  }

  /// 按平台匹配当前链接，返回可用的请求头（目前只有 Cookie）。
  static Map<String, String> headersFor(
    String url,
    List<LinkCredential> all,
  ) =>
      find(url, all)?.headers() ?? const <String, String>{};

  /// 按平台 / 主域匹配当前链接对应的凭证；没有登录过时返回 null。
  static LinkCredential? find(String url, List<LinkCredential> all) {
    final platform = LinkParser.platformOf(url);
    for (final item in all) {
      if (item.platform == platform) return item;
    }
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return null;
    for (final item in all) {
      final savedHost =
          Uri.tryParse(item.finalUrl.isEmpty ? item.loginUrl : item.finalUrl)
              ?.host
              .toLowerCase();
      if (savedHost == null) continue;
      // 只认主域相同（pan.baidu.com 与 yun.baidu.com 视为同一平台）。
      final parts = host.split('.');
      final savedParts = savedHost.split('.');
      if (parts.length >= 2 && savedParts.length >= 2) {
        final domain = parts.sublist(parts.length - 2).join('.');
        final savedDomain = savedParts.sublist(savedParts.length - 2).join('.');
        if (domain == savedDomain) return item;
      }
    }
    return null;
  }
}

/// Flutter ↔ 原生 WebView 登录页的通道。
class LinkLoginBridge {
  LinkLoginBridge({this.invoker});

  static const MethodChannel _channel = MethodChannel('toolbox/link_webview');

  /// 测试注入：替代真实 MethodChannel，避免跑原生代码。
  final Future<Map<dynamic, dynamic>?> Function(
      String method, Map<String, dynamic> args)? invoker;

  Future<LinkCredential?> open(
    String platform,
    String loginUrl, {
    List<String> cookieDomains = const <String>[],
    bool desktop = true,
  }) async {
    final args = <String, dynamic>{
      'platform': platform,
      'url': loginUrl,
      'cookieDomains': cookieDomains,
      'desktop': desktop,
    };
    final Map<dynamic, dynamic>? raw;
    if (invoker != null) {
      raw = await invoker!('openLogin', args);
    } else {
      raw = await _channel.invokeMapMethod<dynamic, dynamic>('openLogin', args);
    }
    if (raw == null) return null;
    final storageRaw = raw['storage']?.toString() ?? '{}';
    Map<String, String> storage;
    try {
      final decoded = jsonDecode(storageRaw);
      storage = decoded is Map
          ? decoded.map(
              (key, value) => MapEntry<String, String>(
                key.toString(),
                value?.toString() ?? '',
              ),
            )
          : const <String, String>{};
    } catch (_) {
      storage = const <String, String>{};
    }
    return LinkCredential(
      platform: platform,
      loginUrl: loginUrl,
      finalUrl: raw['url']?.toString() ?? loginUrl,
      cookies: raw['cookies']?.toString() ?? '',
      storage: storage,
      savedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// 支持通过官方 WebView 登录页取凭证的平台，与 [SharePlatform] 展示名一致。
/// 登录页只负责拿到 Cookie / localStorage，协议解析另算，所以这里覆盖所有
/// 能用网页登录的平台，不依赖输入框里是否已经粘贴了链接。
const List<String> loginPlatforms = <String>[
  '夸克网盘',
  'UC 网盘',
  '百度网盘',
  '139 云盘',
  '迅雷网盘',
  '123 云盘',
  '115 网盘',
  '光鸭云盘',
  '蓝奏云',
  '蓝奏优享',
];

/// 官方登录页与 YunX 保持一致：移动端页面常有环境检测，PC 页在 WebView 里更稳；
/// 139 例外，用移动版登录页。
String? loginUrlFor(String platform) => switch (platform) {
      '夸克网盘' => 'https://pan.quark.cn/?fr=pc&platform=pc',
      'UC 网盘' => 'https://drive.uc.cn/',
      '百度网盘' => 'https://pan.baidu.com/',
      '139 云盘' => 'https://yun.139.com/m/#/login',
      '迅雷网盘' => 'https://pan.xunlei.com/',
      '123 云盘' => 'https://www.123pan.com/',
      '115 网盘' => 'https://115.com/',
      '光鸭云盘' => 'https://www.guangyapan.com/',
      '蓝奏云' => 'https://www.lanzoui.com/',
      '蓝奏优享' => 'https://www.ilanzou.com/',
      _ => null,
    };

/// 需要额外读取的 Cookie 域：139 的 fast-login 字段在 mail.10086.cn，
/// authorization 在 yun.139.com，两个都要取。
List<String> cookieDomainsFor(String platform) => switch (platform) {
      '139 云盘' => <String>['https://mail.10086.cn', 'https://yun.139.com'],
      _ => const <String>[],
    };

/// 是否用桌面端网页登录。
///
/// 多数网盘的移动版首页只有一个「下载 App」按钮、没有登录入口，桌面版才有
/// 账号密码 / 扫码登录；139 例外，它的登录页本身就是 `/m/` 移动版路径，
/// 强行套桌面 UA 反而会打不开，所以保持系统 UA。
bool desktopLoginFor(String platform) => platform != '139 云盘';

/// 支持账号密码直登的平台：不进网页，直接调登录接口换 access_token。
/// 目前只有迅雷（它的直链必须由登录态账号转存后换取，网页 Cookie 走不通）。
bool passwordLoginFor(String platform) => platform == '迅雷网盘';
