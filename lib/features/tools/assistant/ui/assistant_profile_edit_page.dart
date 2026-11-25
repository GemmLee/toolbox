import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/settings/assistant_profile.dart';
import '../../../../core/settings/settings_controller.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/assistant_api.dart';
import '../../../../core/settings/assistant_platforms.dart';
import '../data/net_diagnostics.dart';

/// 配置编辑页：新建（profile 为 null）或编辑既有配置。
class AssistantProfileEditPage extends StatefulWidget {
  const AssistantProfileEditPage({super.key, this.profile});

  final AssistantProfile? profile;

  @override
  State<AssistantProfileEditPage> createState() =>
      _AssistantProfileEditPageState();
}

class _AssistantProfileEditPageState extends State<AssistantProfileEditPage> {
  final OpenAiCompatClient _client = OpenAiCompatClient();
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  Timer? _debounce;
  bool _runningDiagnostics = false;

  bool get _isEditing => widget.profile != null;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _name = TextEditingController(text: p?.name ?? '');
    _baseUrl =
        TextEditingController(text: p?.baseUrl ?? kDefaultAssistantBaseUrl);
    _model = TextEditingController(text: p?.model ?? kDefaultAssistantModel);
    _apiKey = TextEditingController(text: p?.apiKey ?? '');
  }

  @override
  void dispose() {
    // 退出页面时若还有未落盘的防抖保存（例如粘贴完 API Key 后立刻返回），
    // 先补存一次再销毁控制器，避免刚填写的内容被静默丢弃。
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      unawaited(_saveNow());
    }
    _debounce?.cancel();
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    if (!_isEditing) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => _saveNow());
  }

  Future<void> _saveNow() async {
    final p = widget.profile;
    if (p == null) return;
    await SettingsController.instance.updateAssistantProfile(
      p.id,
      name: _name.text,
      baseUrl: _baseUrl.text,
      model: _model.text.trim().isEmpty ? null : _model.text,
      apiKey: _apiKey.text,
    );
  }

  /// 新建模式：校验后创建并返回。
  Future<void> _create() async {
    if (_baseUrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('请先填写接口地址（Base URL）'))));
      return;
    }
    await SettingsController.instance.addAssistantProfile(
      name: _name.text.trim().isEmpty ? tr('配置') : _name.text,
      baseUrl: _baseUrl.text,
      model: _model.text,
      apiKey: _apiKey.text,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _testConnection() async {
    if (_apiKey.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('请先填写 API Key（不内置，需自行输入）'))),
      );
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _client.chat(
        baseUrl: _baseUrl.text.trim(),
        apiKey: _apiKey.text.trim(),
        model: _model.text.trim(),
        messages: <ChatMessage>[ChatMessage.user('ping')],
      );
      messenger.showSnackBar(SnackBar(content: Text(tr('连接成功'))));
    } on AssistantApiException catch (e) {
      final isModelIssue = e.message.contains('模型不存在') ||
          e.message.toLowerCase().contains('model') &&
              (e.message.toLowerCase().contains('not') ||
                  e.message.toLowerCase().contains('invalid'));
      final tip = isModelIssue ? tr('。请在「模型」一栏从平台建议中重新选择') : '';
      messenger.showSnackBar(
          SnackBar(content: Text('${tr('连接失败')}：${e.message}$tip')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${tr('连接失败')}：$e')));
    }
  }

  Future<void> _queryBalance() async {
    if (_apiKey.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('请先填写 API Key（不内置，需自行输入）'))),
      );
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final matched = AssistantPlatform.match(
      _baseUrl.text,
      SettingsController.instance.customAssistantPlatforms,
    );
    if (matched == null || matched.balanceKind == BalanceKind.none) {
      messenger.showSnackBar(SnackBar(content: Text(tr('该平台未提供余额查询接口'))));
      return;
    }
    try {
      final balance = await _client.queryBalance(
        baseUrl: _baseUrl.text.trim(),
        apiKey: _apiKey.text.trim(),
      );
      if (balance == null) {
        messenger.showSnackBar(SnackBar(content: Text(tr('该平台未提供余额查询接口'))));
      } else {
        messenger.showSnackBar(SnackBar(
          content:
              Text(trf('{name} 余额：{b}', {'name': matched.name, 'b': balance})),
        ));
      }
    } on AssistantApiException catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('${tr('查询失败')}：${e.message}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${tr('查询失败')}：$e')));
    }
  }

  /// 逐层诊断网络：IP 直连 → 系统 DNS → 对照域名 → DoH → HTTPS。
  Future<void> _runDiagnostics() async {
    setState(() => _runningDiagnostics = true);
    List<DiagItem> items;
    try {
      items = await NetDiagnostics.run(baseUrl: _baseUrl.text);
    } catch (e) {
      items = <DiagItem>[
        DiagItem(title: '诊断执行失败', ok: false, detail: '$e'),
      ];
    } finally {
      if (mounted) setState(() => _runningDiagnostics = false);
    }
    if (!mounted) return;

    final report = NetDiagnostics.report(items);
    await showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text(tr('网络诊断')),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            item.ok
                                ? Icons.check_circle_outline
                                : Icons.error_outline,
                            size: 18,
                            color: item.ok
                                ? Colors.green
                                : theme.colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.title,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                SelectableText(item.detail,
                                    style: theme.textTheme.bodySmall),
                                if (item.hint != null) ...[
                                  const SizedBox(height: 2),
                                  Text('→ ${item.hint!}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                              color:
                                                  theme.colorScheme.primary)),
                                ],
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
          actions: [
            TextButton(
              onPressed: () {
                copyWithToast(context, report);
                Navigator.of(context).pop();
              },
              child: Text(tr('复制结果')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr('关闭')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _delete() async {
    final p = widget.profile;
    if (p == null) return;
    final settings = SettingsController.instance;
    if (settings.assistantProfiles.length <= 1) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('至少保留一个配置'))));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('确认删除配置')),
        content: Text(tr('删除「{n}」？API Key 也会一并清除').replaceAll('{n}', p.name)),
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
    if (confirmed != true) return;
    await settings.removeAssistantProfile(p.id);
    if (mounted) Navigator.of(context).pop();
  }

  /// 平台选择区：预设 + 自定义平台收进下拉，右侧按钮直达新建自定义平台。
  /// 自定义平台在下拉项里长按可编辑 / 删除。
  Widget _platformSection(AssistantPlatform? matched, ThemeData theme) {
    final custom = SettingsController.instance.customAssistantPlatforms;
    final platforms = AssistantPlatform.all(custom);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(tr('平台'), style: theme.textTheme.titleSmall),
            const Spacer(),
            TextButton.icon(
              key: const ValueKey('add-custom-platform'),
              onPressed: () => _editCustomPlatform(),
              icon: const Icon(Icons.add, size: 16),
              label: Text(tr('自定义平台')),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 限宽：isExpanded 会让下拉菜单撑满整行，长平台上铺满屏幕太笨重。
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 240,
            child: DropdownButtonFormField<AssistantPlatform>(
              key: const ValueKey('profile-platform'),
              value: matched,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              hint: Text(tr('请选择平台或手动填写接口地址')),
              items: <DropdownMenuItem<AssistantPlatform>>[
                for (final platform in platforms)
                  DropdownMenuItem<AssistantPlatform>(
                    value: platform,
                    child: Text(
                      platform.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) _selectPlatform(value);
              },
            ),
          ),
        ),
        if (matched?.isCustom ?? false) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('profile-edit-custom-platform'),
              onPressed: () => _manageCustomPlatform(matched!),
              icon: const Icon(Icons.edit_outlined, size: 15),
              label: Text(tr('编辑当前平台')),
            ),
          ),
        ],
        if (matched == null && _baseUrl.text.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          SmallHint(
            text: tr('当前接口地址不在平台列表中，可直接填写，也可保存为自定义平台'),
          ),
        ],
      ],
    );
  }

  void _selectPlatform(AssistantPlatform platform) {
    _baseUrl.text = platform.baseUrl;
    if (platform.models.isNotEmpty) _model.text = platform.models.first;
    _scheduleSave();
    setState(() {});
  }

  /// 新建 / 编辑自定义平台；保存后（新建时）自动选中该平台。
  ///
  /// 表单的 TextEditingController 由对话框自己创建/释放：对话框关闭时有退出
  /// 动画，若在这里提前 dispose，动画期间重建会访问已释放的控制器。
  Future<void> _editCustomPlatform([AssistantPlatform? existing]) async {
    final settings = SettingsController.instance;
    final data = await showDialog<_CustomPlatformData>(
      context: context,
      builder: (_) => _CustomPlatformDialog(
        initialName: existing?.name ?? '',
        initialUrl: existing?.baseUrl ??
            (_baseUrl.text.trim().isEmpty
                ? kDefaultAssistantBaseUrl
                : _baseUrl.text.trim()),
        initialModels: existing?.models.join('\n') ?? '',
        editing: existing != null,
      ),
    );
    if (data == null || !mounted) return;
    if (existing == null) {
      final created = await settings.addCustomAssistantPlatform(
        name: data.name,
        baseUrl: data.baseUrl,
        models: data.models,
      );
      _selectPlatform(created);
    } else {
      await settings.updateCustomAssistantPlatform(
        existing.id,
        name: data.name,
        baseUrl: data.baseUrl,
        models: data.models,
      );
      // 编辑的正是当前选中平台时，同步刷新输入框。
      final oldUrl = existing.baseUrl.trim().toLowerCase();
      if (oldUrl.isNotEmpty &&
          _baseUrl.text.trim().toLowerCase().startsWith(oldUrl)) {
        _baseUrl.text = data.baseUrl;
        _model.text = data.models.first;
        _scheduleSave();
      }
      setState(() {});
    }
  }

  Future<void> _manageCustomPlatform(AssistantPlatform platform) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(platform.name),
        content: Text(platform.baseUrl),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('edit'),
            child: Text(tr('编辑')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('delete'),
            child: Text(tr('删除')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'edit') {
      await _editCustomPlatform(platform);
      return;
    }
    if (action != 'delete') return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除自定义平台')),
        content: Text(tr('删除该平台？')),
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
    if (confirmed != true || !mounted) return;
    await SettingsController.instance
        .removeCustomAssistantPlatform(platform.id);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matched = AssistantPlatform.match(
      _baseUrl.text,
      SettingsController.instance.customAssistantPlatforms,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? tr('编辑配置') : tr('新建配置')),
        actions: [
          if (!_isEditing)
            IconButton(
              tooltip: tr('保存'),
              icon: const Icon(Icons.check),
              onPressed: _create,
            ),
          if (_isEditing)
            IconButton(
              tooltip: tr('删除该配置'),
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _Labeled(
            label: tr('名称'),
            child: TextField(
              controller: _name,
              decoration: InputDecoration(
                  hintText: tr('如：智谱-日常'), border: const OutlineInputBorder()),
              onChanged: (_) => _scheduleSave(),
            ),
          ),
          _platformSection(matched, theme),
          const SizedBox(height: 16),
          _Labeled(
            label: tr('接口地址（Base URL）'),
            child: TextField(
              key: const ValueKey('profile-base-url'),
              controller: _baseUrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: kDefaultAssistantBaseUrl,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) {
                _scheduleSave();
                // 平台下拉 / 余额按钮依赖 matched，地址变化后要立即重算。
                setState(() {});
              },
            ),
          ),
          _Labeled(
            label: tr('模型'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('profile-model'),
                  controller: _model,
                  decoration: const InputDecoration(
                    hintText: kDefaultAssistantModel,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _scheduleSave(),
                ),
                // 模型不在预设列表只是提示，不拦截：新模型可直接使用官方
                // model id。用归一化比较避免大小写 / 空格导致误报。
                if (matched != null &&
                    _model.text.trim().isNotEmpty &&
                    !isKnownModel(_model.text, matched)) ...[
                  const SizedBox(height: 8),
                  SmallHint(
                    color: theme.colorScheme.outline,
                    maxLines: 3,
                    text: tr('模型不在预设列表中，可直接输入官方名称或模型 ID，将按输入原样发送'),
                  ),
                ],
                if (matched != null && matched.models.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  ExpansionTile(
                    key: const ValueKey('profile-model-suggestions'),
                    title: Text(
                      tr('推荐的模型'),
                      style: theme.textTheme.bodyMedium,
                    ),
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    tilePadding: EdgeInsets.zero,
                    children: <Widget>[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final m in matched.models)
                            ActionChip(
                              label: Text(m),
                              onPressed: () {
                                _model.text = m;
                                _scheduleSave();
                                setState(() {});
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          _Labeled(
            label: tr('API Key'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _apiKey,
                  // 不用 obscureText：密码框会触发安全键盘、禁用复制粘贴。
                  keyboardType: TextInputType.text,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _scheduleSave(),
                ),
                const SizedBox(height: 6),
                SmallHint(
                  text: tr('密钥仅保存在本机，用于直连所选平台的接口'),
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _testConnection,
                  icon: const Icon(Icons.network_check),
                  label: Text(tr('测试连接')),
                ),
              ),
              const SizedBox(width: 8),
              // 查询余额仅对提供余额接口的平台显示，避免点了只弹「不支持」。
              if (matched != null && matched.balanceKind != BalanceKind.none)
                IconButton(
                  key: const ValueKey('profile-query-balance'),
                  tooltip: tr('查询余额'),
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  onPressed: _queryBalance,
                ),
              IconButton(
                key: const ValueKey('profile-diagnostics'),
                tooltip: tr('网络诊断'),
                onPressed: _runningDiagnostics ? null : _runDiagnostics,
                icon: _runningDiagnostics
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.health_and_safety_outlined),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// 自定义平台表单结果。
class _CustomPlatformData {
  const _CustomPlatformData({
    required this.name,
    required this.baseUrl,
    required this.models,
  });

  final String name;
  final String baseUrl;
  final List<String> models;
}

/// 新建 / 编辑自定义平台的表单对话框，校验错误内联显示。
/// 控制器由对话框 State 自己创建并在 dispose 时释放：对话框关闭时有退出
/// 动画，若由调用方提前 dispose，动画期间重建会访问已释放的控制器。
class _CustomPlatformDialog extends StatefulWidget {
  const _CustomPlatformDialog({
    required this.initialName,
    required this.initialUrl,
    required this.initialModels,
    required this.editing,
  });

  final String initialName;
  final String initialUrl;
  final String initialModels;
  final bool editing;

  @override
  State<_CustomPlatformDialog> createState() => _CustomPlatformDialogState();
}

class _CustomPlatformDialogState extends State<_CustomPlatformDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _models;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _url = TextEditingController(text: widget.initialUrl);
    _models = TextEditingController(text: widget.initialModels);
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _models.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.editing ? tr('编辑自定义平台') : tr('新建自定义平台')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('cp-name'),
              controller: _name,
              decoration: InputDecoration(
                labelText: tr('平台名称'),
                hintText: 'DeepSeek',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('cp-url'),
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: tr('接口地址（Base URL）'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('cp-models'),
              controller: _models,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: tr('模型列表（逗号或换行分隔）'),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('取消')),
        ),
        FilledButton(
          key: const ValueKey('cp-save'),
          onPressed: () {
            final err = _validate();
            if (err != null) {
              setState(() => _error = err);
              return;
            }
            Navigator.of(context).pop(_CustomPlatformData(
              name: _name.text.trim(),
              baseUrl: _url.text.trim(),
              models: parsePlatformModels(_models.text),
            ));
          },
          child: Text(tr('保存')),
        ),
      ],
    );
  }

  String? _validate() {
    if (_name.text.trim().isEmpty) return tr('请填写平台名称');
    if (_url.text.trim().isEmpty) {
      return tr('请先填写接口地址（Base URL）');
    }
    if (parsePlatformModels(_models.text).isEmpty) {
      return tr('请至少填写一个模型');
    }
    return null;
  }
}
