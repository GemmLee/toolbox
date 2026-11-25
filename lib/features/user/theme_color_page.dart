import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/settings/app_l10n.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/settings/theme_palette.dart';

/// 主题色：色点网格，选中项显示对勾与描边。
class ThemeColorPage extends StatelessWidget {
  const ThemeColorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.of().themeColor)),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final theme = Theme.of(context);
          final selectedId = settings.themeColorId;
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 14,
              crossAxisSpacing: 6,
              childAspectRatio: 0.86,
            ),
            itemCount: ThemePalette.all.length,
            itemBuilder: (context, index) {
              final entry = ThemePalette.all[index];
              final selected = entry.id == selectedId;
              final onColor = AppTheme.readableOn(entry.color);
              return InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => settings.setThemeColor(entry.id),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 选中态：外圈主题色 + 中间留白 + 色点，比单纯描边更清晰
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      width: 64,
                      height: 64,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? entry.color
                              : theme.colorScheme.outlineVariant
                                  .withOpacity(0.9),
                          width: selected ? 2.2 : 1,
                        ),
                      ),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        decoration: BoxDecoration(
                          color: entry.color,
                          shape: BoxShape.circle,
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: entry.color.withOpacity(
                                selected ? 0.34 : 0.18,
                              ),
                              blurRadius: selected ? 14 : 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: selected
                            ? Icon(Icons.check_rounded,
                                size: 24, color: onColor)
                            : null,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      tr(entry.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
