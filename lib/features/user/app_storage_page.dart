import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/formatters.dart';
import '../../core/platform/file_share.dart';
import '../../core/settings/app_l10n.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/storage/app_files.dart';
import '../../core/widgets/app_widgets.dart';
import '../profile/profile_repository.dart';
import 'cache_detail_sheet.dart';

/// 测试注入：分享文件（默认走原生系统分享面板）。
typedef FileSharer = Future<bool> Function(List<File> files);

/// 测试注入：导出到手机（默认写系统「下载/XMtools」）。
typedef FileExporter = Future<FileExportResult?> Function(List<File> files);

/// 测试注入：删除单个文件（默认走 [AppStore.delete] 的真实文件 I/O）。
typedef FileDeleter = Future<void> Function(StoredFile file);

/// 存储空间：按「个人信息 / 存储文件」分类统一管理应用内文件。
///
/// 工具产生的文件（题库 JSON、刷题备份、AI 生成内容）会自动落到对应目录，
/// 这里可以预览、分享到微信 / QQ、导出到手机、重命名、删除，也可以手动添加文件。
/// 长按任意文件进入多选，可一次分享、导出或删除。
class AppStoragePage extends StatefulWidget {
  const AppStoragePage({
    super.key,
    this.loader,
    this.sharer,
    this.exporter,
    this.deleter,
    this.cacheLoader,
    this.cacheItemCleaner,
  });

  /// 测试注入：替换文件列表来源，避免依赖真实文件系统。
  final Future<List<StoredFile>> Function()? loader;

  /// 测试注入：分享。
  final FileSharer? sharer;

  /// 测试注入：导出到手机。
  final FileExporter? exporter;

  /// 测试注入：删除。
  final FileDeleter? deleter;

  /// 测试注入：缓存明细列表（默认枚举原生缓存与 Dart 侧缓存）。
  final CacheListLoader? cacheLoader;

  /// 测试注入：清理单条缓存。
  final CacheItemCleaner? cacheItemCleaner;

  @override
  State<AppStoragePage> createState() => _AppStoragePageState();
}

class _AppStoragePageState extends State<AppStoragePage> {
  static const MethodChannel _channel = MethodChannel('toolbox/device_status');

  Map<dynamic, dynamic>? _info;
  List<StoredFile>? _files;
  String? _error;

  /// 多选模式下已选文件的路径集合。
  final Set<String> _selected = <String>{};
  bool _busy = false;

  bool get _selecting => _selected.isNotEmpty;

  List<StoredFile> get _selectedFiles => (_files ?? const <StoredFile>[])
      .where((f) => _selected.contains(f.path))
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<StoredFile>? files;
    String? error;
    try {
      final loader = widget.loader;
      files = loader == null ? await AppStore.list() : await loader();
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    // 先把文件列出来：原生统计失败也不影响文件管理。
    setState(() {
      _files = files;
      _error = error;
      if (files != null) {
        // 文件被删除或改名后，选择集合里不能残留失效路径。
        final alive = files.map((f) => f.path).toSet();
        _selected.retainWhere(alive.contains);
      }
    });

    if (widget.loader != null) return;
    Map<dynamic, dynamic>? info;
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('appStorage')
          .timeout(const Duration(seconds: 3));
      if (raw is Map) info = raw;
    } catch (_) {
      info = null;
    }
    if (!mounted) return;
    setState(() => _info = info);
  }

  // —— 操作 ——

  /// 缓存不再一键清：点卡片先看明细，按占用从大到小逐项决定清哪些。
  Future<void> _openCacheDetail() async {
    await showCacheDetailSheet(
      context,
      loader: widget.cacheLoader,
      cleaner: widget.cacheItemCleaner,
      onChanged: _load,
    );
  }

  Future<void> _importFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final picked = result?.files.single;
    if (picked == null) return;
    final category = await _chooseCategory();
    if (category == null || !mounted) return;
    try {
      final bytes = picked.bytes ??
          await File.fromUri(Uri.file(picked.path!)).readAsBytes();
      final stored = await AppStore.saveBytes(
        category: category,
        name: picked.name,
        bytes: bytes,
      );
      if (!mounted) return;
      showToast(context, trf('已添加到存储空间：{n}', {'n': stored.name}));
      await _load();
    } catch (e) {
      if (mounted) showToast(context, trf('添加失败：{e}', {'e': '$e'}));
    }
  }

  Future<AppStoreCategory?> _chooseCategory() {
    return showModalBottomSheet<AppStoreCategory>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(tr('存放到哪个分类'),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final category in AppStoreCategory.values)
              ListTile(
                leading: Icon(category.icon),
                title: Text(tr(category.label)),
                onTap: () => Navigator.of(context).pop(category),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _preview(StoredFile file) async {
    final theme = Theme.of(context);
    if (file.isImage) {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: InteractiveViewer(
            child: Image.file(file.file, fit: BoxFit.contain),
          ),
        ),
      );
      return;
    }
    if (!file.isText) {
      showToast(context, tr('该格式暂不支持预览，可导出后在手机上打开'));
      return;
    }
    String content;
    try {
      content = await AppStore.readText(file);
    } catch (e) {
      if (mounted) showToast(context, trf('读取失败：{e}', {'e': '$e'}));
      return;
    }
    if (!mounted) return;
    final truncated = content.length > 20000;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(file.name, style: theme.textTheme.titleSmall),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              truncated ? '${content.substring(0, 20000)}\n…' : content,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace', height: 1.35),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              copyWithToast(this.context, content);
            },
            child: Text(tr('复制')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('关闭')),
          ),
        ],
      ),
    );
  }

  Future<void> _export(StoredFile file) async {
    try {
      final bytes = await file.file.readAsBytes();
      final target =
          await FilePicker.platform.saveFile(fileName: file.name, bytes: bytes);
      if (target == null || !mounted) return;
      showToast(context, tr('已导出到手机'));
    } catch (e) {
      if (mounted) showToast(context, trf('导出失败：{e}', {'e': '$e'}));
    }
  }

  Future<void> _rename(StoredFile file) async {
    final input = TextEditingController(text: file.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('重命名')),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('文件名'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(input.text),
            child: Text(tr('保存')),
          ),
        ],
      ),
    );
    input.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      await AppStore.rename(file, name);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, trf('重命名失败：{e}', {'e': '$e'}));
    }
  }

  Future<void> _delete(StoredFile file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除文件')),
        content: Text(trf('确认删除「{n}」？删除后不可恢复。', {'n': file.name})),
        actions: [
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
    await _deleteOne(file);
    if (mounted) showToast(context, tr('已删除'));
    await _load();
  }

  Future<void> _deleteOne(StoredFile file) async {
    final deleter = widget.deleter ?? AppStore.delete;
    await deleter(file);
    // 个人信息档案就是这个文件：删掉它等于清空个人信息。
    if (file.category == AppStoreCategory.profile &&
        file.name == ProfileRepository.fileName) {
      await ProfileRepository.clear();
    }
  }

  // —— 多选 ——

  void _toggleSelect(StoredFile file) {
    setState(() {
      if (!_selected.remove(file.path)) _selected.add(file.path);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  void _toggleSelectAll() {
    final files = _files ?? const <StoredFile>[];
    setState(() {
      if (_selected.length == files.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(files.map((f) => f.path));
      }
    });
  }

  Future<void> _shareSelected() async {
    final files = _selectedFiles;
    if (files.isEmpty) return;
    await _shareFiles(files.map((f) => f.file).toList(growable: false));
  }

  Future<void> _shareFiles(List<File> files) async {
    final sharer = widget.sharer ?? (f) => FileShare.share(f);
    final ok = await sharer(files);
    if (!mounted) return;
    if (!ok) showToast(context, tr('未能唤起分享，请确认系统有可用的接收应用'));
  }

  Future<void> _exportSelected() async {
    final files = _selectedFiles;
    if (files.isEmpty || _busy) return;
    setState(() => _busy = true);
    FileExportResult? result;
    try {
      final exporter = widget.exporter ?? (f) => FileShare.export(f);
      result = await exporter(files.map((f) => f.file).toList(growable: false));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (result == null || result.count == 0) {
      showToast(context, tr('导出失败：无法写入下载目录'));
      return;
    }
    showToast(
      context,
      trf('已导出 {n} 个文件到 {d}', {
        'n': '${result.count}',
        'd': result.dir,
      }),
    );
    if (result.failed == 0) _clearSelection();
  }

  Future<void> _deleteSelected() async {
    final files = _selectedFiles;
    if (files.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除文件')),
        content:
            Text(trf('确认删除选中的 {n} 个文件？删除后不可恢复。', {'n': '${files.length}'})),
        actions: [
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
    var done = 0;
    for (final file in files) {
      try {
        await _deleteOne(file);
        done++;
      } catch (_) {
        // 单个文件删不掉不影响其余文件。
      }
    }
    if (!mounted) return;
    _clearSelection();
    showToast(context, trf('已删除 {n} 个文件', {'n': '$done'}));
    await _load();
  }

  // —— 界面 ——

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppL10n.of();
    return Scaffold(
      appBar: _selecting ? _selectionAppBar() : _normalAppBar(l10n),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            _usageCard(theme),
            const SizedBox(height: 4),
            ..._categorySections(theme),
          ],
        ),
      ),
      bottomNavigationBar: _selecting ? _selectionActions(theme) : null,
    );
  }

  AppBar _normalAppBar(AppL10n l10n) {
    return AppBar(
      title: Text(l10n.storage),
      actions: [
        IconButton(
          tooltip: tr('添加文件'),
          icon: const Icon(Icons.add),
          onPressed: _importFile,
        ),
      ],
    );
  }

  AppBar _selectionAppBar() {
    final files = _files ?? const <StoredFile>[];
    final allSelected = files.isNotEmpty && _selected.length == files.length;
    return AppBar(
      leading: IconButton(
        tooltip: tr('退出多选'),
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text(trf('已选 {n} 项', {'n': '${_selected.length}'})),
      actions: [
        TextButton(
          onPressed: files.isEmpty ? null : _toggleSelectAll,
          child: Text(tr(allSelected ? '取消全选' : '全选')),
        ),
      ],
    );
  }

  Widget _selectionActions(ThemeData theme) {
    final danger = theme.colorScheme.error;
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant.withOpacity(0.4),
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Row(
          children: [
            _selectionAction(
              icon: Icons.share_outlined,
              label: tr('分享'),
              onTap: _shareSelected,
            ),
            _selectionAction(
              icon: Icons.download_outlined,
              label: tr('导出到手机'),
              onTap: _busy ? null : _exportSelected,
            ),
            _selectionAction(
              icon: Icons.delete_outline,
              label: tr('删除'),
              color: danger,
              onTap: _deleteSelected,
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectionAction({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    Color? color,
  }) {
    final theme = Theme.of(context);
    final tint = onTap == null
        ? theme.colorScheme.onSurface.withOpacity(0.38)
        : (color ?? theme.colorScheme.onSurfaceVariant);
    return Expanded(
      child: InkWell(
        key: ValueKey<String>('storage-action-$label'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: tint),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: tint),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _usageCard(ThemeData theme) {
    final l10n = AppL10n.of();
    final scheme = theme.colorScheme;
    final files = _files ?? const <StoredFile>[];
    final managed = files.fold<int>(0, (sum, f) => sum + f.size);
    final dataSize = (_info?['dataSize'] as num?)?.toInt() ?? 0;
    final cacheSize = (_info?['cacheSize'] as num?)?.toInt() ?? 0;

    // 四列统计保持一行，列间用发丝线分组；缓存格加主题色底，
    // 让「这是可以点进去的」在视觉上直接看得出来。
    final tiles = <Widget>[
      MetricTile(
        compact: true,
        label: tr('管理文件'),
        value: '${files.length}',
      ),
      MetricTile(
        compact: true,
        label: tr('文件占用'),
        value: formatFileSize(managed),
      ),
      MetricTile(
        compact: true,
        label: l10n.storageData,
        value: formatBytes(dataSize == 0 ? managed : dataSize),
      ),
      Material(
        color: scheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: const ValueKey('storage-cache-tile'),
          onTap: _openCacheDetail,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: MetricTile(
              compact: true,
              label: l10n.storageCache,
              value: formatBytes(cacheSize),
              valueColor: scheme.primary,
            ),
          ),
        ),
      ),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                for (var i = 0; i < tiles.length; i++) ...<Widget>[
                  if (i > 0)
                    Container(
                      width: 1,
                      height: 28,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      color: scheme.outlineVariant.withOpacity(0.45),
                    ),
                  Expanded(child: tiles[i]),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _categorySections(ThemeData theme) {
    if (_error != null) {
      return <Widget>[
        const SizedBox(height: 12),
        HintBanner(
          icon: Icons.error_outline,
          text: trf('存储空间暂不可用：{e}', {'e': _error}),
        ),
      ];
    }
    final files = _files;
    if (files == null) {
      return const <Widget>[
        SizedBox(height: 48),
        Center(child: CircularProgressIndicator()),
      ];
    }
    // 每个分类都必须出现在某个分组里，漏掉会让文件只计数不显示。
    final groups = <String, List<AppStoreCategory>>{
      '个人信息': <AppStoreCategory>[AppStoreCategory.profile],
      '存储文件': <AppStoreCategory>[
        AppStoreCategory.quiz,
        AppStoreCategory.assistant,
        AppStoreCategory.reader,
        AppStoreCategory.other,
      ],
    };
    final widgets = <Widget>[];
    for (final entry in groups.entries) {
      final categories = entry.value;
      final groupFiles =
          files.where((f) => categories.contains(f.category)).toList();
      widgets
        ..add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 15,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Text(
                  tr(entry.key),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                formatFileSize(groupFiles.fold<int>(0, (s, f) => s + f.size)),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ))
        ..add(Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              if (groupFiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                  child: Row(
                    children: [
                      Icon(Icons.inbox_outlined,
                          size: 20, color: theme.colorScheme.outline),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          entry.key == '个人信息' ? tr('还没有个人资料文件') : tr('还没有存储文件'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                for (var i = 0; i < groupFiles.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 16,
                      color: theme.colorScheme.outlineVariant.withOpacity(0.35),
                    ),
                  _fileRow(theme, groupFiles[i]),
                ],
            ],
          ),
        ));
    }
    return widgets;
  }

  Widget _fileRow(ThemeData theme, StoredFile file) {
    final selected = _selected.contains(file.path);
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withOpacity(0.06),
      leading: _selecting
          ? Checkbox(
              value: selected,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (_) => _toggleSelect(file),
            )
          : _fileTypeIcon(theme, file),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${tr(file.category.label)} · ${formatFileSize(file.size)} · '
        '${_timeLabel(file.modified)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _selecting ? _toggleSelect(file) : _preview(file),
      onLongPress: () => _toggleSelect(file),
      trailing: _selecting
          ? null
          : PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 18),
              tooltip: tr('更多'),
              onSelected: (value) => switch (value) {
                'share' => _shareFiles(<File>[file.file]),
                'export' => _export(file),
                'rename' => _rename(file),
                'delete' => _delete(file),
                _ => null,
              },
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'share',
                  child: Text(tr('分享')),
                ),
                PopupMenuItem<String>(
                  value: 'export',
                  child: Text(tr('导出到手机')),
                ),
                PopupMenuItem<String>(
                  value: 'rename',
                  child: Text(tr('重命名')),
                ),
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Text(tr('删除')),
                ),
              ],
            ),
    );
  }

  /// 文件类型图标：图片 / 文本 / 其他各用一种语义色与浅色底衬，
  /// 让长列表里不同类型一眼可分；颜色取自主题，跟随明暗与换色。
  Widget _fileTypeIcon(ThemeData theme, StoredFile file) {
    final scheme = theme.colorScheme;
    final IconData icon;
    final Color tone;
    if (file.isImage) {
      icon = Icons.image_outlined;
      tone = Colors.teal;
    } else if (file.isText) {
      icon = Icons.description_outlined;
      tone = scheme.primary;
    } else {
      icon = Icons.insert_drive_file_outlined;
      tone = Colors.deepOrange;
    }
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: tone.withOpacity(0.12),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: 19, color: tone),
    );
  }

  static String _timeLabel(DateTime time) {
    final now = DateTime.now();
    final hm = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(time.year, time.month, time.day);
    if (day == today) return hm;
    return '${time.month}月${time.day}日';
  }
}
