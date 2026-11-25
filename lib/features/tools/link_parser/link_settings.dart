import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 下载文件的落盘位置。
enum LinkSaveTarget {
  /// 应用存储空间：`用户 → 存储空间 → 其他`，卸载应用才会没。
  appStorage('应用存储空间'),

  /// 手机下载目录：系统「文件管理 / 下载」里能直接看到，别的应用也能读。
  phone('手机下载目录');

  const LinkSaveTarget(this.label);

  final String label;
}

/// 链接解析工具的运行设置（对齐 YunX 下载设置页里的常用项）。
///
/// 只保留「改了对下载真的有影响」的项：保存位置、分片线程、并发任务数、
/// 全局限速、失败重试。通知、后台保活这类需要常驻服务的项不做。
@immutable
class LinkSettings {
  const LinkSettings({
    this.saveTarget = LinkSaveTarget.appStorage,
    this.phoneDir = defaultPhoneDir,
    this.threads = 4,
    this.concurrency = 2,
    this.speedLimitBps = 0,
    this.retries = 1,
  });

  /// 手机下载目录下的默认子目录（相对 `Download/`）。
  static const String defaultPhoneDir = 'Toolbox/链接解析';

  final LinkSaveTarget saveTarget;

  /// 手机下载目录下的相对子目录，空则直接落在 `Download/`。
  final String phoneDir;

  /// 单任务分片线程数（服务端不支持 Range 时自动退回单流）。
  final int threads;

  /// 同时下载的任务数。
  final int concurrency;

  /// 全局限速，0 表示不限。
  final int speedLimitBps;

  /// 失败自动重试次数。
  final int retries;

  bool get toPhone => saveTarget == LinkSaveTarget.phone;

  LinkSettings copyWith({
    LinkSaveTarget? saveTarget,
    String? phoneDir,
    int? threads,
    int? concurrency,
    int? speedLimitBps,
    int? retries,
  }) =>
      LinkSettings(
        saveTarget: saveTarget ?? this.saveTarget,
        phoneDir: phoneDir ?? this.phoneDir,
        threads: threads ?? this.threads,
        concurrency: concurrency ?? this.concurrency,
        speedLimitBps: speedLimitBps ?? this.speedLimitBps,
        retries: retries ?? this.retries,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'saveTarget': saveTarget.name,
        'phoneDir': phoneDir,
        'threads': threads,
        'concurrency': concurrency,
        'speedLimitBps': speedLimitBps,
        'retries': retries,
      };

  factory LinkSettings.fromJson(Map<String, dynamic> json) {
    LinkSaveTarget target = LinkSaveTarget.appStorage;
    final rawTarget = (json['saveTarget'] ?? '').toString();
    for (final item in LinkSaveTarget.values) {
      if (item.name == rawTarget) target = item;
    }
    int intOf(String key, int fallback) {
      final value = json[key];
      if (value is num) return value.toInt();
      return int.tryParse('${value ?? ''}') ?? fallback;
    }

    return LinkSettings(
      saveTarget: target,
      phoneDir: (json['phoneDir'] ?? defaultPhoneDir).toString(),
      threads: intOf('threads', 4).clamp(1, 16),
      concurrency: intOf('concurrency', 2).clamp(1, 5),
      speedLimitBps: intOf('speedLimitBps', 0).clamp(0, 1 << 30),
      retries: intOf('retries', 1).clamp(0, 5),
    );
  }
}

/// 设置的读写与全局可监听副本。
///
/// 页面、下载管理器都读 [current]，设置页改完立即生效，不需要重启工具。
class LinkSettingsStore {
  LinkSettingsStore._();

  static const String storeKey = 'link_settings_v1';

  static final ValueNotifier<LinkSettings> current =
      ValueNotifier<LinkSettings>(const LinkSettings());

  static Future<LinkSettings> load({
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    try {
      final prefs = await (prefsLoader ?? SharedPreferences.getInstance)();
      final raw = prefs.getString(storeKey);
      if (raw == null || raw.isEmpty) {
        current.value = const LinkSettings();
        return current.value;
      }
      final decoded = jsonDecode(raw);
      final settings = decoded is Map
          ? LinkSettings.fromJson(decoded.cast<String, dynamic>())
          : const LinkSettings();
      current.value = settings;
      return settings;
    } catch (_) {
      current.value = const LinkSettings();
      return current.value;
    }
  }

  static Future<void> save(
    LinkSettings settings, {
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    current.value = settings;
    final prefs = await (prefsLoader ?? SharedPreferences.getInstance)();
    await prefs.setString(storeKey, jsonEncode(settings.toJson()));
  }

  /// 测试用：直接改内存里的当前值，不碰磁盘。
  @visibleForTesting
  static void useForTest(LinkSettings settings) => current.value = settings;

  @visibleForTesting
  static void resetForTest() => current.value = const LinkSettings();
}

/// 把「手机下载目录」的配置整理成 MediaStore 用的相对路径。
///
/// 结果形如 `Download/Toolbox/链接解析`，去掉首尾斜杠、过滤 `..`，
/// 避免设置里写进奇怪的路径把文件丢到别处。
String phoneRelativeDir(String configured) {
  final cleaned = configured
      .replaceAll('\\', '/')
      .split('/')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty && part != '.' && part != '..')
      .join('/');
  if (cleaned.isEmpty) return 'Download';
  return cleaned.startsWith('Download') ? cleaned : 'Download/$cleaned';
}
