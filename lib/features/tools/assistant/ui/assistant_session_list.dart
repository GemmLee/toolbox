import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/ai_status_indicator.dart';
import '../logic/assistant_controller.dart';
import '../logic/assistant_session.dart';

// —— 左侧对话列表（侧栏 / 抽屉共用） ——

class AssistantSessionList extends StatelessWidget {
  const AssistantSessionList({
    super.key,
    required this.controller,
    required this.onPick,
    required this.onNew,
    required this.onRename,
    required this.onClear,
    required this.onDelete,
    required this.onOpenSettings,
  });

  final AssistantController controller;
  final ValueChanged<String> onPick;
  final VoidCallback onNew;
  final Future<void> Function(AssistantSession) onRename;
  final Future<void> Function(AssistantSession) onClear;
  final Future<void> Function(AssistantSession) onDelete;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = <AssistantSession>[...controller.sessions]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 6, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(tr('对话'), style: theme.textTheme.titleSmall),
                  ),
                  IconButton(
                    tooltip: tr('新对话'),
                    icon: const Icon(Icons.add),
                    onPressed: onNew,
                  ),
                ],
              ),
            ),
            Expanded(
              child: sessions.isEmpty
                  ? Center(
                      child: Text(
                        tr('还没有对话'),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: sessions.length,
                      itemBuilder: (context, index) {
                        final session = sessions[index];
                        final active = session.id == controller.activeSessionId;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: ListTile(
                            dense: true,
                            selected: active,
                            selectedTileColor: theme
                                .colorScheme.primaryContainer
                                .withOpacity(0.45),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            contentPadding:
                                const EdgeInsets.only(left: 12, right: 0),
                            title: Text(
                              session.title.isEmpty ? tr('新对话') : session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                            subtitle: Text(
                              '${trf('{n} 条消息', {'n': session.size})}'
                              ' · ${_sessionTimeLabel(session.updatedAt)}',
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: theme.colorScheme.outline),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (controller.isGenerating(session.id))
                                  const Padding(
                                    padding: EdgeInsets.only(right: 6),
                                    child: AiThinkingDots(size: 4),
                                  ),
                                PopupMenuButton<String>(
                                  tooltip: tr('更多'),
                                  icon: const Icon(Icons.more_vert, size: 18),
                                  onSelected: (value) {
                                    if (value == 'rename') onRename(session);
                                    if (value == 'clear') onClear(session);
                                    if (value == 'delete') onDelete(session);
                                  },
                                  itemBuilder: (context) =>
                                      <PopupMenuEntry<String>>[
                                    PopupMenuItem<String>(
                                      value: 'rename',
                                      child: Text(tr('重命名对话')),
                                    ),
                                    PopupMenuItem<String>(
                                      value: 'clear',
                                      child: Text(tr('清空对话内容')),
                                    ),
                                    PopupMenuItem<String>(
                                      value: 'delete',
                                      child: Text(tr('删除对话')),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            onTap: () => onPick(session.id),
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: const Icon(Icons.settings_outlined, size: 20),
              title: Text(tr('智能助手设置'), style: theme.textTheme.bodyMedium),
              onTap: onOpenSettings,
            ),
          ],
        ),
      ),
    );
  }
}

String _sessionTimeLabel(DateTime time) {
  final now = DateTime.now();
  final diff = now.difference(time);
  if (diff.inMinutes < 1) return tr('刚刚');
  if (diff.inMinutes < 60) return trf('{n} 分钟前', {'n': diff.inMinutes});
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final hm = '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
  if (day == today) return hm;
  if (today.difference(day).inDays == 1) return '${tr('昨天')} $hm';
  return '${time.month}月${time.day}日';
}

/// 当前对话不是正在生成的那段时，给一条可点回的提示。
class AssistantElsewhereBanner extends StatelessWidget {
  const AssistantElsewhereBanner({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const AiThinkingDots(size: 4),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('另一段对话正在生成，点此查看'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 18, color: theme.colorScheme.onSecondaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}
