import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/storage/app_files.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/skills.dart';

/// 技能管理：预置技能 + 自定义技能的增删改与文件导入。
///
/// 入口在「用户 → AI 配置 → 技能管理」，对话页只负责「选用」。
class SkillManagePage extends StatefulWidget {
  const SkillManagePage({super.key});

  @override
  State<SkillManagePage> createState() => _SkillManagePageState();
}

class _SkillManagePageState extends State<SkillManagePage> {
  List<AssistantSkill>? _skills;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final skills = await SkillStore.all();
    if (!mounted) return;
    setState(() => _skills = skills);
  }

  Future<void> _edit([AssistantSkill? skill]) async {
    final result = await showDialog<_SkillDraft>(
      context: context,
      builder: (_) => _SkillEditDialog(skill: skill),
    );
    if (result == null) return;
    if (skill == null) {
      await SkillStore.add(
        name: result.name,
        description: result.description,
        prompt: result.prompt,
      );
    } else {
      await SkillStore.update(
        skill.id,
        name: result.name,
        description: result.description,
        prompt: result.prompt,
      );
    }
    await _load();
    if (mounted) showToast(context, tr('已保存'));
  }

  Future<void> _delete(AssistantSkill skill) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除技能')),
        content: Text(trf('确定删除「{n}」？', {'n': skill.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await SkillStore.remove(skill.id);
    await _load();
    if (mounted) showToast(context, tr('已删除'));
  }

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['md', 'markdown', 'txt', 'json'],
      withData: true,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) return;
    try {
      final skill = await SkillStore.importFromFile(
        fileName: file.name,
        content: _utf8Text(file.bytes!),
      );
      await _load();
      if (mounted) {
        showToast(context, trf('已导入技能「{n}」', {'n': skill.name}));
      }
    } on FormatException catch (e) {
      if (mounted) showToast(context, trf('导入失败：{e}', {'e': '$e'}));
    }
  }

  /// 把技能导出成 Markdown 到存储空间（AI 助手分类），可再次导入。
  Future<void> _export(AssistantSkill skill) async {
    try {
      final stored = await AppStore.saveText(
        category: AppStoreCategory.assistant,
        name: '${skill.name}.md',
        content: SkillStore.exportMarkdown(skill),
      );
      if (mounted) {
        showToast(
          context,
          trf('已导出到存储空间：{n}', {'n': stored.name}),
        );
      }
    } catch (e) {
      if (mounted) showToast(context, trf('导出失败：{e}', {'e': '$e'}));
    }
  }

  static String _utf8Text(List<int> bytes) {
    var data = bytes;
    if (data.length >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF) {
      data = data.sublist(3);
    }
    return utf8.decode(data, allowMalformed: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final skills = _skills;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('技能管理')),
        actions: [
          IconButton(
            tooltip: tr('新建技能'),
            icon: const Icon(Icons.add),
            onPressed: () => _edit(),
          ),
        ],
      ),
      body: skills == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                SmallHint(
                  text: tr('技能是一段注入到对话开头的提示词；在对话里选中后，该对话会一直沿用'),
                ),
                const SizedBox(height: 12),
                if (skills.isEmpty)
                  const EmptyState(
                    icon: Icons.auto_awesome_outlined,
                    text: '还没有技能，点右上角 + 新建或导入技能文件',
                  )
                else
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < skills.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 1,
                              thickness: 1,
                              indent: 16,
                              color: theme.colorScheme.outlineVariant
                                  .withOpacity(0.35),
                            ),
                          _SkillRow(
                            skill: skills[i],
                            onOpen: () => _showPrompt(skills[i]),
                            onExport: () => _export(skills[i]),
                            onEdit:
                                skills[i].builtIn ? null : () => _edit(skills[i]),
                            onDelete:
                                skills[i].builtIn ? null : () => _delete(skills[i]),
                          ),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _import,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: Text(tr('导入技能文件')),
                ),
                const SizedBox(height: 8),
                SmallHint(
                  text: tr('技能文件为 .md：开头用 --- 包住 name / description，正文即提示词；旧版 .json 仍可导入'),
                ),
              ],
            ),
    );
  }

  Future<void> _showPrompt(AssistantSkill skill) async {
    final theme = Theme.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(skill.name, style: theme.textTheme.titleSmall),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              skill.prompt,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('关闭')),
          ),
        ],
      ),
    );
  }
}

class _SkillRow extends StatelessWidget {
  const _SkillRow({
    required this.skill,
    required this.onOpen,
    required this.onExport,
    this.onEdit,
    this.onDelete,
  });

  final AssistantSkill skill;
  final VoidCallback onOpen;
  final VoidCallback onExport;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        skill.builtIn ? Icons.verified_outlined : Icons.description_outlined,
        color: skill.builtIn ? theme.colorScheme.primary : null,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(skill.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (skill.builtIn) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                tr('预置'),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        skill.description.isEmpty ? tr('无描述') : skill.description,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onOpen,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey<String>('skill-export-${skill.id}'),
            tooltip: tr('导出到存储空间'),
            icon: const Icon(Icons.save_alt, size: 18),
            onPressed: onExport,
          ),
          if (!skill.builtIn)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 18),
              tooltip: tr('更多'),
              onSelected: (value) {
                if (value == 'edit') onEdit?.call();
                if (value == 'delete') onDelete?.call();
              },
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'edit',
                  child: Text(tr('编辑')),
                ),
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Text(tr('删除')),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _SkillDraft {
  const _SkillDraft(this.name, this.description, this.prompt);

  final String name;
  final String description;
  final String prompt;
}

class _SkillEditDialog extends StatefulWidget {
  const _SkillEditDialog({this.skill});

  final AssistantSkill? skill;

  @override
  State<_SkillEditDialog> createState() => _SkillEditDialogState();
}

class _SkillEditDialogState extends State<_SkillEditDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.skill?.name ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.skill?.description ?? '');
  late final TextEditingController _prompt =
      TextEditingController(text: widget.skill?.prompt ?? '');

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty || _prompt.text.trim().isEmpty) {
      showToast(context, tr('名称与提示词不能为空'));
      return;
    }
    Navigator.of(context).pop(_SkillDraft(
      _name.text.trim(),
      _description.text.trim(),
      _prompt.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.skill == null ? tr('新建技能') : tr('编辑技能')),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: tr('名称'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _description,
                decoration: InputDecoration(
                  labelText: tr('一句话描述（可选）'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _prompt,
                minLines: 6,
                maxLines: 12,
                decoration: InputDecoration(
                  labelText: tr('提示词'),
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('取消')),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(tr('保存')),
        ),
      ],
    );
  }
}
