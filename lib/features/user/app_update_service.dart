import 'dart:convert';

import 'package:http/http.dart' as http;

/// 应用更新清单：与 R2 上 `xmapk/version.json` 对应。
///
/// 只走公开 R2 域名，APP 内不保存任何密钥 / 私有签名域名。
/// 升级 APK 时只需更新 R2 上的清单与安装包，无需发版改代码。
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    this.versionCode = 0,
    this.notes = '',
    this.apkFile = '',
  });

  final String version;
  final int versionCode;
  final String notes;

  /// 相对 `xmapk/` 的对象名；为空时回退到默认安装包名。
  final String apkFile;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      version: (json['version'] ?? '').toString().trim(),
      versionCode: json['versionCode'] is num
          ? (json['versionCode'] as num).toInt()
          : int.tryParse('${json['versionCode']}') ?? 0,
      notes: (json['notes'] ?? json['note'] ?? '').toString(),
      apkFile: (json['apkFile'] ?? json['file'] ?? '').toString().trim(),
    );
  }

  /// 完整下载直链（公开 R2 域名 + xmapk/ 目录）。
  String apkUrl(String baseUrl) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final name =
        apkFile.isEmpty ? 'XMtools-$version.apk' : apkFile.split('/').last;
    return '$base/xmapk/${Uri.encodeComponent(name)}';
  }
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// R2 更新检查：拉取 version.json 并与本地版本比较。
///
/// [client] 与 [baseUrl] 可注入，便于测试；超时统一由 [timeout] 控制。
class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    this.baseUrl = kPublicResourceBaseUrl,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client();

  /// 公开 R2 域名（与网页 xmhome.html、题库索引一致）。仅公开可读对象。
  static const String kPublicResourceBaseUrl = 'https://xmonline-sgcc.r2.dev';
  static const String manifestPath = 'xmapk/version.json';

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  String get manifestUrl {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$base/$manifestPath';
  }

  Future<AppUpdateInfo> fetch() async {
    final http.Response resp;
    try {
      resp = await _client
          .get(Uri.parse(manifestUrl), headers: const <String, String>{
        'Accept': 'application/json',
      }).timeout(timeout);
    } catch (e) {
      throw AppUpdateException('网络请求失败：$e');
    }
    if (resp.statusCode != 200) {
      throw AppUpdateException('更新服务返回 HTTP ${resp.statusCode}');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
    } on FormatException {
      throw const AppUpdateException('更新清单不是有效的 JSON');
    }
    if (decoded is! Map) throw const AppUpdateException('更新清单格式异常');
    final info = AppUpdateInfo.fromJson(Map<String, dynamic>.from(decoded));
    if (info.version.isEmpty) {
      throw const AppUpdateException('更新清单缺少 version 字段');
    }
    return info;
  }

  void dispose() => _client.close();
}

/// 语义化版本比较：只比较数字段，忽略 `v` 前缀与构建元数据。
///
/// 返回 true 表示 [latest] 比 [current] 新；段数不足时用 0 补齐。
bool isNewerVersion(String latest, String current) {
  List<int> parse(String value) {
    final cleaned = value.trim().toLowerCase();
    final core = cleaned.startsWith('v') ? cleaned.substring(1) : cleaned;
    final main = core.split(RegExp(r'[+\-]')).first;
    return main
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
  }

  final a = parse(latest);
  final b = parse(current);
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final av = i < a.length ? a[i] : 0;
    final bv = i < b.length ? b[i] : 0;
    if (av != bv) return av > bv;
  }
  return false;
}
