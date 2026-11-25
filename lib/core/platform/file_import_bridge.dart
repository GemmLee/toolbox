import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../settings/default_open_tools.dart';
import '../settings/settings_controller.dart';
import '../storage/app_files.dart';

/// 一次待处理的外部导入：归档后的文件 + 按设置解析出的默认动作。
class PendingImport {
  const PendingImport(this.file, this.action);

  final StoredFile file;
  final DefaultOpenAction action;
}

/// 外部 App（微信 / QQ 等）「用其他应用打开 / 分享」文件的接收端。
///
/// 原生侧先把文件复制进私有临时目录并缓存一份待取清单（见 MainActivity.kt），
/// 这里按「用户 → 默认打开工具」的设置把文件归档到应用存储空间
/// （「用户 → 存储空间」可见），然后删掉临时副本。
///
/// 冷启动与热启动两条路径都要覆盖：启动后主动 [drain]，运行期间收到
/// `onFilesImported` 再 drain 一次；原生队列是唯一数据源，因此不会重复导入。
class FileImportBridge extends ChangeNotifier {
  FileImportBridge._();

  static final FileImportBridge instance = FileImportBridge._();

  static const MethodChannel _channel = MethodChannel('toolbox/file_import');

  /// XMtools 内部能处理的扩展名（与「默认打开工具」设置里的格式一致）。
  /// 其余类型即使被系统派发过来也不写入存储空间。
  static Set<String> get supportedExtensions => kSupportedImportExtensions;

  bool _initialized = false;
  PendingImport? _pendingOpen;
  int _rejected = 0;
  String? _lastError;

  /// 取走最近一次成功导入的「文件 + 默认动作」，供应用外壳决定打开哪个工具。
  PendingImport? takePending() {
    final pending = _pendingOpen;
    _pendingOpen = null;
    return pending;
  }

  /// 兼容旧调用：只要文件，不关心动作（取走即清空）。
  StoredFile? takePendingOpen() => takePending()?.file;

  int get rejected => _rejected;
  String? get lastError => _lastError;

  static bool isSupported(String fileName) {
    final ext = p.extension(fileName).toLowerCase();
    return supportedExtensions
        .contains(ext.startsWith('.') ? ext.substring(1) : ext);
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onFilesImported') await drain();
      return null;
    });
    await drain();
  }

  /// 取走原生侧待处理清单；测试环境没有插件时静默降级。
  Future<int> drain() async {
    List<dynamic> pending;
    try {
      pending = await _channel.invokeListMethod<dynamic>('consumePending') ??
          const <dynamic>[];
    } on MissingPluginException {
      return 0;
    } on PlatformException {
      return 0;
    } catch (_) {
      return 0;
    }
    var count = 0;
    for (final item in pending) {
      if (item is! Map) continue;
      final path = item['path'];
      final name = item['name'];
      if (path is! String || path.isEmpty) continue;
      final stored = await adoptPath(
        path,
        name: name is String ? name : null,
      );
      if (stored != null) count++;
    }
    return count;
  }

  /// 归档一个本地文件；[deleteSource] 供 App 内手动导入时保留原文件，
  /// [requestOpen] 为 false 时留在列表页，不自动跳到阅读器。
  Future<StoredFile?> adoptPath(
    String path, {
    String? name,
    bool deleteSource = true,
    bool requestOpen = true,
  }) async {
    final source = File(path);
    try {
      if (!await source.exists()) {
        _lastError = '$path not found';
        notifyListeners();
        return null;
      }
      final displayName = name ?? p.basename(path);
      if (!isSupported(displayName)) {
        _rejected++;
        _lastError = 'unsupported:$displayName';
        if (deleteSource) await _safeDelete(source);
        notifyListeners();
        return null;
      }
      // 按「用户 → 默认打开工具」的设置决定动作与归档目录：题库 JSON
      // 走刷题助手目录，其余仍放文字阅读器目录。两者都能在阅读器列表里看到。
      final action =
          SettingsController.instance.defaultOpenActionFor(displayName);
      final category = action == DefaultOpenAction.quizBank
          ? AppStoreCategory.quiz
          : AppStoreCategory.reader;
      final stored = await AppStore.adopt(
        category: category,
        source: source,
        name: displayName,
      );
      if (deleteSource) await _safeDelete(source);
      _lastError = null;
      if (requestOpen) _pendingOpen = PendingImport(stored, action);
      notifyListeners();
      return stored;
    } catch (e) {
      _lastError = '$e';
      notifyListeners();
      return null;
    }
  }

  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 临时文件删除失败不影响归档结果。
    }
  }

  void resetForTest() {
    _initialized = false;
    _pendingOpen = null;
    _rejected = 0;
    _lastError = null;
  }
}
