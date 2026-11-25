import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/storage/cache_inventory.dart';
import '../../core/widgets/app_widgets.dart';

/// 缓存明细列表的注入点（测试里避免跑真实文件 I/O）。
typedef CacheListLoader = Future<List<CacheEntry>> Function();

/// 单项清理的注入点。
typedef CacheItemCleaner = Future<int> Function(CacheEntry entry);

/// 点击存储空间「缓存」卡片弹出：按占用从大到小列出各项缓存，逐项清理。
Future<void> showCacheDetailSheet(
  BuildContext context, {
  CacheListLoader? loader,
  CacheItemCleaner? cleaner,
  Future<void> Function()? onChanged,
}) async {
  final entries = await (loader ?? CacheInventory.load)();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => _CacheDetailSheet(
      entries: entries,
      cleaner: cleaner ?? CacheInventory.clean,
      onChanged: onChanged,
    ),
  );
}

class _CacheDetailSheet extends StatefulWidget {
  const _CacheDetailSheet({
    required this.entries,
    required this.cleaner,
    this.onChanged,
  });

  final List<CacheEntry> entries;
  final CacheItemCleaner cleaner;
  final Future<void> Function()? onChanged;

  @override
  State<_CacheDetailSheet> createState() => _CacheDetailSheetState();
}

class _CacheDetailSheetState extends State<_CacheDetailSheet> {
  late List<CacheEntry> _entries = <CacheEntry>[
    ...widget.entries,
  ]..sort((a, b) => b.bytes.compareTo(a.bytes));
  String? _busyId;
  bool _cleaningAll = false;

  int get _total => _entries.fold<int>(0, (sum, e) => sum + e.bytes);

  Future<void> _cleanOne(CacheEntry entry) async {
    setState(() => _busyId = entry.id);
    int freed;
    try {
      freed = await widget.cleaner(entry);
    } catch (e) {
      freed = 0;
      if (mounted) showToast(context, trf('清理失败：{e}', {'e': '$e'}));
    }
    if (!mounted) return;
    setState(() {
      _entries = _entries.where((e) => e.id != entry.id).toList();
      _busyId = null;
    });
    showToast(context, trf('已清理 {v}', {'v': formatBytes(freed)}));
    await widget.onChanged?.call();
  }

  Future<void> _cleanAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('清理缓存')),
        content: Text(tr('将清除全部缓存项，存储空间里的文件不受影响。')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('清理')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _cleaningAll = true);
    var freed = 0;
    for (final entry in _entries.toList(growable: false)) {
      try {
        freed += await widget.cleaner(entry);
      } catch (_) {
        // 单项失败不影响其余项。
      }
    }
    if (!mounted) return;
    setState(() {
      _entries = const <CacheEntry>[];
      _cleaningAll = false;
    });
    showToast(context, trf('已清理缓存 {s}', {'s': formatBytes(freed)}));
    await widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.78,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.cached_outlined, size: 22, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tr('缓存明细'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    formatBytes(_total),
                    key: const ValueKey('cache-detail-total'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                tr('按占用从大到小排列，可单独清理；存储空间里的文件不受影响。'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                tr('题库、错题、收藏与笔记保存在应用数据库中，不属于缓存，不会被清理。'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: _entries.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 28),
                        child: Center(
                          child: Text(
                            tr('暂无可清理缓存'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          thickness: 1,
                          indent: 44,
                          color: scheme.outlineVariant.withOpacity(0.35),
                        ),
                        itemBuilder: (context, index) =>
                            _entryRow(theme, _entries[index]),
                      ),
              ),
              if (_entries.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  key: const ValueKey('cache-clean-all'),
                  onPressed: _cleaningAll || _busyId != null ? null : _cleanAll,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: Text(trf('清理全部（{n} 项）', {'n': '${_entries.length}'})),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _entryRow(ThemeData theme, CacheEntry entry) {
    final scheme = theme.colorScheme;
    final busy = _busyId == entry.id || _cleaningAll;
    final icon = switch (entry.kind) {
      CacheKind.runtime => Icons.layers_outlined,
      CacheKind.imports || CacheKind.temp => Icons.folder_open_outlined,
      CacheKind.quizRecords => Icons.history_toggle_off_outlined,
      CacheKind.quizAi => Icons.smart_toy_outlined,
    };
    return ListTile(
      key: ValueKey<String>('cache-entry-${entry.id}'),
      dense: true,
      leading: Icon(icon, size: 20, color: scheme.primary),
      title: Text(
        '${tr(entry.tool)} · ${tr(entry.name)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${entry.detail} · ${formatBytes(entry.bytes)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              key: ValueKey<String>('cache-clean-${entry.id}'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () => _cleanOne(entry),
              child: Text(tr('清理')),
            ),
    );
  }
}
