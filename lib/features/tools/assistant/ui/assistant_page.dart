import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/ai_status_indicator.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/storage/store_picker.dart';
import '../data/document_extractor.dart';
import '../../../../core/settings/assistant_platforms.dart';
import '../data/skills.dart';
import '../logic/assistant_controller.dart';
import '../logic/assistant_session.dart';
import 'assistant_bubble.dart';
import 'assistant_session_list.dart';
import 'assistant_settings_page.dart';
import 'skill_manage_page.dart';

/// 智能助手：自由聊天 + 技能处理文件。
class AssistantPage extends StatefulWidget {
  const AssistantPage({super.key});

  @override
  State<AssistantPage> createState() => AssistantPageState();
}

class AssistantPageState extends State<AssistantPage> {
  /// 全局单例：离开页面不销毁，生成中的请求会继续跑完。
  final AssistantController _controller = AssistantController.instance;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();

  /// 宽屏时侧栏是否展开（窄屏改用抽屉）。
  bool _sidebarOpen = true;

  /// 正在读取/解析附件（区分于 AI 生成状态）。
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_scrollToBottom);
    _controller.load();
  }

  @override
  void dispose() {
    _controller.removeListener(_scrollToBottom);
    // 注意：不 dispose 控制器——对话要继续在后台生成，回来才能看到结果。
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const AssistantSettingsPage()));
    await _controller.load();
  }

  Future<void> _pickAttachment() async {
    // 附件既可以从手机选，也可以直接用存储空间里的文件。
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.smartphone_outlined),
              title: Text(tr('从手机选择文件')),
              onTap: () => Navigator.of(context).pop('phone'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(tr('从存储空间选择')),
              onTap: () => Navigator.of(context).pop('store'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    String? name;
    List<int>? bytes;
    if (source == 'store') {
      final stored = await pickStoredFile(context,
          title: tr('选择附件'), extensions: DocumentExtractor.supportedExtensions);
      if (stored == null || !mounted) return;
      try {
        name = stored.name;
        bytes = await stored.file.readAsBytes();
      } catch (e) {
        if (mounted) showToast(context, trf('文件读取失败：{e}', {'e': '$e'}));
        return;
      }
    } else {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: DocumentExtractor.supportedExtensions,
        withData: true,
      );
      final file = result?.files.single;
      if (file == null || file.bytes == null) return;
      name = file.name;
      bytes = file.bytes;
    }
    final data = bytes;
    if (!mounted || data == null) return;
    setState(() => _uploading = true);
    try {
      // 让上传动画至少呈现一帧，避免大文件解析瞬间完成时看不到反馈。
      await Future<void>.delayed(const Duration(milliseconds: 180));
      final doc = DocumentExtractor.extract(fileName: name, bytes: data);
      if (!mounted) return;
      _controller
          .addAttachment(AssistantAttachment(name: doc.name, text: doc.text));
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _sendMessage() async {
    final text = _input.text.trim();
    if (text.isEmpty && _controller.attachments.isEmpty) return;
    if (_controller.streaming) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('另一段对话正在生成，请稍候或点侧栏查看'))),
      );
      return;
    }
    _input.clear();
    await _controller.send(text);
  }

  Future<void> _renameSession(AssistantSession session) async {
    final input = TextEditingController(text: session.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('重命名对话')),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('对话名称')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr('取消'))),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(input.text),
              child: Text(tr('保存'))),
        ],
      ),
    );
    if (title != null) await _controller.renameSession(session.id, title);
    input.dispose();
  }

  Future<void> _clearSession(AssistantSession session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('清空对话')),
        content: Text(tr('该对话的聊天记录将被删除，且不可恢复')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(tr('取消'))),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('清空'))),
        ],
      ),
    );
    if (ok == true) await _controller.clearSession(session.id);
  }

  Future<void> _deleteSession(AssistantSession session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除对话')),
        content: Text(tr('该对话的聊天记录将被删除，且不可恢复')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(tr('取消'))),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('删除'))),
        ],
      ),
    );
    if (ok == true) await _controller.deleteSession(session.id);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final session = _controller.activeSession;
    final title = (session?.title ?? '').trim();

    final sidebar = AssistantSessionList(
      controller: _controller,
      onPick: (id) {
        _controller.selectSession(id);
        if (!wide) Navigator.of(context).pop();
      },
      onNew: () {
        _controller.newSession();
        if (!wide) Navigator.of(context).pop();
      },
      onRename: _renameSession,
      onClear: _clearSession,
      onDelete: _deleteSession,
      onOpenSettings: () {
        if (!wide) Navigator.of(context).pop();
        _openSettings();
      },
    );

    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: tr('对话列表'),
            icon: Icon(wide
                ? (_sidebarOpen ? Icons.menu_open : Icons.menu)
                : Icons.menu),
            onPressed: () {
              if (wide) {
                setState(() => _sidebarOpen = !_sidebarOpen);
              } else {
                Scaffold.of(context).openDrawer();
              }
            },
          ),
        ),
        title: Text(
          title.isEmpty ? tr('智能助手') : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // 右上角只留「开启新对话」：设置与清空都在左侧对话列表里。
        actions: [
          IconButton(
            tooltip: tr('开启新对话'),
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: () => _controller.newSession(),
          ),
        ],
      ),
      drawer: wide ? null : Drawer(width: 300, child: SafeArea(child: sidebar)),
      body: wide
          ? Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  width: _sidebarOpen ? 264 : 0,
                  child: _sidebarOpen
                      ? ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.centerLeft,
                            minWidth: 264,
                            maxWidth: 264,
                            child: sidebar,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                if (_sidebarOpen) const VerticalDivider(width: 1),
                Expanded(child: _buildChat()),
              ],
            )
          : _buildChat(),
    );
  }

  Widget _buildChat() {
    return SafeArea(
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final messages = _controller.messages;
          final streamingHere = _controller.streaming &&
              _controller.streamingSessionId == _controller.activeSessionId;
          final streamingElsewhere = _controller.streaming && !streamingHere;
          return Column(
            children: [
              if (!_controller.configured) _ConfigBanner(onOpen: _openSettings),
              if (streamingElsewhere)
                AssistantElsewhereBanner(
                  onTap: () {
                    final id = _controller.streamingSessionId;
                    if (id != null) _controller.selectSession(id);
                  },
                ),
              Expanded(
                child: messages.isEmpty && !streamingHere
                    ? _EmptyHint(controller: _controller)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        itemCount: messages.length + (streamingHere ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index < messages.length) {
                            return AssistantBubble(
                                data: AssistantBubbleData.of(messages[index]));
                          }
                          return AssistantBubble(
                              data: AssistantBubbleData.streaming(
                                  _controller.partial));
                        },
                      ),
              ),
              if (_uploading)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: AiStatusIndicator.uploading(label: tr('正在解析附件…')),
                ),
              if (_controller.attachments.isNotEmpty)
                _AttachmentRow(controller: _controller),
              _Composer(
                controller: _controller,
                input: _input,
                focus: _focus,
                onSend: _sendMessage,
                onPick: _pickAttachment,
              ),
            ],
          );
        },
      ),
    );
  }
}

// —— 底部技能入口 ——

/// 与模型选择同一行、靠最右侧的技能选择按钮。
class _SkillButton extends StatelessWidget {
  const _SkillButton({required this.controller});

  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final skill = controller.activeSkill;
    final color = theme.colorScheme.primary;
    return GestureDetector(
      key: const ValueKey('assistant-skill-button'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _showSkillSheet(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.32)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.auto_awesome, size: 14, color: color),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 76),
              child: Text(
                skill?.name ?? tr('技能'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSkillSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _SkillSheet(controller: controller),
    );
  }
}

class _SkillSheet extends StatefulWidget {
  const _SkillSheet({required this.controller});

  final AssistantController controller;

  @override
  State<_SkillSheet> createState() => _SkillSheetState();
}

class _SkillSheetState extends State<_SkillSheet> {
  @override
  Widget build(BuildContext context) {
    final skills = widget.controller.skills;
    final active = widget.controller.activeSkill;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(tr('选择技能'),
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              TextButton.icon(
                onPressed: _manage,
                icon: const Icon(Icons.tune, size: 18),
                label: Text(tr('管理技能')),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: Text(tr('不使用技能（自由对话）')),
            selected: active == null,
            onTap: () => _pick(null),
          ),
          for (final skill in skills)
            ListTile(
              leading: Icon(skill.builtIn
                  ? Icons.verified_outlined
                  : Icons.description_outlined),
              title: Text(skill.name),
              subtitle:
                  skill.description.isEmpty ? null : Text(skill.description),
              selected: active?.id == skill.id,
              onTap: () => _pick(skill),
            ),
          const SizedBox(height: 8),
          SmallHint(
            text: tr('技能在「用户 → AI 配置 → 技能管理」里新建或导入'),
          ),
        ],
      ),
    );
  }

  Future<void> _pick(AssistantSkill? skill) async {
    await widget.controller.selectSkill(skill);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _manage() async {
    final navigator = Navigator.of(context);
    navigator.pop();
    await navigator
        .push(MaterialPageRoute<void>(builder: (_) => const SkillManagePage()));
    await widget.controller.refreshSkills();
  }
}

// —— 提示条 ——

class _ConfigBanner extends StatelessWidget {
  const _ConfigBanner({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.key_outlined,
                  size: 18, color: theme.colorScheme.onTertiaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('尚未配置 API Key，点此前往「智能助手设置」'),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 20, color: theme.colorScheme.onTertiaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.controller});

  final AssistantController controller;

  /// 从模型 id 里取简短品牌名：glm-5.3 → GLM，deepseek-v4-flash → DeepSeek。
  String _modelName(String model) {
    final m = model.trim().toLowerCase();
    if (m.contains('glm')) return 'GLM';
    if (m.contains('deepseek')) return 'DeepSeek';
    if (m.contains('qwen')) return 'Qwen';
    if (m.contains('kimi')) return 'Kimi';
    if (m.isEmpty) return tr('助手');
    return model.trim().split(RegExp(r'[-_/ ]')).first;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = _modelName(controller.settings.assistantModel);
    final skill = controller.activeSkill;
    final line = skill == null || skill.name.trim().isEmpty
        ? trf('和 {model} 聊一聊', <String, Object?>{'model': model})
        : trf('和 {model} 一起处理「{skill}」',
            <String, Object?>{'model': model, 'skill': skill.name});
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.auto_awesome_outlined,
                size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(line,
                style: theme.textTheme.titleSmall, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

// —— 附件与输入区 ——

class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({required this.controller});

  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final a in controller.attachments)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InputChip(
                label: Text(a.name, overflow: TextOverflow.ellipsis),
                avatar: const Icon(Icons.description_outlined, size: 16),
                onDeleted: () => controller.removeAttachment(a),
                labelStyle: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.input,
    required this.focus,
    required this.onSend,
    required this.onPick,
  });

  final AssistantController controller;
  final TextEditingController input;
  final FocusNode focus;
  final VoidCallback onSend;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // 底部留白略增，让整块设置/输入区离屏底稍远；上方与消息区也留出间距。
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: tr('添加文件'),
                icon: const Icon(Icons.attach_file),
                onPressed: controller.streaming ? null : onPick,
              ),
              Expanded(
                child: TextField(
                  controller: input,
                  focusNode: focus,
                  minLines: 2,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: tr('输入消息…'),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              controller.streaming
                  ? IconButton(
                      tooltip: tr('停止'),
                      icon: Icon(Icons.stop_circle_outlined,
                          color: theme.colorScheme.error, size: 30),
                      onPressed: controller.stop,
                    )
                  : IconButton(
                      tooltip: tr('发送'),
                      icon: Icon(Icons.send,
                          color: theme.colorScheme.primary, size: 26),
                      onPressed: onSend,
                    ),
            ],
          ),
          // 输入框下方同一行：左侧模型选择，最右侧技能选择。
          Row(
            children: <Widget>[
              Expanded(child: _ModelBar(controller: controller)),
              const SizedBox(width: 6),
              _SkillButton(controller: controller),
            ],
          ),
        ],
      ),
    );
  }
}

/// 输入框下方的模型条：点击或上拉弹出模型选择面板。
class _ModelBar extends StatelessWidget {
  const _ModelBar({required this.controller});

  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = controller.settings;
    final model = settings.assistantModel;
    final profile = settings.activeAssistantProfile;
    final label = model.isEmpty ? tr('未选择模型') : model;
    return GestureDetector(
      key: const ValueKey('assistant-model-bar'),
      behavior: HitTestBehavior.opaque,
      onTap: () => showModelSheet(context, controller),
      onVerticalDragEnd: (details) {
        // 向上拖动即打开面板，向下拖动不做处理（避免误触）。
        if ((details.primaryVelocity ?? 0) < -80) {
          showModelSheet(context, controller);
        }
      },
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        // 用底色胶囊 + 主题色文字；放在左侧，右侧留给技能入口。
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: (profile == null
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary)
                  .withOpacity(0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: (profile == null
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary)
                    .withOpacity(0.32),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.tune_rounded,
                  size: 14,
                  color: profile == null
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    profile == null ? tr('未配置 AI，点此设置') : '${tr('模型')}：$label',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: profile == null
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.keyboard_arrow_up_rounded,
                  size: 18,
                  color: profile == null
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 模型选择面板：当前配置对应平台的模型列表 + 手动输入。
Future<void> showModelSheet(
    BuildContext context, AssistantController controller) async {
  final settings = controller.settings;
  if (settings.activeAssistantProfile == null) {
    await controller.load();
    if (!context.mounted) return;
    if (settings.activeAssistantProfile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('尚未配置 AI 配置，请先到「用户 → AI 配置」新建'))),
      );
      return;
    }
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ModelSheet(controller: controller),
  );
}

class _ModelSheet extends StatefulWidget {
  const _ModelSheet({required this.controller});

  final AssistantController controller;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  late final TextEditingController _custom =
      TextEditingController(text: widget.controller.settings.assistantModel);

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  /// 应用模型；[profileId] 为空表示沿用当前配置。
  Future<void> _apply(String model, {String? profileId}) async {
    final name = model.trim();
    if (name.isEmpty) return;
    final settings = widget.controller.settings;
    final targetId = profileId ?? settings.activeAssistantProfile?.id;
    if (targetId == null) return;
    // 选的是别的配置下的模型时先切过去，否则会出现「模型对、地址/Key 不对」。
    await settings.setActiveAssistantProfile(targetId);
    await settings.updateAssistantProfile(targetId, model: name);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = widget.controller.settings;
    final profile = settings.activeAssistantProfile;
    final current = settings.assistantModel;
    final platform = AssistantPlatform.match(
        settings.assistantBaseUrl, settings.customAssistantPlatforms);
    // 当前配置可选：平台预置 + 正在用的模型。
    final own = <String>{
      ...?platform?.models,
      if (current.isNotEmpty) current,
    }.toList(growable: false);
    // 其它 AI 配置的模型也列进来，点选时连带切换配置。
    final others = <({String id, String name, List<String> models})>[];
    for (final p in settings.assistantProfiles) {
      if (p.id == profile?.id) continue;
      final pf =
          AssistantPlatform.match(p.baseUrl, settings.customAssistantPlatforms);
      final list = <String>{
        ...?pf?.models,
        if (p.model.isNotEmpty) p.model,
      }.where((m) => !own.contains(m)).toList(growable: false);
      if (list.isEmpty) continue;
      others.add((id: p.id, name: p.name, models: list));
    }
    final empty = own.isEmpty && others.isEmpty;
    return SafeArea(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(tr('选择模型'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
                ),
                if (platform != null)
                  Text(platform.name,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
            if (profile != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  trf('当前模型：{m}', {'m': current.isEmpty ? '-' : current}),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            if (empty) SmallHint(text: tr('该平台没有预置模型列表，请在下方手动输入')),
            for (final m in own)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  m == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 20,
                  color: m == current
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  m,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight:
                        m == current ? FontWeight.w600 : FontWeight.w500,
                    color: m == current
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                ),
                onTap: () => _apply(m),
              ),
            for (final group in others) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Icon(Icons.swap_horiz,
                      size: 14, color: theme.colorScheme.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      trf('切换配置：{n}', {'n': group.name}),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              for (final m in group.models)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.radio_button_unchecked,
                      size: 20, color: theme.colorScheme.onSurfaceVariant),
                  title: Text(
                    m,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  onTap: () => _apply(m, profileId: group.id),
                ),
            ],
            const Divider(height: 24),
            TextField(
              controller: _custom,
              decoration: InputDecoration(
                labelText: tr('手动输入模型名'),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: tr('确定'),
                  icon: const Icon(Icons.check),
                  onPressed: () => _apply(_custom.text),
                ),
              ),
              onSubmitted: _apply,
            ),
          ],
        ),
      ),
    );
  }
}
