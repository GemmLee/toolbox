import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 下载任务状态。
enum DownloadStatus {
  queued('排队中'),
  running('下载中'),
  paused('已暂停'),
  done('已完成'),
  failed('失败'),
  canceled('已取消');

  const DownloadStatus(this.label);

  final String label;

  bool get isActive => this == queued || this == running;
}

/// 一条下载任务（对应 YunX `DownloadTaskEntity` 的精简版）。
///
/// 字段用可变形态：进度每秒要刷几十次，`copyWith` 出来的新对象会让列表里
/// 正在被 `await` 的引用失联。可变 + 通知列表刷新更直接。
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.url,
    required this.name,
    this.platform = '',
    this.createdAt = 0,
    this.referer = '',
    this.userAgent = '',
    this.headers = const <String, String>{},
    this.total = 0,
    this.done = 0,
    this.status = DownloadStatus.queued,
    this.error = '',
    this.savedPath = '',
    this.localPath = '',
    this.savedToPhone = false,
    this.updatedAt = 0,
  });

  final String id;
  final String url;
  final String name;
  final String platform;
  final int createdAt;
  final String referer;
  final String userAgent;
  final Map<String, String> headers;

  int total;
  int done;

  /// 运行时的瞬时速度（字节/秒），不持久化。
  int speed = 0;

  DownloadStatus status;
  String error;

  /// 完成后的落盘位置：应用存储空间是绝对路径，手机目录是「下载/…」这类显示路径。
  String savedPath;

  /// 成品在本机上的真实路径，用于预览 / 分享；拿不到时为空。
  String localPath;
  bool savedToPhone;
  int updatedAt;

  /// 运行时状态：用户点了暂停 / 取消。
  bool pauseRequested = false;
  bool cancelRequested = false;

  /// 等待这条任务结束（成功 / 失败 / 取消）用；不持久化。
  final Completer<DownloadTask> completer = Completer<DownloadTask>();

  double get progress {
    if (total <= 0) return 0;
    return (done / total).clamp(0.0, 1.0);
  }

  bool get finished =>
      status == DownloadStatus.done ||
      status == DownloadStatus.failed ||
      status == DownloadStatus.canceled;

  /// 文件前缀：用于和同任务的临时文件对齐，暂停后重下能续传。
  String get tempPrefix => 'xmt_${id}_';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'url': url,
        'name': name,
        'platform': platform,
        'createdAt': createdAt,
        'referer': referer,
        'userAgent': userAgent,
        'headers': headers,
        'total': total,
        'done': done,
        'status': status.name,
        'error': error,
        'savedPath': savedPath,
        'localPath': localPath,
        'savedToPhone': savedToPhone,
        'updatedAt': updatedAt,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    int intOf(String key, [int fallback = 0]) {
      final value = json[key];
      if (value is num) return value.toInt();
      return int.tryParse('${value ?? ''}') ?? fallback;
    }

    var status = DownloadStatus.queued;
    final rawStatus = (json['status'] ?? '').toString();
    for (final item in DownloadStatus.values) {
      if (item.name == rawStatus) status = item;
    }
    // 上次进程被杀时还在跑的任务：重启后按暂停处理，用户可以手动继续。
    if (status == DownloadStatus.running) status = DownloadStatus.paused;

    return DownloadTask(
      id: (json['id'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      platform: (json['platform'] ?? '').toString(),
      createdAt: intOf('createdAt'),
      referer: (json['referer'] ?? '').toString(),
      userAgent: (json['userAgent'] ?? '').toString(),
      headers: _stringMap(json['headers']),
      total: intOf('total'),
      done: intOf('done'),
      status: status,
      error: (json['error'] ?? '').toString(),
      savedPath: (json['savedPath'] ?? '').toString(),
      localPath: (json['localPath'] ?? '').toString(),
      savedToPhone: json['savedToPhone'] == true,
      updatedAt: intOf('updatedAt'),
    );
  }

  /// 只会被 [_markFinished] 之外的流程调用一次；重复调用直接忽略。
  void complete() {
    if (!completer.isCompleted) completer.complete(this);
  }

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

/// 下载记录的持久化：SharedPreferences 里一个 JSON 数组，最多留 200 条。
class DownloadTaskStore {
  DownloadTaskStore._();

  static const String storeKey = 'link_download_tasks_v1';
  static const int maxTasks = 200;

  static Future<List<DownloadTask>> load({
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    try {
      final prefs = await (prefsLoader ?? SharedPreferences.getInstance)();
      final raw = prefs.getString(storeKey);
      if (raw == null || raw.isEmpty) return <DownloadTask>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <DownloadTask>[];
      return decoded
          .whereType<Map>()
          .map((m) => DownloadTask.fromJson(m.cast<String, dynamic>()))
          .where((task) => task.id.isNotEmpty && task.url.isNotEmpty)
          .toList();
    } catch (_) {
      return <DownloadTask>[];
    }
  }

  static Future<void> save(
    List<DownloadTask> tasks, {
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    final prefs = await (prefsLoader ?? SharedPreferences.getInstance)();
    final trimmed = tasks.length > maxTasks
        ? tasks.sublist(tasks.length - maxTasks)
        : tasks;
    await prefs.setString(
      storeKey,
      jsonEncode(trimmed.map((task) => task.toJson()).toList()),
    );
  }

  @visibleForTesting
  static Future<void> clear({
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    final prefs = await (prefsLoader ?? SharedPreferences.getInstance)();
    await prefs.remove(storeKey);
  }
}
