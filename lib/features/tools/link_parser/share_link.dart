import 'dart:convert';

/// 网盘平台。展示名与凭证表里保存的名字保持一致，避免两边各写一份映射。
enum SharePlatform {
  quark('夸克网盘'),
  uc('UC 网盘'),
  xunlei('迅雷网盘'),
  baidu('百度网盘'),
  c139('139 云盘'),
  pan123('123 云盘'),
  pan115('115 网盘'),
  guangya('光鸭云盘'),
  ilanzou('蓝奏优享'),
  lanzou('蓝奏云'),
  github('GitHub');

  const SharePlatform(this.label);

  final String label;

  static SharePlatform? ofLabel(String label) {
    for (final value in SharePlatform.values) {
      if (value.label == label) return value;
    }
    return null;
  }
}

/// 从分享链接里抠出的三要素。
class ParsedShare {
  const ParsedShare({
    required this.shareId,
    required this.platform,
    this.pwd,
  });

  final String shareId;
  final SharePlatform platform;
  final String? pwd;
}

/// 参照 YunX `ShareLinkParser`：从整段分享文案里识别平台、share_id 与提取码。
///
/// 规则全部是纯函数，方便单测锁住行为；导入时忽略文案里的多余标点，
/// 提取码优先 URL 参数，其次中文文案（「提取码：abcd」）。
class ShareLinkParser {
  ShareLinkParser._();

  static final RegExp _url = RegExp(r'https?://[^\s]+');
  static final RegExp _pwdInUrl = RegExp(r'[?&]pwd=([A-Za-z0-9]+)');
  static final RegExp _pwdInText =
      RegExp(r'(?:提取码|访问码|密码)[：:]\s*([A-Za-z0-9]{4,8})');
  static final RegExp _pwdIn115Url = RegExp(r'[?&]password=([A-Za-z0-9]+)');
  static final RegExp _pwdInLanzouUrl = RegExp(
      r'[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]+)',
      caseSensitive: false);

  static final List<_ShareRule> _rules = <_ShareRule>[
    _ShareRule(
      SharePlatform.quark,
      RegExp(r'pan\.quark\.cn/s/([A-Za-z0-9]+)', caseSensitive: false),
    ),
    _ShareRule(
      SharePlatform.uc,
      RegExp(r'drive\.uc\.cn/s/([A-Za-z0-9]+)', caseSensitive: false),
    ),
    _ShareRule(
      SharePlatform.xunlei,
      RegExp(r'pan\.xunlei\.com/s/([A-Za-z0-9_-]+)', caseSensitive: false),
    ),
    // 百度 surl 不带开头的 1，识别时保留完整 id，返回时再剥掉。
    _ShareRule(
      SharePlatform.baidu,
      RegExp(r'pan\.baidu\.com/s/(1[A-Za-z0-9_-]+)', caseSensitive: false),
      trimLeadingOne: true,
    ),
    _ShareRule(
      SharePlatform.c139,
      RegExp(r'yun\.139\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)',
          caseSensitive: false),
    ),
    _ShareRule(
      SharePlatform.pan123,
      RegExp(r'123(?:865|pan)\.(?:com|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)',
          caseSensitive: false),
    ),
    _ShareRule(
      SharePlatform.pan123,
      RegExp(r'share\.123pan\.cn/123pan/([A-Za-z0-9-]+)', caseSensitive: false),
    ),
    _ShareRule(
      SharePlatform.pan123,
      RegExp(r'api/srr\?sk=([A-Za-z0-9-]+)', caseSensitive: false),
    ),
    _ShareRule(
      SharePlatform.pan115,
      RegExp(r'115(?:cdn|rc)?\.com/s/(sw[A-Za-z0-9]+)', caseSensitive: false),
      passwordParam: 'password',
    ),
    _ShareRule(
      SharePlatform.guangya,
      RegExp(r'guangyapan\.com/s/([A-Za-z0-9_-]+)', caseSensitive: false),
    ),
    _ShareRule(
      SharePlatform.ilanzou,
      RegExp(r'(?:^|[/.])ilanzou\.(?:com|net|org|cn)/s/([A-Za-z0-9_-]+)',
          caseSensitive: false),
      passwordParam: 'lanzou',
    ),
    _ShareRule(
      SharePlatform.lanzou,
      RegExp(
          r'(?:^|[/.])(?:lanzou[a-z0-9-]*|lan[zs]o[ux]|lanzn)\.(?:com|net|org|cn)/([A-Za-z0-9]+)',
          caseSensitive: false),
      passwordParam: 'lanzou',
    ),
  ];

  static ParsedShare? parse(String input) {
    final text = input.trim();
    final raw = _url.firstMatch(text)?.group(0) ??
        (text.startsWith('http') ? text : '');
    if (raw.isEmpty) return null;
    final url = raw.replaceAll(r'''[。，,；;)\]}"']+$''', '');

    // 115 口令式链接：https://115.com/sws8lxs36jf-n307/
    final command = RegExp(
      r'115(?:cdn|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})',
      caseSensitive: false,
    ).firstMatch(url);
    if (command != null) {
      return ParsedShare(
        shareId: command.group(1)!,
        pwd: command.group(2),
        platform: SharePlatform.pan115,
      );
    }

    for (final rule in _rules) {
      final match = rule.pattern.firstMatch(url);
      if (match == null) continue;
      var id = match.group(1)!;
      if (rule.trimLeadingOne && id.startsWith('1')) {
        id = id.substring(1);
      }
      final String? pwd;
      switch (rule.passwordParam) {
        case 'password':
          pwd = _pwdIn115Url.firstMatch(url)?.group(1) ?? _pwdOfText(text);
        case 'lanzou':
          pwd = _pwdInLanzouUrl.firstMatch(url)?.group(1) ?? _pwdOfText(text);
        default:
          pwd = _pwdInUrl.firstMatch(url)?.group(1) ?? _pwdOfText(text);
      }
      return ParsedShare(shareId: id, pwd: pwd, platform: rule.platform);
    }
    return null;
  }

  static String? _pwdOfText(String text) =>
      _pwdInText.firstMatch(text)?.group(1);

  /// 139 的 Cookie 白名单：只对这几个字段感兴趣，其余埋点字段一律不带。
  static const Set<String> c139KeepKeys = <String>{
    'Os_SSo_Sid',
    'RMKEY',
    'UserData',
    'Login_UserNumber',
    '_139_index_isLoginType',
    'UUIDToken',
    'JSESSIONID',
    'areaCode8011',
    'provCode8011',
    'authorization',
    'auth_token',
    'token',
    'ud_id',
    'ORCHES-I-ACCOUNT-SIMPLIFY',
    'ORCHES-I-ACCOUNT-ENCRYPT',
    'nation_code',
  };

  static Map<String, String> cookieMap(String raw) {
    final result = <String, String>{};
    for (final part in raw.split(';')) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      result[part.substring(0, index).trim()] =
          part.substring(index + 1).trim();
    }
    return result;
  }

  static String c139Cookies(String raw) {
    final kept = <String, String>{};
    for (final entry in cookieMap(raw).entries) {
      if (c139KeepKeys.contains(entry.key) && entry.value.isNotEmpty) {
        kept.putIfAbsent(entry.key, () => entry.value);
      }
    }
    return kept.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  static String? c139Authorization(String raw) {
    final value = cookieMap(raw)['authorization'];
    return value == null || value.isEmpty ? null : value;
  }

  /// 139 账号：优先 base64 明文手机号，再 authorization 里的第二段，最后 Login_UserNumber。
  static String? c139Account(String raw) {
    final cookies = cookieMap(raw);
    final encrypted = cookies['ORCHES-I-ACCOUNT-ENCRYPT'];
    if (encrypted != null && encrypted.isNotEmpty) {
      try {
        final decoded = utf8.decode(base64Decode(encrypted));
        if (decoded.isNotEmpty) return decoded;
      } catch (_) {}
    }
    final auth = c139Authorization(raw);
    if (auth != null) {
      try {
        final decoded =
            utf8.decode(base64Decode(auth.replaceFirst('Basic', '').trim()));
        final parts = decoded.split(':');
        if (parts.length >= 2 && parts[1].isNotEmpty) return parts[1];
      } catch (_) {}
    }
    return cookies['Login_UserNumber'];
  }
}

class _ShareRule {
  const _ShareRule(
    this.platform,
    this.pattern, {
    this.trimLeadingOne = false,
    this.passwordParam = '',
  });

  final SharePlatform platform;
  final RegExp pattern;
  final bool trimLeadingOne;
  final String passwordParam;
}
