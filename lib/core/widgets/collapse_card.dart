import 'package:flutter/material.dart';

/// 通用可折叠卡片：标题 + 小三角，展开显示 children。
class CollapseCard extends StatefulWidget {
  const CollapseCard({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.trailing,
    this.actions,
    this.initiallyExpanded = false,
    this.dense = false,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  /// 标题左侧固定内容（如用量文本）。
  final Widget? trailing;

  /// 标题右侧的操作按钮（展开/收起箭头之前）。
  final List<Widget>? actions;
  final bool initiallyExpanded;

  /// 紧凑排布：标题栏与内容区的上下留白一起收窄。
  final bool dense;

  @override
  State<CollapseCard> createState() => _CollapseCardState();
}

class _CollapseCardState extends State<CollapseCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: widget.dense
                  ? const EdgeInsets.fromLTRB(14, 10, 6, 10)
                  : const EdgeInsets.fromLTRB(16, 14, 8, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (widget.subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (widget.trailing != null) ...[
                    const SizedBox(width: 8),
                    widget.trailing!,
                  ],
                  if (widget.actions != null) ...widget.actions!,
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            sizeCurve: Curves.easeInOut,
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              // 顶部留出空间：输入框的浮动 label 会画在边框上沿之上，
              // 紧贴标题时会被上方的说明文字遮住半行。
              padding: widget.dense
                  ? const EdgeInsets.fromLTRB(14, 8, 14, 12)
                  : const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
