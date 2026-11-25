import 'package:flutter/material.dart';

import '../../core/settings/app_background.dart';
import '../../core/settings/app_l10n.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/widgets/mini_segmented.dart';
import '../../features/tools/assistant/ui/assistant_settings_page.dart';
import 'about_page.dart';
import 'app_storage_page.dart';
import 'background_page.dart';
import 'default_open_tool_page.dart';
import 'font_size_page.dart';
import 'language_page.dart';
import 'settings_tile.dart';
import 'theme_color_page.dart';

/// 「用户」主目录：账户 / 外观 / 数据与关于。
class UserPage extends StatelessWidget {
  const UserPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final l10n = AppL10n.of();
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            SettingsGroup(
              title: tr('智能'),
              tiles: [
                SettingsTile(
                  icon: Icons.tune_outlined,
                  title: tr('AI 配置'),
                  onTap: () => _push(context, const AssistantSettingsPage()),
                ),
              ],
            ),
            SettingsGroup(
              title: tr('外观与语言'),
              tiles: [
                SettingsTile(
                  icon: Icons.brightness_6_outlined,
                  title: l10n.theme,
                  showChevron: false,
                  trailing: _themeSegmented(settings),
                ),
                SettingsTile(
                  icon: Icons.wallpaper_outlined,
                  title: l10n.background,
                  value: _backgroundLabel(l10n, settings.backgroundKind),
                  onTap: () => _push(context, const BackgroundPage()),
                ),
                SettingsTile(
                  icon: Icons.palette_outlined,
                  title: l10n.themeColor,
                  leadingColor: settings.themeColor.color,
                  onTap: () => _push(context, const ThemeColorPage()),
                ),
                SettingsTile(
                  icon: Icons.format_size_outlined,
                  title: l10n.fontSize,
                  value: '${(settings.fontScale * 100).round()}%',
                  onTap: () => _push(context, const FontSizePage()),
                ),
                SettingsTile(
                  icon: Icons.translate_outlined,
                  title: l10n.language,
                  value: settings.language == AppLanguage.system
                      ? l10n.modeSystem
                      : settings.language.nativeName,
                  onTap: () => _push(context, const LanguagePage()),
                ),
              ],
            ),
            SettingsGroup(
              title: tr('默认与数据'),
              tiles: [
                SettingsTile(
                  icon: Icons.open_in_new_outlined,
                  title: tr('默认打开工具'),
                  onTap: () => _push(context, const DefaultOpenToolPage()),
                ),
                SettingsTile(
                  icon: Icons.storage_outlined,
                  title: l10n.storage,
                  onTap: () => _push(context, const AppStoragePage()),
                ),
              ],
            ),
            SettingsGroup(
              title: tr('关于'),
              tiles: [
                SettingsTile(
                  icon: Icons.info_outline,
                  title: l10n.aboutTitle,
                  onTap: () => _push(context, const AboutPage()),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  static String _backgroundLabel(AppL10n l10n, BackgroundKind kind) =>
      switch (kind) {
        BackgroundKind.none => l10n.bgNone,
        BackgroundKind.color => l10n.bgSolid,
        BackgroundKind.gradient => l10n.bgGradient,
        BackgroundKind.image => l10n.bgImage,
      };
}

/// 主题行的右侧分段按钮（系统/浅色/深色），与工资页同款紧凑胶囊。
Widget _themeSegmented(SettingsController settings) {
  final l10n = AppL10n.of();
  return MiniSegmented<ThemeMode>(
    options: [
      MiniSegmentedOption<ThemeMode>(
        value: ThemeMode.system,
        label: l10n.themeSystem,
        key: const ValueKey('theme-system'),
      ),
      MiniSegmentedOption<ThemeMode>(
        value: ThemeMode.light,
        label: l10n.themeLight,
        key: const ValueKey('theme-light'),
      ),
      MiniSegmentedOption<ThemeMode>(
        value: ThemeMode.dark,
        label: l10n.themeDark,
        key: const ValueKey('theme-dark'),
      ),
    ],
    selected: settings.themeMode,
    onChanged: (mode) => settings.setThemeMode(mode),
  );
}
