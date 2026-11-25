import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/storage/local_store.dart';
import '../../core/tool_registry.dart';
import '../../core/widgets/app_backdrop.dart';
import '../../core/widgets/tool_open_route.dart';
import 'tool_info_sheet.dart';
import 'tool_order_page.dart';

/// 工具总览：按注册顺序平铺，每行三个，支持搜索。
///
/// 收进「折叠工具栏」的工具默认不占网格，点标题栏展开才出现；
/// 收录 / 移出在工具顺序页里拖拽完成。
class ToolsOverviewPage extends StatefulWidget {
  const ToolsOverviewPage({super.key});

  @override
  State<ToolsOverviewPage> createState() => _ToolsOverviewPageState();
}

class _ToolsOverviewPageState extends State<ToolsOverviewPage> {
  static const String _openKey = 'tool_folded_open';

  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _foldedOpen = false;

  @override
  void initState() {
    super.initState();
    _restoreFoldedOpen();
  }

  /// 折叠栏是否展开属于显示偏好，跟着存储走，重启后保持上次状态。
  Future<void> _restoreFoldedOpen() async {
    final json = await LocalStore.readMap(_openKey);
    final open = json?['open'];
    if (!mounted || open is! bool || open == _foldedOpen) return;
    setState(() => _foldedOpen = open);
  }

  void _toggleFolded() {
    setState(() => _foldedOpen = !_foldedOpen);
    LocalStore.writeMap(_openKey, <String, dynamic>{'open': _foldedOpen});
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openOrder() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ToolOrderPage()),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final matched = ToolRegistry.search(_query);
    final searching = _query.trim().isNotEmpty;
    // 搜索时不再区分折叠与否：要搜就得能搜到全部工具。
    final folded =
        searching ? const <ToolDefinition>[] : ToolRegistry.foldedTools;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: tr('搜索'),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 排序入口只在搜索框右侧给一个图标，不占额外一行。
            IconButton.filledTonal(
              key: const ValueKey('tool-order-entry'),
              tooltip: tr('调整顺序'),
              icon: const Icon(Icons.swap_vert, size: 20),
              onPressed: _openOrder,
            ),
          ],
        ),
        if (folded.isNotEmpty) ...[
          const SizedBox(height: 12),
          _foldedSection(folded),
          const SizedBox(height: 12),
        ] else
          const SizedBox(height: 18),
        if (matched.isEmpty)
          _emptyState()
        else
          _grid(searching ? matched : ToolRegistry.pinnedTools),
      ],
    );
  }

  /// 三列网格：卡片边长 = 列宽，任何屏宽下都是正方形。
  Widget _grid(List<ToolDefinition> tools) {
    if (tools.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 10.0;
        final cardWidth = (constraints.maxWidth - gap * 2) / 3;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final tool in tools) _ToolCard(tool: tool, width: cardWidth),
          ],
        );
      },
    );
  }

  /// 折叠工具栏：一行标题（带数量与展开箭头），展开后照同样的三列网格铺开。
  Widget _foldedSection(List<ToolDefinition> tools) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('overview-folded-toggle'),
            onTap: _toggleFolded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
              child: Row(
                children: [
                  Icon(Icons.unfold_more_outlined,
                      size: 19, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    tr('折叠工具栏'),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${tools.length}',
                    key: const ValueKey('overview-folded-count'),
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const Spacer(),
                  Icon(
                    _foldedOpen ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_foldedOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _grid(tools),
            ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    final theme = Theme.of(context);
    final muted = BackdropStyle.foregroundOf(
      context,
      theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 56),
      child: Column(
        children: [
          Icon(
            Icons.search_off,
            size: 44,
            color: muted,
          ),
          const SizedBox(height: 12),
          Text(
            tr('没有匹配的工具'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.tool, required this.width});

  final ToolDefinition tool;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = tool.accent ?? scheme.primary;
    return SizedBox(
      width: width,
      // 边长跟随三列网格宽度，任何屏宽下都是圆角正方形；
      // 下方描述允许两行，正好补齐上一轮压缩掉的高度。
      height: width,
      child: Material(
        color: theme.cardTheme.color,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          side: BorderSide(color: scheme.outlineVariant.withOpacity(0.9)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            Navigator.of(context).push(
              // 工具页统一用短进场动效：320ms 的淡入 + 轻微放大，
              // 让「点的卡片」和「打开的页面」在视觉上接得上。
              ToolOpenRoute<void>(
                builder: tool.builder,
                settings: RouteSettings(name: '/tool/${tool.id}'),
              ),
            );
          },
          // 长按看占用：工具卡本身就是入口，属性窗挂在同一块区域上。
          onLongPress: () => showToolInfoSheet(context, tool),
          child: Stack(
            children: [
              // 左上角一层极淡的主题色光，卡片不再是一块死白
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.topLeft,
                        radius: 1.15,
                        colors: <Color>[
                          accent.withOpacity(0.10),
                          accent.withOpacity(0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(11, 12, 11, 11),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(tool.icon, color: accent, size: 26),
                    const Spacer(),
                    Text(
                      tr(tool.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 12.8,
                        height: 1.25,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      tr(tool.description),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant.withOpacity(0.9),
                        fontSize: 10,
                        height: 1.25,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
