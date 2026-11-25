import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../core/platform/file_import_bridge.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/storage/app_files.dart';
import '../../../core/widgets/app_widgets.dart';
import 'reader_view_page.dart';

/// 一次手动导入项：路径、展示名、是否为可删除的临时副本。
typedef ReaderImportItem = ({String path, String name, bool temporary});

/// 文字阅读器：直接列出应用存储空间里可阅读的 txt / json / md 文档。
///
/// 数据源是整个存储空间（不含个人信息分类），因此工具导出的题库 JSON、
/// 技能 Markdown 也能在这里打开；外部文件由 [FileImportBridge] 从第三方
/// App 接收并归档，「从手机选择文件」只是兜底入口。
class TextReaderPage extends StatefulWidget {
  const TextReaderPage({
    super.key,
    this.loader,
    this.importer,
    this.contentLoader,
  });

  /// 测试注入：替换文件列表来源，避免依赖真实文件系统。
  final Future<List<StoredFile>> Function()? loader;

  /// 测试注入：替换文件选择器。
  final Future<List<ReaderImportItem>> Function()? importer;

  /// 测试注入：打开文件时替换内容读取，避免 widget 测试里跑真实 I/O。
  final Future<String> Function(StoredFile file)? contentLoader;

  @override
  State<TextReaderPage> createState() => _TextReaderPageState();
}

class _TextReaderPageState extends State<TextReaderPage> {
  List<StoredFile>? _files;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    FileImportBridge.instance.addListener(_onImports);
    _load();
  }

  @override
  void dispose() {
    FileImportBridge.instance.removeListener(_onImports);
    super.dispose();
  }

  void _onImports() => _load();

  Future<void> _load() async {
    try {
      // 读取整个存储空间：题库 JSON、助手 Markdown 也可直接阅读。
      // 个人信息档案不让在阅读器里改，避免误编辑导致资料丢失。
      final files = widget.loader != null
          ? await widget.loader!()
          : await AppStore.list();
      final filtered = files
          .where((f) => f.category != AppStoreCategory.profile)
          .where((f) => FileImportBridge.isSupported(f.name))
          .toList()
        ..sort((a, b) => b.modified.compareTo(a.modified));
      if (!mounted) return;
      setState(() {
        _files = filtered;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<List<ReaderImportItem>> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: FileImportBridge.supportedExtensions.toList(),
      withData: true,
    );
    final out = <ReaderImportItem>[];
    for (final picked in result?.files ?? const <PlatformFile>[]) {
      if (picked.path != null) {
        out.add((path: picked.path!, name: picked.name, temporary: false));
      } else if (picked.bytes != null) {
        final tmp = File(
          '${Directory.systemTemp.path}/xmt_'
          '${DateTime.now().microsecondsSinceEpoch}_${picked.name}',
        );
        await tmp.writeAsBytes(picked.bytes!, flush: true);
        out.add((path: tmp.path, name: picked.name, temporary: true));
      }
    }
    return out;
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final items = widget.importer != null
          ? await widget.importer!()
          : await _pickFiles();
      var count = 0;
      for (final item in items) {
        final stored = await FileImportBridge.instance.adoptPath(
          item.path,
          name: item.name,
          deleteSource: item.temporary,
          requestOpen: false,
        );
        if (stored != null) count++;
      }
      await _load();
      if (!mounted) return;
      showToast(
        context,
        count > 0 ? trf('已导入 {n} 个文件', {'n': count}) : tr('暂不支持该文件类型'),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(StoredFile file) async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => ReaderViewPage(
        file: file,
        contentLoader: widget.contentLoader,
      ),
    ));
    await _load();
  }

  Future<void> _confirmDelete(StoredFile file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除文件')),
        content: Text(trf('确定删除「{n}」？', {'n': file.name})),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppStore.delete(file);
    await _load();
    if (mounted) showToast(context, tr('已删除'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('文字阅读器')),
        actions: <Widget>[
          IconButton(
            key: const ValueKey('reader-import'),
            tooltip: tr('导入文件'),
            icon: const Icon(Icons.add),
            onPressed: _busy ? null : _import,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(child: _body()),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
            child: SmallHint(text: tr('长按文件可删除')),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final error = _error;
    if (error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        text: trf('读取失败：{e}', {'e': error}),
      );
    }
    final files = _files;
    if (files == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (files.isEmpty) {
      return EmptyState(
        icon: Icons.article_outlined,
        title: tr('还没有文档'),
        text:
            tr('在微信、QQ 中打开 txt / json / md 文件时选择「用其他应用打开」→ XMtools，文件会自动保存到这里'),
        action: FilledButton.tonalIcon(
          key: const ValueKey('reader-empty-import'),
          onPressed: _import,
          icon: const Icon(Icons.file_open_outlined, size: 18),
          label: Text(tr('从手机选择文件')),
        ),
      );
    }
    final theme = Theme.of(context);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: files.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, index) {
        final file = files[index];
        final ext = file.extension;
        return ListTile(
          key: ValueKey('reader-file-${file.name}'),
          leading: Icon(_iconOf(ext), color: _colorOf(ext, theme.colorScheme)),
          title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${tr(file.category.label)} · ${ext.toUpperCase()} · '
            '${formatFileSize(file.size)} · ${_dateOf(file.modified)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _open(file),
          onLongPress: () => _confirmDelete(file),
        );
      },
    );
  }

  IconData _iconOf(String ext) => switch (ext) {
        'json' => Icons.data_object,
        'md' || 'markdown' => Icons.article_outlined,
        'html' || 'htm' => Icons.html,
        _ => Icons.description_outlined,
      };

  Color _colorOf(String ext, ColorScheme scheme) => switch (ext) {
        'json' => scheme.tertiary,
        'md' || 'markdown' => scheme.primary,
        'html' || 'htm' => scheme.error,
        _ => scheme.secondary,
      };

  String _dateOf(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.month}/${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}
