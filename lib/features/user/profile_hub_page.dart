import 'package:flutter/material.dart';

import '../../core/settings/app_l10n.dart';
import '../../core/settings/tool_texts.dart';
import '../profile/profile_basic_page.dart';
import '../profile/profile_model.dart';
import '../profile/profile_pension_page.dart';
import '../profile/profile_rates_page.dart';
import '../profile/profile_repository.dart';
import 'settings_tile.dart';

/// 个人信息子目录：基本信息 / 五险一金比例。
class ProfileHubPage extends StatefulWidget {
  const ProfileHubPage({super.key});

  @override
  State<ProfileHubPage> createState() => _ProfileHubPageState();
}

class _ProfileHubPageState extends State<ProfileHubPage> {
  @override
  void initState() {
    super.initState();
    ProfileRepository.load();
    // 老用户升级后，把已有的档案补写进「存储空间 › 个人信息」。
    ProfileRepository.syncMirror();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.profileSection)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          ValueListenableBuilder<UserProfile?>(
            valueListenable: ProfileRepository.notifier,
            builder: (context, profile, _) {
              // 未填写时展示引导文案，已填写时展示城市与税前月薪。
              final empty = profile == null || profile.isEmpty;
              return SettingsGroup(
                tiles: [
                  SettingsTile(
                    icon: Icons.badge_outlined,
                    title: l10n.basicInfo,
                    subtitle: empty
                        ? l10n.basicInfoSubtitle
                        : '${tr(profile.city.name)} · ${profile.gross?.toStringAsFixed(0) ?? '--'}',
                    onTap: () => _push(const ProfileBasicPage()),
                  ),
                  SettingsTile(
                    icon: Icons.percent_outlined,
                    title: l10n.insuranceRates,
                    onTap: () => _push(const ProfileRatesPage()),
                  ),
                  SettingsTile(
                    icon: Icons.elderly_outlined,
                    title: tr('养老与税优信息'),
                    value: (profile?.hasPensionInfo ?? false)
                        ? tr('已填写')
                        : null,
                    onTap: () => _push(const ProfilePensionPage()),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}
