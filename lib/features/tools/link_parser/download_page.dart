import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../core/platform/file_share.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import 'download_manager.dart';
import 'download_task.dart';

/// 下载管理：解析页里点「下载」的所有任务都在这里，进度、暂停、重试、
/// 已完成文件统一管理。
///
/// 之前每个任务只有页面里一行临时文字，退出页面就丢；现在任务落盘成记录，
/// 应用重启后还能看到下载过的内容和保存位置。
class DownloadPage extends StatefulWidget {
  const DownloadPage({
    super.key,
    this.manager,
    this.onOpenSettings,
  });

  /// 测试注入：不传则用全局单例。
  final DownloadManager? manager;

  /// 右上角设置入口；为空时不显示。
  final VoidCallback? onOpenSettings;

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  DownloadManager get _manager => widget.manager ?? DownloadManager.instance;

  @override
  void initState() {
    super.initState();
    _manager.ensureLoaded();
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('清除下载记录')),
        content: Text(tr('只清除记录和未完成的临时文件，已保存的成品文件不会被删除。')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('清除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _manager.clearAll();
    if (mounted) showToast(context, tr('已清除下载记录'));
  }

  Future<void> _open(DownloadTask task) async {
    final path = task.localPath.isNotEmpty ? task.localPath : task.savedPath;
    final file = File(path);
    if (path.isEmpty || !file.existsSync()) {
      // 公共下载目录里的文件受分区存储限制，应用可能按路径读不到——
      // 这时直接告诉用户去哪儿找，比报「文件不存在」有用。
      showToast(
        context,
        task.savedToPhone
            ? trf('已保存到 {p}，请在系统文件管理里打开', {'p': task.savedPath})
            : trf('文件不在这里了：{p}', {'p': task.savedPath}),
      );
      return;
    }
    final isImage = RegExp(r'\.(jpe?g|png|gif|webp|bmp)$', caseSensitive: false)
        .hasMatch(task.name);
    if (isImage) {
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          insetPadding: const EdgeInsets.all(12),
          child: InteractiveViewer(
            maxScale: 4,
            child: Image.file(file, fit: BoxFit.contain),
          ),
        ),
      );
      return;
    }
    final ok = await FileShare.share(<File>[file]);
    if (!ok && mounted) showToast(context, tr('没有可分享的应用'));
  }

  Future<void> _cancel(DownloadTask task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('取消下载')),
        content: Text(trf('{name} 已下载的部分会被删除。', {'name': task.name})),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('继续下载')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('取消下载')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _manager.cancel(task);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('下载管理')),
        actions: <Widget>[
          ListenableBuilder(
            listenable: _manager,
            builder: (context, _) => IconButton(
              tooltip: tr('清除已完成'),
              onPressed: _manager.tasks.any((task) => task.finished)
                  ? _confirmClear
                  : null,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
          ),
          if (widget.onOpenSettings != null)
            IconButton(
              key: const ValueKey('download-settings'),
              tooltip: tr('设置'),
              onPressed: widget.onOpenSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _manager,
        builder: (context, _) {
          final tasks = _manager.tasks;
          if (tasks.isEmpty) {
            return EmptyState(
              icon: Icons.download_outlined,
              title: tr('还没有下载任务'),
              text: tr('在链接解析里点「下载」，任务会出现在这里，可以暂停、重试或查看保存位置。'),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            itemCount: tasks.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return _summaryCard(theme, tasks);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _taskCard(theme, tasks[index - 1]),
              );
            },
          );
        },
      ),
    );
  }

  Widget _summaryCard(ThemeData theme, List<DownloadTask> tasks) {
    final scheme = theme.colorScheme;
    final running = tasks.where((t) => t.status == DownloadStatus.running);
    final speed = running.fold<int>(0, (sum, t) => sum + t.speed);
    final done = tasks.where((t) => t.status == DownloadStatus.done).length;
    final failed = tasks.where((t) => t.status == DownloadStatus.failed).length;
    final totalBytes = tasks
        .where((t) => t.status == DownloadStatus.done)
        .fold<int>(0, (sum, t) => sum + t.done);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    running.isEmpty
                        ? trf('已完成 {n} 个', {'n': done})
                        : trf('正在下载 {n} 个', {'n': running.length}),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    <String>[
                      if (speed > 0) '${formatBytes(speed)}/s',
                      trf('已保存 {v}', {'v': formatBytes(totalBytes)}),
                      if (failed > 0) trf('失败 {n}', {'n': failed}),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (running.isNotEmpty)
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  value: running.first.total > 0
                      ? running.first.progress
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _taskCard(ThemeData theme, DownloadTask task) {
    final scheme = theme.colorScheme;
    final running = task.status == DownloadStatus.running ||
        task.status == DownloadStatus.queued;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_iconOf(task), size: 19, color: scheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    task.name,
                    key: ValueKey<String>('download-name-${task.id}'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _statusLine(task),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (running && task.status == DownloadStatus.running) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: task.total > 0 ? task.progress : null,
                        minHeight: 4,
                      ),
                    ),
                  ],
                  if (task.status == DownloadStatus.failed &&
                      task.error.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      task.error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error),
                    ),
                  ],
                ],
              ),
            ),
            ..._actions(task),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(DownloadTask task) {
    Widget icon(IconData data, String tooltip, VoidCallback onTap, String key) {
      return IconButton(
        key: ValueKey<String>(key),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        padding: EdgeInsets.zero,
        icon: Icon(data, size: 19),
        onPressed: onTap,
      );
    }

    if (task.status == DownloadStatus.done) {
      return <Widget>[
        icon(Icons.open_in_new, tr('打开'), () => _open(task),
            'download-open-${task.id}'),
        icon(Icons.close, tr('删除记录'), () => _manager.remove(task),
            'download-remove-${task.id}'),
      ];
    }
    if (task.status.isActive) {
      return <Widget>[
        icon(Icons.pause_rounded, tr('暂停'), () => _manager.pause(task),
            'download-pause-${task.id}'),
        icon(Icons.close, tr('取消'), () => _cancel(task),
            'download-cancel-${task.id}'),
      ];
    }
    return <Widget>[
      icon(Icons.play_arrow_rounded, tr('继续'), () => _manager.resume(task),
          'download-resume-${task.id}'),
      icon(Icons.close, tr('删除记录'), () => _manager.remove(task),
          'download-remove-${task.id}'),
    ];
  }

  String _statusLine(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.queued:
        return task.total > 0
            ? trf('排队中 · {v}', {'v': formatBytes(task.total)})
            : tr('排队中');
      case DownloadStatus.running:
        final size = task.total > 0
            ? '${formatBytes(task.done)} / ${formatBytes(task.total)}'
            : formatBytes(task.done);
        final speed = task.speed > 0 ? ' · ${formatBytes(task.speed)}/s' : '';
        return '$size$speed';
      case DownloadStatus.paused:
        return task.total > 0
            ? trf('已暂停 · {a} / {b}', {
                'a': formatBytes(task.done),
                'b': formatBytes(task.total),
              })
            : tr('已暂停');
      case DownloadStatus.done:
        return trf('已保存到 {p}', {
          'p': task.savedPath.isEmpty ? tr('存储空间') : task.savedPath,
        });
      case DownloadStatus.failed:
        return tr('下载失败');
      case DownloadStatus.canceled:
        return tr('已取消');
    }
  }

  static IconData _iconOf(DownloadTask task) {
    final name = task.name.toLowerCase();
    if (RegExp(r'\.(jpe?g|png|gif|webp|bmp|heic)$').hasMatch(name)) {
      return Icons.image_outlined;
    }
    if (RegExp(r'\.(mp4|mov|m4v|mkv|webm|ts)$').hasMatch(name)) {
      return Icons.movie_outlined;
    }
    if (RegExp(r'\.(mp3|m4a|aac|wav|flac|ogg)$').hasMatch(name)) {
      return Icons.audiotrack_outlined;
    }
    if (RegExp(r'\.(apk)$').hasMatch(name)) return Icons.android_outlined;
    if (RegExp(r'\.(zip|rar|7z|tar|gz)$').hasMatch(name)) {
      return Icons.folder_zip_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}
