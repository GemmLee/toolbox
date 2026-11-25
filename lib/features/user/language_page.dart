import 'package:flutter/material.dart';

import '../../core/settings/app_l10n.dart';
import '../../core/settings/settings_controller.dart';

/// 应用语言：简体中文 / 繁體中文 / English。
class LanguagePage extends StatelessWidget {
  const LanguagePage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.of().language)),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var i = 0; i < AppLanguage.values.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 1,
                          indent: 16,
                          color: theme.colorScheme.outlineVariant
                              .withOpacity(0.35),
                        ),
                      _option(context, AppLanguage.values[i]),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _option(BuildContext context, AppLanguage language) {
    final theme = Theme.of(context);
    final l10n = AppL10n.of();
    final selected = SettingsController.instance.language == language;
    final title = language == AppLanguage.system
        ? l10n.modeSystem
        : language.nativeName;
    final subtitle = switch (language) {
      AppLanguage.system => 'System locale',
      AppLanguage.simplifiedChinese => 'Simplified Chinese',
      AppLanguage.traditionalChinese => 'Traditional Chinese',
      AppLanguage.english => 'English (US)',
    };
    return ListTile(
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: selected
          ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
          : null,
      onTap: () => SettingsController.instance.setLanguage(language),
    );
  }
}
