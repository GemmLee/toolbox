import 'package:flutter/material.dart';

import '../formatters.dart';
import '../settings/tool_texts.dart';
import 'app_files.dart';

/// 从「存储空间」里挑一个文件（按扩展名过滤）。
///
/// 返回 null 表示用户取消。工具页的导入入口用它实现
/// 「直接导入存储空间内的文件」。
Future<StoredFile?> pickStoredFile(
  BuildContext context, {
  List<String>? extensions,
  String? title,
}) {
  return showModalBottomSheet<StoredFile>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _StoreFileSheet(extensions: extensions, title: title),
  );
}

class _StoreFileSheet extends StatefulWidget {
  const _StoreFileSheet({this.extensions, this.title});

  final List<String>? extensions;
  final String? title;

  @override
  State<_StoreFileSheet> createState() => _StoreFileSheetState();
}

class _StoreFileSheetState extends State<_StoreFileSheet> {
  late Future<List<StoredFile>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<StoredFile>> _load() async {
    final allowed = widget.extensions
        ?.map((e) => e.toLowerCase().replaceAll('.', ''))
        .toSet();
    final files = await AppStore.list();
    if (allowed == null || allowed.isEmpty) return files;
    return files.where((f) => allowed.contains(f.extension)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title ?? tr('从存储空间选择'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (widget.extensions != null)
                    Text(
                      widget.extensions!.map((e) => '.$e').join(' / '),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                ],
              ),
            ),
            Flexible(
              child: FutureBuilder<List<StoredFile>>(
                future: _future,
                builder: (context, snapshot) {
                  final files = snapshot.data;
                  if (files == null) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (files.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
                      child: Column(
                        children: [
                          Icon(Icons.folder_off_outlined,
                              size: 40, color: theme.colorScheme.outline),
                          const SizedBox(height: 8),
                          Text(
                            tr('存储空间里还没有可用的文件'),
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tr('可在「用户 → 存储空间」添加，或先用工具生成'),
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: files.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final file = files[index];
                      return ListTile(
                        leading: Icon(
                          file.isImage
                              ? Icons.image_outlined
                              : Icons.description_outlined,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(file.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${file.category.label} · ${formatFileSize(file.size)}',
                        ),
                        onTap: () => Navigator.of(context).pop(file),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
