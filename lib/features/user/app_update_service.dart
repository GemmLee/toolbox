import 'dart:convert';

import 'package:http/http.dart' as http;

/// 发布页入口：无 APK asset 或拉取失败时的兜底地址。
const String kReleasePageUrl = 'https://github.com/GemmLee/toolbox/releases';

/// 一条 Release 更新信息：版本号来自 tag，下载地址来自 asset。
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    this.versionCode = 0,
    this.notes = '',
    this.downloadUrl = '',
    this.releaseUrl = '',
  });

  final String version;
  final int versionCode;
  final String notes;

  /// APK asset 直链；为空时回退到发布页。
  final String downloadUrl;

  /// Release 页面地址，作为无 APK asset 时的兜底。
  final String releaseUrl;

  String get openUrl => downloadUrl.isNotEmpty
      ? downloadUrl
      : (releaseUrl.isNotEmpty ? releaseUrl : kReleasePageUrl);

  factory AppUpdateInfo.fromReleaseJson(Map<String, dynamic> json) {
    final rawTag = (json['tag_name'] ?? json['tag'] ?? '').toString().trim();
    final tag = rawTag.startsWith('v') || rawTag.startsWith('V')
        ? rawTag.substring(1)
        : rawTag;
    final assets = json['assets'];
    var apkUrl = '';
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = '${asset['name'] ?? ''}'.toLowerCase();
        if (!name.endsWith('.apk')) continue;
        final url = '${asset['browser_download_url'] ?? ''}';
        if (url.isNotEmpty) {
          apkUrl = url;
          break;
        }
      }
    }
    return AppUpdateInfo(
      version: tag,
      notes: (json['body'] ?? json['name'] ?? '').toString().trim(),
      downloadUrl: apkUrl,
      releaseUrl: (json['html_url'] ?? '').toString().trim(),
    );
  }
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 更新检查：读取 GitHub 最新 Release 的 tag 与 APK asset。
class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    this.repository = kDefaultRepository,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client();

  static const String kDefaultRepository = 'GemmLee/toolbox';
  static const String kApiBaseUrl = 'https://api.github.com';

  final http.Client _client;
  final String repository;
  final Duration timeout;

  String get releaseApiUrl =>
      '$kApiBaseUrl/repos/$repository/releases/latest';

  Future<AppUpdateInfo> fetch() async {
    final http.Response resp;
    try {
      resp = await _client
          .get(Uri.parse(releaseApiUrl), headers: const <String, String>{
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'XMtools',
      }).timeout(timeout);
    } catch (_) {
      throw const AppUpdateException('网络请求失败，请稍后重试');
    }
    if (resp.statusCode == 404) {
      throw const AppUpdateException('暂无发布版本，请稍后重试');
    }
    if (resp.statusCode != 200) {
      throw const AppUpdateException('更新服务暂时不可用');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
    } on FormatException {
      throw const AppUpdateException('更新信息格式异常');
    }
    if (decoded is! Map) throw const AppUpdateException('更新信息格式异常');
    final info =
        AppUpdateInfo.fromReleaseJson(Map<String, dynamic>.from(decoded));
    if (info.version.isEmpty) {
      throw const AppUpdateException('更新信息格式异常');
    }
    return info;
  }

  void dispose() => _client.close();
}

/// 语义化版本比较：只比较数字段，忽略 `v` 前缀与构建元数据。
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
