import 'package:flutter/material.dart';

import '../../../../core/settings/assistant_profile.dart';
import '../../../../core/settings/settings_controller.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import 'assistant_profile_edit_page.dart';
import 'skill_manage_page.dart';

/// AI 配置主页：多配置卡片列表。
///
/// 右上角「+」新建；每张卡片占一行（横向方块），点按进入编辑，
/// 右侧 ○/✓ 按钮选择当前使用的配置。
class AssistantSettingsPage extends StatelessWidget {
  const AssistantSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('AI 配置')),
        actions: [
          IconButton(
            tooltip: tr('新建配置'),
            icon: const Icon(Icons.add),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AssistantProfileEditPage(),
                ),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final profiles = settings.assistantProfiles;
          final activeId = settings.activeAssistantProfile?.id ?? '';
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              SmallHint(text: tr('点按卡片编辑配置，右侧按钮选择当前使用的 AI')),
              const SizedBox(height: 8),
              for (final profile in profiles)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ProfileCard(
                    profile: profile,
                    active: profile.id == activeId,
                    onOpen: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              AssistantProfileEditPage(profile: profile),
                        ),
                      );
                    },
                    onSelect: () =>
                        settings.setActiveAssistantProfile(profile.id),
                  ),
                ),
              if (profiles.isEmpty) ...[
                const SizedBox(height: 48),
                Center(
                  child: Column(
                    children: [
                      Icon(Icons.auto_awesome_outlined,
                          size: 48, color: theme.colorScheme.outline),
                      const SizedBox(height: 12),
                      Text(tr('还没有配置，点右上角 + 新建')),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AssistantProfileEditPage(),
                          ),
                        ),
                        icon: const Icon(Icons.add),
                        label: Text(tr('新建配置')),
                      ),
                    ],
                  ),
                ),
              ],
              if (profiles.isNotEmpty) ...[
                const SizedBox(height: 24),
                _UsageCard(settings: settings),
              ],
              const SizedBox(height: 16),
              Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: Text(tr('技能管理')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SkillManagePage(),
                    ),
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

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.active,
    required this.onOpen,
    required this.onSelect,
  });

  final AssistantProfile profile;
  final bool active;
  final VoidCallback onOpen;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = Uri.tryParse(profile.baseUrl)?.host ?? profile.baseUrl;
    final hasKey = profile.apiKey.isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onOpen,
        title: Row(
          children: [
            Expanded(
              child: Text(
                profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (active)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  tr('使用中'),
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer),
                ),
              ),
          ],
        ),
        subtitle: Text(
          '${profile.model.isEmpty ? tr('未设置模型') : profile.model}'
          ' · ${host.isEmpty ? tr('未设置接口地址') : host}'
          '${hasKey ? '' : ' · ${tr('未填写 API Key')}'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // 右侧 ○/✓：选中的配置显示圆圈内对勾。
        trailing: IconButton(
          tooltip: active ? tr('当前使用') : tr('选择此配置'),
          onPressed: active ? null : onSelect,
          icon: Icon(
            active ? Icons.check_circle : Icons.radio_button_unchecked,
            color: active ? theme.colorScheme.primary : null,
          ),
        ),
      ),
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = settings.assistantTokensIn + settings.assistantTokensOut;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('本机累计用量'), style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                _usageItem(tr('输入'), '${settings.assistantTokensIn}'),
                _usageItem(tr('输出'), '${settings.assistantTokensOut}'),
                _usageItem(tr('合计'), '$total'),
              ],
            ),
            if (total > 0) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => settings.resetAssistantUsage(),
                  child: Text(tr('清零统计')),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _usageItem(String label, String value) =>
      Expanded(child: MetricTile(label: label, value: value));
}
