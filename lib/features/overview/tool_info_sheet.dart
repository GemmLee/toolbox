import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/storage/storage_maintenance.dart';
import '../../core/tool_registry.dart';
import '../../core/widgets/app_widgets.dart';

/// 长按工具卡弹出的属性窗：看这个工具占了多少用户数据，并就地清理。
///
/// 只列真实可清理的数据；工具本体随 APK 一起安装，拆不出单个体积，不列出。
Future<void> showToolInfoSheet(
  BuildContext context,
  ToolDefinition tool, {
  Future<ToolUsage> Function(ToolDefinition tool)? usageLoader,
  Future<int> Function(ToolDefinition tool)? cleaner,
  Future<int> Function(ToolDefinition tool)? temporaryCleaner,
}) async {
  final usage = await (usageLoader ?? ToolStorageService.usageOf)(tool);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => _ToolInfoSheet(
      tool: tool,
      usage: usage,
      cleaner: cleaner ?? ToolStorageService.clear,
      temporaryCleaner: temporaryCleaner ?? ToolStorageService.clearTemporary,
    ),
  );
}

class _ToolInfoSheet extends StatefulWidget {
  const _ToolInfoSheet({
    required this.tool,
    required this.usage,
    required this.cleaner,
    required this.temporaryCleaner,
  });

  final ToolDefinition tool;
  final ToolUsage usage;
  final Future<int> Function(ToolDefinition tool) cleaner;
  final Future<int> Function(ToolDefinition tool) temporaryCleaner;

  @override
  State<_ToolInfoSheet> createState() => _ToolInfoSheetState();
}

class _ToolInfoSheetState extends State<_ToolInfoSheet> {
  late ToolUsage _usage = widget.usage;
  bool _busy = false;

  Future<void> _clearTemporary() async {
    setState(() => _busy = true);
    final freed = await widget.temporaryCleaner(widget.tool);
    final next = await ToolStorageService.usageOf(widget.tool);
    if (!mounted) return;
    setState(() {
      _usage = next;
      _busy = false;
    });
    showToast(context, trf('已清理 {v}', {'v': formatStorageSize(freed)}));
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('清除该工具数据')),
        content: Text(
          '${trf('将删除「{name}」的全部用户数据，操作不可撤销。', {
                'name': tr(widget.tool.name),
              })}\n'
          '${tr('题库、工资记录等内容会一并删除，建议先在存储空间里备份。')}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('清除')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final freed = await widget.cleaner(widget.tool);
    final next = await ToolStorageService.usageOf(widget.tool);
    if (!mounted) return;
    setState(() {
      _usage = next;
      _busy = false;
    });
    showToast(context, trf('已释放 {v}', {'v': formatStorageSize(freed)}));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = widget.tool.accent ?? scheme.primary;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(widget.tool.icon, color: accent, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        tr(widget.tool.name),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        tr(widget.tool.category),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  formatStorageSize(_usage.totalBytes),
                  key: const ValueKey('tool-info-total'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.onSurface.withOpacity(0.05),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _row(tr('用户数据'), formatStorageSize(_usage.totalBytes)),
                  const SizedBox(height: 6),
                  _row(tr('存储文件'), formatStorageSize(_usage.fileBytes)),
                  const SizedBox(height: 6),
                  _row(tr('偏好与记录'), formatStorageSize(_usage.dataBytes)),
                ],
              ),
            ),
            if (_usage.details.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _usage.details.join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 14),
            if (_busy)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else ...<Widget>[
              if (widget.tool.id == 'quiz') ...<Widget>[
                OutlinedButton.icon(
                  key: const ValueKey('tool-info-clear-temp'),
                  onPressed: _clearTemporary,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: Text(tr('清理旧刷题记录（保留最近 30 条）')),
                ),
                const SizedBox(height: 8),
              ],
              FilledButton.tonalIcon(
                key: const ValueKey('tool-info-clear-all'),
                onPressed: _usage.hasData ? _clearAll : null,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(tr('清除该工具数据')),
                style: FilledButton.styleFrom(
                  foregroundColor: scheme.error,
                  backgroundColor: scheme.error.withOpacity(0.10),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
