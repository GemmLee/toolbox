import 'package:flutter/material.dart';

import '../../core/settings/app_l10n.dart';
import '../../core/settings/settings_controller.dart';

/// 字体大小：全局文字缩放 + 实时预览。
class FontSizePage extends StatelessWidget {
  const FontSizePage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(AppL10n.of().fontSize),
        actions: [
          TextButton(
            onPressed: () => settings.setFontScale(1.0),
            child: Text(AppL10n.of().resetDefault),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final l10n = AppL10n.of();
          final theme = Theme.of(context);
          final scale = settings.fontScale;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text(
                            l10n.fontSize,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${(scale * 100).round()}%',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: scale,
                        min: SettingsController.minFontScale,
                        max: SettingsController.maxFontScale,
                        divisions: 10,
                        label: '${(scale * 100).round()}%',
                        onChanged: (value) => settings.setFontScale(value),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'A',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            'A',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.preview,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 预览按目标比例独立绘制，避免与全局缩放叠加两次
                      MediaQuery.withNoTextScaling(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.previewTitle,
                              style: TextStyle(
                                fontSize: 19 * scale,
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.onSurface,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              l10n.previewBody,
                              style: TextStyle(
                                fontSize: 14 * scale,
                                color: theme.colorScheme.onSurface,
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '¥12,000.00 · 08:30',
                              style: TextStyle(
                                fontSize: 12 * scale,
                                color: theme.colorScheme.onSurfaceVariant,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
