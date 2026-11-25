import 'package:flutter/material.dart';

import '../../core/settings/tool_texts.dart';
import '../../core/tool_registry.dart';
import '../../core/widgets/app_widgets.dart';

/// 调整工具顺序：拖动右侧把手即可，改动立即保存；右上角可恢复默认顺序。
///
/// 列表下方是「折叠工具栏」的投放区：把工具拖过分隔线就收进折叠栏，
/// 再从折叠栏拖回上方即恢复平铺。两段共用同一个可排序列表，这样跨区拖拽
/// 不用自己实现拖放命中。
class ToolOrderPage extends StatefulWidget {
  const ToolOrderPage({super.key});

  @override
  State<ToolOrderPage> createState() => _ToolOrderPageState();
}

class _ToolOrderPageState extends State<ToolOrderPage> {
  /// 平铺区与折叠区的分界标记，只在本页做列表切分用。
  final Object _divider = Object();

  late List<ToolDefinition> _pinned =
      List<ToolDefinition>.of(ToolRegistry.pinnedTools);
  late List<ToolDefinition> _folded =
      List<ToolDefinition>.of(ToolRegistry.foldedTools);

  int get _headerIndex => _pinned.length;
  int get _itemCount => _pinned.length + 1 + _folded.length;

  /// 拖动结果写回注册表：顺序存整条列表，折叠集合单独存。
  void _persist() {
    ToolRegistry.saveFolded(_folded.map((tool) => tool.id));
    ToolRegistry.saveOrder(
      <ToolDefinition>[..._pinned, ..._folded]
          .map((tool) => tool.id)
          .toList(growable: false),
    );
  }

  void _reorder(int oldIndex, int newIndex) {
    // 分隔条本身不可拖动，真被拖到时忽略。
    if (oldIndex == _headerIndex) return;
    if (newIndex > oldIndex) newIndex -= 1;

    final flat = <Object>[..._pinned, _divider, ..._folded];
    final moved = flat.removeAt(oldIndex);
    flat.insert(newIndex.clamp(0, flat.length), moved);

    final split = flat.indexOf(_divider);
    setState(() {
      _pinned = flat.sublist(0, split).cast<ToolDefinition>();
      _folded = flat.sublist(split + 1).cast<ToolDefinition>();
    });
    _persist();
  }

  void _setFolded(ToolDefinition tool, bool folded) {
    setState(() {
      if (folded) {
        _pinned.remove(tool);
        _folded.add(tool);
      } else {
        _folded.remove(tool);
        _pinned.add(tool);
      }
    });
    _persist();
  }

  Future<void> _reset() async {
    await ToolRegistry.resetOrder();
    if (!mounted) return;
    setState(() {
      _pinned = List<ToolDefinition>.of(ToolRegistry.tools);
      _folded = <ToolDefinition>[];
    });
    showToast(context, tr('已恢复默认顺序'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('工具顺序')),
        actions: [
          InfoHint(text: tr('按住右侧把手拖动排序；拖到下方折叠栏即收进去')),
          TextButton(
            key: const ValueKey('tool-order-reset'),
            onPressed: _reset,
            child: Text(tr('重置顺序')),
          ),
        ],
      ),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        buildDefaultDragHandles: false,
        itemCount: _itemCount,
        onReorder: _reorder,
        itemBuilder: (context, index) {
          if (index == _headerIndex) return _foldedHeader(context);
          final folded = index > _headerIndex;
          final tool =
              folded ? _folded[index - _headerIndex - 1] : _pinned[index];
          return _row(context, tool, folded: folded, index: index);
        },
      ),
    );
  }

  /// 分隔条：虚线感觉的风险太大，用一条描边卡做投放区，空的时候给一句提示。
  Widget _foldedHeader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      key: const ValueKey('tool-order-folded-header'),
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      color: scheme.surfaceContainerHighest.withOpacity(0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, _folded.isEmpty ? 10 : 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.move_to_inbox_outlined,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  tr('折叠工具栏'),
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${_folded.length}',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            if (_folded.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  tr('把工具拖到这里，就收进折叠工具栏'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    ToolDefinition tool, {
    required bool folded,
    required int index,
  }) {
    final theme = Theme.of(context);
    final accent = tool.accent ?? theme.colorScheme.primary;
    return Card(
      key: ValueKey<String>('tool-order-${tool.id}'),
      margin: const EdgeInsets.symmetric(vertical: 3),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        dense: true,
        minLeadingWidth: 24,
        visualDensity: VisualDensity.compact,
        leading: Icon(tool.icon, color: accent, size: 22),
        title: Text(tr(tool.name)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: ValueKey<String>('tool-order-fold-${tool.id}'),
              tooltip: folded ? tr('移出折叠工具栏') : tr('收进折叠工具栏'),
              icon: Icon(
                folded
                    ? Icons.unarchive_outlined
                    : Icons.move_to_inbox_outlined,
                size: 19,
              ),
              visualDensity: VisualDensity.compact,
              onPressed: () => _setFolded(tool, !folded),
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.drag_handle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
