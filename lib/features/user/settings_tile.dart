import 'package:flutter/material.dart';

import '../../core/widgets/app_backdrop.dart';
/// 设置分组卡片：一组入口用圆角卡片包裹，组间留白。
/// [title] 传 null 时不显示左上角小字注释。
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    this.tiles = const <Widget>[],
  });

  final String? title;
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                title!,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: BackdropStyle.foregroundOf(
                    context,
                    theme.colorScheme.onSurfaceVariant,
                  ).withOpacity(0.85),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 50,
                      color: theme.colorScheme.outlineVariant
                          .withOpacity(0.55),
                    ),
                  tiles[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置入口行：图标 + 标题 + 右侧当前值 + 箭头。
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.leadingColor,
    this.onTap,
    this.trailing,
    this.showChevron = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 右侧当前值（如「跟随系统」「晴空蓝」）。
  final String? value;

  /// 图标底色（用于主题色圆点等）。
  final Color? leadingColor;
  final VoidCallback? onTap;

  /// 自定义右侧控件（如分段按钮），提供时取代 value 与箭头。
  final Widget? trailing;

  /// 是否显示右侧箭头。
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = leadingColor ?? theme.colorScheme.primary;
    final muted = BackdropStyle.foregroundOf(
      context,
      theme.colorScheme.onSurfaceVariant,
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        // 去掉图标框后由文字撑高；最小高 32 与分段按钮行对齐，总高 52。
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Row(
          children: [
            SizedBox(
              width: 24,
              child: leadingColor != null
                  ? Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    )
                  : Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ] else ...[
              if (value != null) ...[
                const SizedBox(width: 8),
                Text(
                  value!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: muted,
                  ),
                ),
              ],
              if (showChevron) ...[
                const SizedBox(width: 2),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: muted.withOpacity(0.7),
                ),
              ],
            ],
          ],
          ),
        ),
      ),
    );
  }
}
