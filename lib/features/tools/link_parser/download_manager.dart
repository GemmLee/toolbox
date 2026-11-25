import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/storage/app_files.dart';
import 'download_task.dart';
import 'link_downloader.dart';
import 'link_settings.dart';

/// 导出到公共下载目录后的结果。
class PublicSaveResult {
  const PublicSaveResult({required this.displayPath, required this.localPath});

  /// 给人看的位置，如 `Download/Toolbox/链接解析/a.mp4`。
  final String displayPath;

  /// 本机绝对路径，用于预览 / 分享；系统没给时为空。
  final String localPath;
}

/// 把「应用私有存储」里的文件导出到系统公共下载目录。
///
/// 走原生的 MediaStore（Android 10+）或公共目录直写，不需要用户手动授权整个
/// 存储权限；原生侧负责按 `Download/<子目录>/` 建目录、去重、写 MIME。
class PublicDownloadSaver {
  PublicDownloadSaver({this.invoker});

  static const MethodChannel _channel = MethodChannel('toolbox/link_webview');

  /// 测试注入：替代真实 MethodChannel。
  final Future<Map<dynamic, dynamic>?> Function(Map<String, dynamic> args)?
      invoker;

  Future<PublicSaveResult> export(
    File file, {
    required String relativeDir,
    required String name,
  }) async {
    final args = <String, dynamic>{
      'path': file.path,
      'relativeDir': relativeDir,
      'name': name,
    };
    final raw = invoker != null
        ? await invoker!(args)
        : await _channel.invokeMapMethod<dynamic, dynamic>(
            'exportDownload',
            args,
          );
    final display = raw?['displayPath']?.toString() ?? '';
    if (display.isEmpty) {
      throw StateError('系统没有返回保存位置');
    }
    return PublicSaveResult(
      displayPath: display,
      localPath: raw?['localPath']?.toString() ?? '',
    );
  }
}

/// 下载管理器：队列、并发、限速、暂停/继续、落盘归档。
///
/// 全应用一个实例（[instance]），页面只负责把任务丢进来，进度统一从这里读。
/// 「下载页」和「解析页」看到的是同一份列表，不会出现两个地方各记一套的问题。
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    Future<Directory> Function()? tempDirLoader,
    PublicDownloadSaver? publicSaver,
    Future<PublicSaveResult> Function(DownloadTask, File, LinkSettings)? saver,
    @visibleForTesting LinkDownloader Function()? downloaderFactory,
  })  : _tempDirLoader = tempDirLoader,
        _publicSaver = publicSaver ?? PublicDownloadSaver(),
        _saver = saver,
        _downloaderFactory = downloaderFactory;

  static DownloadManager? _instance;

  static DownloadManager get instance => _instance ??= DownloadManager();

  @visibleForTesting
  static void resetForTest({DownloadManager? manager}) {
    _instance?.dispose();
    _instance = manager;
  }

  final Future<Directory> Function()? _tempDirLoader;
  final PublicDownloadSaver _publicSaver;
  final Future<PublicSaveResult> Function(
      DownloadTask, File, LinkSettings)? _saver;
  final LinkDownloader Function()? _downloaderFactory;

  final List<DownloadTask> _tasks = <DownloadTask>[];
  final Map<String, _SpeedSample> _samples = <String, _SpeedSample>{};

  bool _loaded = false;
  bool _disposed = false;
  Timer? _saveTimer;
  Timer? _notifyTimer;

  /// 下载记录（新→旧），页面直接监听本对象刷新。
  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_tasks);

  bool get hasActive => _tasks.any((task) => task.status.isActive);

  int get activeCount =>
      _tasks.where((task) => task.status == DownloadStatus.running).length;

  /// 首次进入页面时从磁盘恢复记录；只做一次。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    // 保存位置 / 线程数在这里就绪，避免下载任务抢在设置读出来之前按默认值跑。
    await LinkSettingsStore.load();
    final restored = await DownloadTaskStore.load();
    _tasks
      ..clear()
      ..addAll(restored);
    _sort();
    _notify();
  }

  /// 新建任务并排队；返回的任务可以用 `task.completer.future` 等结束。
  DownloadTask enqueue({
    required String url,
    required String name,
    String platform = '',
    int size = 0,
    String referer = '',
    String userAgent = '',
    Map<String, String> headers = const <String, String>{},
  }) {
    final now = DateTime.now();
    final task = DownloadTask(
      id: '${now.microsecondsSinceEpoch}',
      url: url,
      name: name.isEmpty ? _nameFromUrl(url) : name,
      platform: platform,
      createdAt: now.millisecondsSinceEpoch,
      referer: referer,
      userAgent: userAgent,
      headers: headers,
      total: size,
      status: DownloadStatus.queued,
      updatedAt: now.millisecondsSinceEpoch,
    );
    _tasks.insert(0, task);
    _sort();
    _notify();
    _scheduleSave();
    _pump();
    return task;
  }

  /// 暂停：正在跑的让下载循环退出（保留临时文件，继续时断点续传）。
  void pause(DownloadTask task) {
    if (task.status == DownloadStatus.running) {
      task.pauseRequested = true;
      return;
    }
    if (task.status == DownloadStatus.queued) {
      task.status = DownloadStatus.paused;
      task.updatedAt = DateTime.now().millisecondsSinceEpoch;
      _notify();
      _scheduleSave();
    }
  }

  /// 继续 / 重试：重新排队，已下载的字节数和临时文件都留着。
  void resume(DownloadTask task) {
    if (task.status.isActive) return;
    if (task.status == DownloadStatus.done) return;
    task
      ..status = DownloadStatus.queued
      ..error = ''
      ..speed = 0
      ..pauseRequested = false
      ..cancelRequested = false
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    _notify();
    _scheduleSave();
    _pump();
  }

  /// 取消：连临时文件一起删掉，之后只能从头下。
  Future<void> cancel(DownloadTask task) async {
    if (task.status.isActive) {
      task.cancelRequested = true;
      // 排队中的任务没有下载循环在跑，直接落地成已取消。
      if (task.status == DownloadStatus.queued) {
        _finish(task, DownloadStatus.canceled);
      }
      return;
    }
    await _deleteTemp(task);
    _finish(task, DownloadStatus.canceled);
  }

  /// 只删记录，磁盘上的成品文件保留（用户可能已经移动 / 改过名）。
  Future<void> remove(DownloadTask task) async {
    task.cancelRequested = true;
    await _deleteTemp(task);
    _tasks.remove(task);
    _samples.remove(task.id);
    _notify();
    _scheduleSave();
  }

  Future<void> clearFinished() async {
    _tasks.removeWhere((task) => task.finished);
    _notify();
    _scheduleSave();
  }

  /// 清空记录并删掉所有临时文件（成品文件不动）。
  Future<void> clearAll() async {
    for (final task in _tasks) {
      task.cancelRequested = true;
    }
    _tasks.clear();
    _samples.clear();
    _notify();
    _scheduleSave();
    await _cleanTempDir();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _notifyTimer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------ 调度

  void _pump() {
    if (_disposed) return;
    final settings = LinkSettingsStore.current.value;
    var slots = settings.concurrency -
        _tasks.where((task) => task.status == DownloadStatus.running).length;
    if (slots <= 0) return;
    for (final task in List<DownloadTask>.from(_tasks)) {
      if (slots <= 0) break;
      if (task.status != DownloadStatus.queued) continue;
      slots--;
      unawaited(_run(task, settings));
    }
  }

  Future<void> _run(DownloadTask task, LinkSettings settings) async {
    task
      ..status = DownloadStatus.running
      ..error = ''
      ..pauseRequested = false
      ..cancelRequested = false
      ..speed = 0
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    _notify();
    _scheduleSave();

    bool canceled() => task.pauseRequested || task.cancelRequested;

    try {
      DownloadedFile? downloaded;
      Object? lastError;
      for (var attempt = 0; attempt <= settings.retries; attempt++) {
        try {
          downloaded = await _download(task, settings, canceled);
          lastError = null;
          break;
        } on DownloadCanceledException {
          rethrow;
        } catch (e) {
          lastError = e;
          if (canceled()) rethrow;
          if (attempt == settings.retries) rethrow;
          task.error = '$e';
          _notify();
          await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        }
      }
      final result = downloaded;
      if (result == null) {
        throw lastError ?? StateError('下载失败');
      }
      final saved = await _persist(task, result.file, settings);
      task
        ..savedPath = saved.displayPath
        ..localPath = saved.localPath
        ..savedToPhone = settings.toPhone
        ..done = result.bytes
        ..speed = 0;
      if (task.total <= 0) task.total = result.bytes;
      _finish(task, DownloadStatus.done);
    } on DownloadCanceledException {
      if (task.cancelRequested) {
        await _deleteTemp(task);
        _finish(task, DownloadStatus.canceled);
      } else {
        _finish(task, DownloadStatus.paused);
      }
    } catch (e) {
      task.error = _readableError(e);
      _finish(task, DownloadStatus.failed);
    } finally {
      _pump();
    }
  }

  Future<DownloadedFile> _download(
    DownloadTask task,
    LinkSettings settings,
    bool Function() isCanceled,
  ) async {
    final downloader = _downloaderFactory?.call() ??
        LinkDownloader(
          threads: settings.threads,
          speedLimitBytesPerSecond: settings.speedLimitBps,
          headers: <String, String>{
            if (task.userAgent.isNotEmpty) 'User-Agent': task.userAgent,
            if (task.referer.isNotEmpty) 'Referer': task.referer,
            ...task.headers,
          },
          tempDirLoader: _tempDirLoader,
        );
    final watch = Stopwatch()..start();
    return downloader.download(
      task.url,
      name: task.name,
      tempKey: task.id,
      isCanceled: isCanceled,
      onProgress: (done, total) {
        task.done = done;
        if (total > 0) task.total = total;
        _sampleSpeed(task, done, watch);
        _throttledNotify();
      },
    );
  }

  /// 归档到应用存储空间或系统下载目录；返回给用户看的路径与真实路径。
  Future<PublicSaveResult> _persist(
    DownloadTask task,
    File file,
    LinkSettings settings,
  ) async {
    final custom = _saver;
    if (custom != null) return custom(task, file, settings);
    if (settings.toPhone) {
      final saved = await _publicSaver.export(
        file,
        relativeDir: phoneRelativeDir(settings.phoneDir),
        name: task.name,
      );
      if (await file.exists()) await file.delete();
      return saved;
    }
    final stored = await AppStore.adopt(
      category: AppStoreCategory.other,
      source: file,
      name: task.name,
    );
    if (await file.exists()) await file.delete();
    return PublicSaveResult(
      displayPath: stored.path,
      localPath: stored.path,
    );
  }

  void _finish(DownloadTask task, DownloadStatus status) {
    task
      ..status = status
      ..speed = 0
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    if (status != DownloadStatus.running) _samples.remove(task.id);
    _notify();
    _scheduleSave();
    task.complete();
  }

  // ------------------------------------------------------------------ 工具

  Future<Directory> _tempDir() async {
    final loader = _tempDirLoader;
    if (loader != null) return loader();
    try {
      // 放在应用支持目录而不是缓存目录：缓存页的「一键清理」不会把正在下载的
      // 半截文件删掉，卸载应用时才会一起清掉。
      final base = await getApplicationSupportDirectory();
      final dir = Directory(p.join(base.path, 'link_downloads'));
      if (!dir.existsSync()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  Future<void> _deleteTemp(DownloadTask task) async {
    try {
      final dir = await _tempDir();
      if (!dir.existsSync()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && p.basename(entity.path).startsWith(task.tempPrefix)) {
          await entity.delete();
        }
      }
    } catch (_) {
      // 临时目录不可用时不必报错：下次下载会重新建文件。
    }
  }

  Future<void> _cleanTempDir() async {
    try {
      final dir = await _tempDir();
      if (!dir.existsSync()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && p.basename(entity.path).startsWith('xmt_')) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  void _sampleSpeed(DownloadTask task, int done, Stopwatch watch) {
    final sample = _samples[task.id] ??= _SpeedSample(done, watch.elapsed);
    final elapsed = watch.elapsed - sample.at;
    if (elapsed < const Duration(milliseconds: 500)) return;
    final delta = done - sample.bytes;
    task.speed = elapsed.inMicroseconds <= 0
        ? 0
        : (delta * 1000000 / elapsed.inMicroseconds).round();
    sample
      ..bytes = done
      ..at = watch.elapsed;
  }

  void _sort() {
    // 列表按创建时间倒序：新任务在上，已完成的老任务压到底部。
    _tasks.sort((a, b) {
      final activeA = a.status.isActive ? 1 : 0;
      final activeB = b.status.isActive ? 1 : 0;
      if (activeA != activeB) return activeB.compareTo(activeA);
      return b.createdAt.compareTo(a.createdAt);
    });
  }

  void _notify() {
    _sort();
    if (!_disposed) notifyListeners();
  }

  /// 进度回调很密集，UI 每秒刷 8 次足够，避免整页重建把列表拖慢。
  void _throttledNotify() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 120), _notify);
  }

  void _scheduleSave() {
    if (_disposed) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      unawaited(DownloadTaskStore.save(_tasks));
    });
  }

  static String _nameFromUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final name = path.split('/').where((part) => part.isNotEmpty).lastOrNull;
    if (name == null || name.isEmpty) return 'download';
    return Uri.decodeComponent(name);
  }

  static String _readableError(Object error) {
    final text = error is StateError ? error.message : '$error';
    if (text.contains('HTTP 403')) return '服务器拒绝访问（403），链接可能已过期或需要登录';
    if (text.contains('HTTP 404')) return '文件不存在（404）';
    if (text.contains('TimeoutException') || text.contains('超时')) {
      return '连接超时，请检查网络后重试';
    }
    if (text.contains('SocketException')) return '网络中断，请重试';
    return text;
  }
}

class _SpeedSample {
  _SpeedSample(this.bytes, this.at);

  int bytes;
  Duration at;
}
