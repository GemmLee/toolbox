import 'dart:io';

import 'package:flutter/services.dart';

/// 导出到系统「下载」目录的结果。
class FileExportResult {
  const FileExportResult({
    required this.count,
    required this.failed,
    required this.dir,
  });

  /// 成功写入的文件数。
  final int count;

  /// 写入失败的文件数。
  final int failed;

  /// 目标目录（展示用，例如 `Download/XMtools`）。
  final String dir;

  bool get ok => count > 0;

  static FileExportResult? fromMap(Object? raw) {
    if (raw is! Map) return null;
    int at(String key) => (raw[key] as num?)?.toInt() ?? 0;
    return FileExportResult(
      count: at('count'),
      failed: at('failed'),
      dir: (raw['dir'] as String?) ?? 'Download/XMtools',
    );
  }
}

/// 分享 / 导出应用存储空间里的文件。
///
/// 原生侧用 `FileProvider` 把私有目录里的文件以 `content://` 交给系统分享面板，
/// 微信、QQ 等接收方读取的是临时授权的 URI，不需要申请存储权限。
class FileShare {
  FileShare._();

  static const MethodChannel _channel = MethodChannel('toolbox/file_share');

  /// 唤起系统分享面板；返回是否成功发起（用户是否真的发送不做判断）。
  static Future<bool> share(List<File> files, {String? subject}) async {
    final paths = files.map((f) => f.path).toList(growable: false);
    if (paths.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('share', <String, Object?>{
        'paths': paths,
        if (subject != null && subject.trim().isNotEmpty) 'subject': subject,
      });
      return ok == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 导出到系统「下载/XMtools」；平台不支持时返回 null。
  static Future<FileExportResult?> export(List<File> files) async {
    final paths = files.map((f) => f.path).toList(growable: false);
    if (paths.isEmpty) return null;
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'export',
        <String, Object?>{'paths': paths},
      );
      return FileExportResult.fromMap(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
