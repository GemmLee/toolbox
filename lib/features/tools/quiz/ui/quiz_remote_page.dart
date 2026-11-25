import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/settings/settings_controller.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../link_parser/download_manager.dart';
import '../../link_parser/download_task.dart';
import '../data/quiz_repository.dart';
import '../logic/quiz_import.dart';
import '../logic/quiz_remote_index.dart';
import 'quiz_common.dart';
import 'quiz_import_page.dart';

/// 在线题库：从 R2 读取 index.json，列出文件并按需下载、导入。
///
/// [service] / [cache] / [download] 均可注入，便于 widget 测试不碰真实 I/O。
class QuizRemotePage extends StatefulWidget {
  const QuizRemotePage({
    super.key,
    required this.repo,
    QuizIndexService? service,
    QuizIndexCache? cache,
    Future<DownloadTask> Function(QuizRemoteFile file)? downloader,
  })  : _service = service,
        _cache = cache,
        _downloader = downloader;

  final QuizRepository repo;
  final QuizIndexService? _service;
  final QuizIndexCache? _cache;
  final Future<DownloadTask> Function(QuizRemoteFile file)? _downloader;

  @override
  State<QuizRemotePage> createState() => _QuizRemotePageState();
}

class _QuizRemotePageState extends State<QuizRemotePage> {
  late QuizIndexService _service;
  late QuizIndexCache _cache;
  List<QuizRemoteFile> _files = const <QuizRemoteFile>[];
  bool _loading = true;
  String? _error;
  final Set<String> _busyIds = <String>{};

  @override
  void initState() {
    super.initState();
    final override = SettingsController.instance.quizResourceBaseUrl;
    final baseUrl = override.isEmpty
        ? QuizIndexService.kDefaultQuizResourceBaseUrl
        : override;
    _service = widget._service ?? QuizIndexService(baseUrl: baseUrl);
    _cache = widget._cache ?? QuizIndexCache();
    _load(useCacheFirst: true);
  }

  @override
  void dispose() {
    if (widget._service == null) _service.dispose();
    super.dispose();
  }

  Future<void> _load({required bool useCacheFirst}) async {
    if (useCacheFirst) {
      final cached = await _cache.read();
      if (cached != null && cached.isNotEmpty && mounted) {
        setState(() {
          _files = cached;
          _loading = false;
        });
      }
    }
    try {
      final files = await _service.fetch();
      await _cache.save(files);
      if (!mounted) return;
      setState(() {
        _files = files;
        _error = null;
        _loading = false;
      });
    } on QuizIndexException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _downloadAndImport(QuizRemoteFile file) async {
    if (_busyIds.contains(file.id)) return;
    setState(() => _busyIds.add(file.id));
    try {
      final task = widget._downloader != null
          ? await widget._downloader!(file)
          : await _enqueue(file);
      final finished = await task.completer.future;
      if (finished.status != DownloadStatus.done || !mounted) {
        if (mounted) {
          showToast(
              context, finished.error.isEmpty ? tr('下载失败') : finished.error);
        }
        return;
      }
      final path = finished.localPath.isNotEmpty
          ? finished.localPath
          : finished.savedPath;
      if (path.isEmpty || !File(path).existsSync()) {
        showToast(context, tr('文件已下载，但无法读取本地路径'));
        return;
      }
      final text = await File(path).readAsString();
      final preview = QuizImporter.parse(text);
      if (!mounted) return;
      final navigator = Navigator.of(context);
      final ok = await navigator.push<bool>(
        quizRoute<bool>(
            builder: (_) =>
                QuizImportPage(repo: widget.repo, preview: preview)),
      );
      if (ok == true && mounted) showToast(context, tr('导入成功'));
    } on ImportError catch (e) {
      if (mounted) showToast(context, '${tr('导入失败')}：$e');
    } catch (e) {
      if (mounted) showToast(context, '${tr('下载失败')}：$e');
    } finally {
      if (mounted) setState(() => _busyIds.remove(file.id));
    }
  }

  Future<DownloadTask> _enqueue(QuizRemoteFile file) async {
    await DownloadManager.instance.ensureLoaded();
    return DownloadManager.instance.enqueue(
      url: file.downloadUrl(_service.baseUrl),
      name: file.file,
      platform: '在线题库',
      size: file.size,
    );
  }

  Future<void> _editBaseUrl() async {
    final controller = TextEditingController(
      text: SettingsController.instance.quizResourceBaseUrl.isEmpty
          ? QuizIndexService.kDefaultQuizResourceBaseUrl
          : SettingsController.instance.quizResourceBaseUrl,
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('资源域名')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'https://...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('保存')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (saved != true) return;
    final value = controller.text.trim();
    final effective =
        value == QuizIndexService.kDefaultQuizResourceBaseUrl ? '' : value;
    await SettingsController.instance.setQuizResourceBaseUrl(effective);
    if (!mounted) return;
    setState(() {
      _service = QuizIndexService(
          baseUrl: value.isEmpty
              ? QuizIndexService.kDefaultQuizResourceBaseUrl
              : value);
    });
    _load(useCacheFirst: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('在线题库')),
        actions: [
          IconButton(
            key: const ValueKey('quiz-remote-edit-url'),
            icon: const Icon(Icons.link_outlined),
            tooltip: tr('资源域名'),
            onPressed: _editBaseUrl,
          ),
          IconButton(
            key: const ValueKey('quiz-remote-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: tr('刷新'),
            onPressed: () => _load(useCacheFirst: false),
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading && _files.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_files.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 48, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text(_error ?? tr('暂无在线题库'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.outline)),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _load(useCacheFirst: false),
                child: Text(tr('重试')),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(useCacheFirst: false),
      child: ListView.separated(
        key: const ValueKey('quiz-remote-list'),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: _files.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final file = _files[index];
          final busy = _busyIds.contains(file.id);
          return Card(
            child: ListTile(
              key: ValueKey('quiz-remote-${file.id}'),
              leading: const Icon(Icons.description_outlined),
              title: Text(file.title),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 2),
                  Text(file.file,
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.outline)),
                  if (file.metaLabel.isNotEmpty)
                    Text(file.metaLabel, style: const TextStyle(fontSize: 12)),
                  if (file.sizeLabel.isNotEmpty)
                    Text(file.sizeLabel, style: const TextStyle(fontSize: 12)),
                ],
              ),
              trailing: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : FilledButton.tonal(
                      onPressed: () => _downloadAndImport(file),
                      child: Text(tr('下载')),
                    ),
              isThreeLine: true,
            ),
          );
        },
      ),
    );
  }
}
