import 'package:flutter/material.dart';

import '../../core/settings/default_open_tools.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/widgets/app_widgets.dart';

/// 「默认打开工具」：按文件格式设置外部导入时默认交给哪个工具处理。
///
/// 只有一种处理方式的格式也列出来（只读），以后新增处理方式直接在此扩展。
class DefaultOpenToolPage extends StatelessWidget {
  const DefaultOpenToolPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(title: Text(tr('默认打开工具'))),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: <Widget>[
              SmallHint(text: tr('从其他应用打开或分享文件时，按这里的设置处理。')),
              const SizedBox(height: 12),
              for (final rule in kDefaultOpenRules) ...<Widget>[
                _ruleCard(context, theme, settings, rule),
                const SizedBox(height: 10),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _ruleCard(
    BuildContext context,
    ThemeData theme,
    SettingsController settings,
    DefaultOpenRule rule,
  ) {
    final current =
        settings.defaultOpenActionFor('sample.${rule.extensions.first}');
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.insert_drive_file_outlined,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    rule.label,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (rule.actions.length == 1)
              ListTile(
                key: ValueKey<String>('default-open-single-${rule.id}'),
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                leading: Icon(Icons.check,
                    size: 18, color: theme.colorScheme.primary),
                title: Text(tr(actionName(rule.actions.first))),
                subtitle: Text(tr(actionDescription(rule.actions.first))),
              )
            else
              for (final action in rule.actions)
                RadioListTile<DefaultOpenAction>(
                  key: ValueKey<String>(
                    'default-open-${rule.id}-${actionKey(action)}',
                  ),
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  value: action,
                  groupValue: current,
                  title: Text(tr(actionName(action))),
                  subtitle: Text(tr(actionDescription(action))),
                  onChanged: (value) {
                    if (value != null) {
                      settings.setDefaultOpenTool(rule.id, value);
                    }
                  },
                ),
          ],
        ),
      ),
    );
  }
}
