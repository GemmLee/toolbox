import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/platform/auto_click.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import 'auto_click_models.dart';
import 'auto_click_profiles.dart';

/// 自动点击：配置动作序列 → 启动悬浮控制面板 → 切到目标应用点「开始」。
///
/// 手势由 Android 无障碍服务执行，坐标按屏幕百分比保存，换分辨率不用重填。
/// 悬浮面板上的「取点」会把这次点击的坐标回传过来，直接追加一个点击动作，
/// 省得让用户自己估百分比。
class AutoClickPage extends StatefulWidget {
  const AutoClickPage({
    super.key,
    this.host,
    this.loader,
    this.saver,
    this.profilesLoader,
    this.profilesSaver,
    this.activeIdLoader,
    this.exporter,
    this.importer,
  });

  /// 注入点：widget 测试用假实现，不碰原生通道与 SharedPreferences。
  final AutoClickHost? host;
  final Future<AutoClickConfig> Function()? loader;
  final Future<void> Function(AutoClickConfig)? saver;

  /// 方案管理注入点：默认走 [AutoClickProfileStore] 与文件选择。
  final Future<List<AutoClickProfile>> Function()? profilesLoader;
  final Future<void> Function(List<AutoClickProfile> profiles, String activeId)?
      profilesSaver;
  final Future<String> Function(List<AutoClickProfile> profiles)?
      activeIdLoader;

  /// 导出：拿到 JSON 文本，返回给用户看的保存位置（null 表示取消）。
  final Future<String?> Function(String json, String suggestedName)? exporter;

  /// 导入：返回读到的 JSON 文本（null 表示取消）。
  final Future<String?> Function()? importer;

  @override
  State<AutoClickPage> createState() => _AutoClickPageState();
}

class _AutoClickPageState extends State<AutoClickPage> {
  final TextEditingController _interval = TextEditingController();
  final TextEditingController _randomDelay = TextEditingController();
  final TextEditingController _repeat = TextEditingController();

  AutoClickConfig _config = AutoClickConfig.defaults();

  /// 本机保存的多套动作方案；当前编辑的 [_config] 始终等于激活方案的 config。
  List<AutoClickProfile> _profiles = const <AutoClickProfile>[];
  String _activeId = '';
  bool _loading = true;
  bool _canDraw = false;
  bool _accessibility = false;
  bool _showing = false;

  AutoClickHost get _host => widget.host ?? const AutoClickHost();

  AutoClickProfile? get _activeProfile {
    for (final p in _profiles) {
      if (p.id == _activeId) return p;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _host.listenPoints?.call(_onPickedPoint);
    _load();
  }

  @override
  void dispose() {
    _host.listenPoints?.call(null);
    _interval.dispose();
    _randomDelay.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // 方案列表：默认从本机仓库读；注入点供 widget 测试隔离 SharedPreferences。
    final profiles =
        await (widget.profilesLoader ?? AutoClickProfileStore.load)();
    final activeId = await (widget.activeIdLoader ??
        ((List<AutoClickProfile> list) =>
            AutoClickProfileStore.activeIdOf(list)))(profiles);

    // config 来源：旧注入 loader 优先（保持老测试语义），否则取激活方案。
    AutoClickProfile? active;
    for (final p in profiles) {
      if (p.id == activeId) {
        active = p;
        break;
      }
    }
    final config = await (widget.loader ??
        (() async => active?.config ?? AutoClickConfig.defaults()))();

    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeId = activeId;
      _config = config;
      _interval.text = '${config.intervalMs}';
      _randomDelay.text = '${config.randomDelayMs}';
      _repeat.text = '${config.repeat}';
      _loading = false;
    });
    await _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final results = await Future.wait(<Future<bool>>[
      _host.canDraw(),
      _host.accessibility(),
      _host.isRunning(),
    ]);
    if (!mounted) return;
    setState(() {
      _canDraw = results[0];
      _accessibility = results[1];
      _showing = results[2];
    });
  }

  /// 编辑当前配置。若注入了 saver（旧测试 / 单配置场景）用它落盘；
  /// 否则把配置写回激活方案，再持久化整个方案仓库。
  void _setConfig(AutoClickConfig config) {
    setState(() => _config = config);
    final saver = widget.saver;
    if (saver != null) {
      unawaited(saver(config));
    } else {
      unawaited(_saveActiveConfig(config));
    }
    // 面板已经挂在屏幕上时同步过去，取点新增的动作立刻参与循环。
    if (_showing) {
      unawaited(
          _host.updateConfig?.call(config.toJson()) ?? Future<void>.value());
    }
  }

  /// 把 [_config] 写回激活方案并落盘（多方案模式）。
  Future<void> _saveActiveConfig(AutoClickConfig config) async {
    if (_activeId.isEmpty) return;
    final next = <AutoClickProfile>[
      for (final p in _profiles)
        if (p.id == _activeId) p.copyWith(config: config).touched() else p,
    ];
    if (!mounted) return;
    setState(() => _profiles = next);
    await (widget.profilesSaver ?? AutoClickProfileStore.save)(next, _activeId);
  }

  /// 切换方案时，把当前编辑中的内容先存回旧方案，再加载新方案。
  Future<void> _switchProfile(String id) async {
    if (id == _activeId) return;
    await _saveActiveConfig(_config);
    final target = _profiles.firstWhere((p) => p.id == id);
    final cfg = target.config;
    if (!mounted) return;
    setState(() {
      _activeId = id;
      _config = cfg;
      _interval.text = '${cfg.intervalMs}';
      _randomDelay.text = '${cfg.randomDelayMs}';
      _repeat.text = '${cfg.repeat}';
    });
    await (widget.profilesSaver ?? AutoClickProfileStore.save)(_profiles, id);
    // 面板在屏时把新序列推给原生。
    if (_showing) {
      unawaited(_host.updateConfig?.call(cfg.toJson()) ?? Future<void>.value());
    }
    if (!mounted) return;
    showToast(context, trf('已切换到方案：{n}', {'n': target.name}));
  }

  /// 悬浮面板取点后回调：直接追加一个点击动作。
  void _onPickedPoint(double x, double y) {
    if (!mounted) return;
    final action = AutoClickAction(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: AutoClickActionType.tap,
      x: x,
      y: y,
      durationMs: 80,
    );
    _setConfig(
      _config.copyWith(actions: <AutoClickAction>[..._config.actions, action]),
    );
    showToast(
      context,
      trf('已添加点击动作（{x}%, {y}%）', {
        'x': x.toStringAsFixed(1),
        'y': y.toStringAsFixed(1),
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('自动点击')),
        actions: <Widget>[
          IconButton(
            key: const ValueKey('auto-click-import'),
            tooltip: tr('导入方案'),
            icon: const Icon(Icons.file_open_outlined, size: 20),
            onPressed: _importProfiles,
          ),
          IconButton(
            key: const ValueKey('auto-click-export'),
            tooltip: tr('导出方案'),
            icon: const Icon(Icons.ios_share, size: 20),
            onPressed: _exportProfiles,
          ),
          IconButton(
            key: const ValueKey('auto-click-refresh'),
            tooltip: tr('刷新权限状态'),
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _refreshStatus,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: <Widget>[
                _profileBar(context),
                const SizedBox(height: 10),
                _permissionRow(context),
                const SizedBox(height: 10),
                _actionCard(context),
                const SizedBox(height: 10),
                _timingCard(context),
                const SizedBox(height: 8),
                SmallHint(text: tr('面板可拖动；点「暂停」停下、点「×」关闭；手势只在本机执行')),
              ],
            ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: _showing
            ? OutlinedButton.icon(
                key: const ValueKey('auto-click-stop'),
                onPressed: _stop,
                icon: const Icon(Icons.stop_circle_outlined, size: 20),
                label: Text(tr('停止并关闭面板')),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
              )
            : FilledButton.icon(
                key: const ValueKey('auto-click-start'),
                onPressed: _start,
                icon: const Icon(Icons.play_arrow, size: 20),
                label: Text(tr('启动悬浮控制面板')),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
      ),
    );
  }

  /// 方案条：左侧下拉切换当前方案，右侧「另存 / 重命名 / 删除」。
  Widget _profileBar(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = _activeProfile;
    return SectionCard(
      title: tr('动作方案'),
      dense: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            key: const ValueKey('auto-click-profile-rename'),
            tooltip: tr('重命名'),
            icon: const Icon(Icons.drive_file_rename_outline, size: 18),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            padding: EdgeInsets.zero,
            onPressed: active == null ? null : _renameProfile,
          ),
          IconButton(
            key: const ValueKey('auto-click-profile-delete'),
            tooltip: tr('删除方案'),
            icon: const Icon(Icons.delete_outline, size: 18),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            padding: EdgeInsets.zero,
            onPressed: _profiles.length <= 1 ? null : _deleteProfile,
          ),
        ],
      ),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Material(
                color: scheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  key: const ValueKey('auto-click-profile-switch'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: _pickProfile,
                  child: SizedBox(
                    height: 38,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              active?.name ?? tr('选择方案'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5),
                            ),
                          ),
                          const Icon(Icons.expand_more, size: 18),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              key: const ValueKey('auto-click-profile-save-as'),
              onPressed: _saveAsProfile,
              icon: const Icon(Icons.add, size: 17),
              label: Text(tr('另存为')),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 38),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SmallHint(
          text: tr('可保存多套动作序列，随时切换；方案只存在本机，导出后可备份或换设备导入'),
        ),
      ],
    );
  }

  /// 两项权限压成一行胶囊：绿色是已就绪，红色可直接点开设置。
  Widget _permissionRow(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: _permissionChip(
            context,
            key: const ValueKey('auto-click-overlay-permission'),
            icon: Icons.layers_outlined,
            label: tr('悬浮窗'),
            granted: _canDraw,
            onRequest: () async {
              await _host.requestOverlay();
              await _refreshStatus();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _permissionChip(
            context,
            key: const ValueKey('auto-click-accessibility-permission'),
            icon: Icons.touch_app_outlined,
            label: tr('无障碍'),
            granted: _accessibility,
            onRequest: () async {
              await _host.openSettings();
              await _refreshStatus();
            },
          ),
        ),
      ],
    );
  }

  Widget _permissionChip(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String label,
    required bool granted,
    required Future<void> Function() onRequest,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = granted ? const Color(0xFF2E9E5B) : scheme.error;
    return Material(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(10),
        onTap: granted ? null : () => unawaited(onRequest()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: <Widget>[
              Icon(
                granted ? Icons.check_circle : Icons.error_outline,
                size: 15,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (!granted)
                Text(
                  tr('去开启'),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionCard(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: trf('动作序列（{n}）', {'n': _config.actions.length}),
      dense: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InfoHint(
            text: tr('启动面板后点「取点」，再点屏幕上要点的位置，就会自动加一个点击动作'),
          ),
          TextButton.icon(
            key: const ValueKey('auto-click-add'),
            onPressed: _pickType,
            icon: const Icon(Icons.add, size: 18),
            label: Text(tr('添加动作')),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
      children: <Widget>[
        if (_config.actions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              tr('还没有动作，点「添加动作」开始'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        for (var i = 0; i < _config.actions.length; i++)
          _actionTile(context, i, _config.actions[i]),
      ],
    );
  }

  Widget _actionTile(BuildContext context, int index, AutoClickAction action) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: ValueKey('auto-click-action-${action.id}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 18,
            child: Text(
              '${index + 1}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  tr(autoClickActionLabel(action.type)),
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  _describe(action),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('auto-click-edit-${action.id}'),
            icon: const Icon(Icons.edit_outlined, size: 17),
            tooltip: tr('编辑'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: () => _editAction(action, index),
          ),
          IconButton(
            key: ValueKey('auto-click-delete-${action.id}'),
            icon: const Icon(Icons.delete_outline, size: 17),
            tooltip: tr('删除'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: () => _setConfig(
              _config.copyWith(
                actions: <AutoClickAction>[
                  for (var i = 0; i < _config.actions.length; i++)
                    if (i != index) _config.actions[i],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _describe(AutoClickAction action) => switch (action.type) {
        AutoClickActionType.tap =>
          'X ${_pct(action.x)}% · Y ${_pct(action.y)}% · ${action.durationMs} ms',
        AutoClickActionType.swipe => '(${_pct(action.x)}%, ${_pct(action.y)}%) → '
            '(${_pct(action.x2)}%, ${_pct(action.y2)}%) · ${action.durationMs} ms',
        AutoClickActionType.back => tr('系统返回键'),
        AutoClickActionType.wait => trf('等待 {n} 毫秒', {'n': action.durationMs}),
      };

  String _pct(double value) => value.toStringAsFixed(0);

  Widget _timingCard(BuildContext context) {
    return SectionCard(
      title: tr('间隔与循环'),
      dense: true,
      children: <Widget>[
        // 三个短数字字段并排：都是「毫秒 / 次」，单行放得下，没必要各占一行。
        Row(
          children: <Widget>[
            Expanded(
              child: _tinyField(
                controller: _interval,
                label: tr('间隔'),
                suffix: 'ms',
                onChanged: (value) {
                  final n = int.tryParse(value.trim());
                  if (n != null) _setConfig(_config.copyWith(intervalMs: n));
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _tinyField(
                controller: _randomDelay,
                label: tr('随机'),
                suffix: 'ms',
                onChanged: (value) {
                  final n = int.tryParse(value.trim());
                  if (n != null) _setConfig(_config.copyWith(randomDelayMs: n));
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _tinyField(
                controller: _repeat,
                label: tr('循环'),
                suffix: tr('次'),
                onChanged: (value) {
                  final n = int.tryParse(value.trim());
                  if (n != null) _setConfig(_config.copyWith(repeat: n));
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SmallHint(text: tr('循环 0 为无限；每次动作后等待「间隔 + 0~随机」再执行下一步')),
      ],
    );
  }

  Widget _tinyField({
    required TextEditingController controller,
    required String label,
    required String suffix,
    required ValueChanged<String> onChanged,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: onChanged,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        labelStyle: const TextStyle(fontSize: 12.5),
        suffixStyle: const TextStyle(fontSize: 11),
      ),
    );
  }

  Future<void> _start() async {
    if (_config.actions.isEmpty) {
      showToast(context, tr('请先添加至少一个动作'));
      return;
    }
    if (!_canDraw) {
      await _host.requestOverlay();
      if (!mounted) return;
      await _refreshStatus();
      if (!mounted) return;
      if (!_canDraw) {
        showToast(context, tr('请先开启悬浮窗权限'));
        return;
      }
    }
    if (!_accessibility) {
      showToast(context, tr('请先在「设置 › 无障碍」开启 XMtools 自动点击'));
      return;
    }
    final ok = await _host.start(_config.toJson());
    if (!mounted) return;
    setState(() => _showing = ok);
    showToast(
      context,
      ok ? tr('已启动，切到目标应用后点面板「开始」') : tr('启动失败，请检查悬浮窗权限'),
    );
  }

  Future<void> _stop() async {
    await _host.stop();
    if (!mounted) return;
    setState(() => _showing = false);
    showToast(context, tr('已停止自动点击'));
  }

  // ------------------------------------------------------------------ 方案管理

  /// 点方案条弹出方案列表供切换。
  Future<void> _pickProfile() async {
    final id = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(tr('选择方案')),
        children: <Widget>[
          for (final p in _profiles)
            SimpleDialogOption(
              key: ValueKey('auto-click-profile-item-${p.id}'),
              onPressed: () => Navigator.of(dialogContext).pop(p.id),
              child: Row(
                children: <Widget>[
                  Icon(
                    p.id == _activeId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(p.name)),
                ],
              ),
            ),
        ],
      ),
    );
    if (id == null || !mounted) return;
    await _switchProfile(id);
  }

  /// 弹出输入框拿方案名，返回 null 表示取消。
  /// controller 由独立 State 持有，避免 await 返回后 dispose 时退出动画还没结束。
  Future<String?> _askName({
    required String title,
    String initial = '',
    String? confirmLabel,
  }) =>
      showDialog<String>(
        context: context,
        builder: (dialogContext) => _NameDialog(
          title: title,
          initial: initial,
          confirmLabel: confirmLabel ?? tr('保存'),
        ),
      );

  /// 另存为：用当前配置新建一套方案并切过去。
  Future<void> _saveAsProfile() async {
    final name = await _askName(
      title: tr('另存为新方案'),
      initial: trf('{n} 副本',
          {'n': _activeProfile?.name ?? AutoClickProfileStore.defaultName}),
      confirmLabel: tr('保存'),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final profile = AutoClickProfileStore.create(name, _config);
    final next = <AutoClickProfile>[profile, ..._profiles];
    setState(() {
      _profiles = next;
      _activeId = profile.id;
    });
    await (widget.profilesSaver ?? AutoClickProfileStore.save)(
        next, profile.id);
    if (!mounted) return;
    showToast(context, trf('已保存方案：{n}', {'n': name}));
  }

  Future<void> _renameProfile() async {
    final active = _activeProfile;
    if (active == null) return;
    final name = await _askName(
      title: tr('重命名方案'),
      initial: active.name,
      confirmLabel: tr('重命名'),
    );
    if (name == null || name.isEmpty || name == active.name || !mounted) return;
    final next = <AutoClickProfile>[
      for (final p in _profiles)
        if (p.id == active.id) p.copyWith(name: name).touched() else p,
    ];
    setState(() => _profiles = next);
    await (widget.profilesSaver ?? AutoClickProfileStore.save)(next, _activeId);
    if (!mounted) return;
    showToast(context, trf('已重命名为：{n}', {'n': name}));
  }

  Future<void> _deleteProfile() async {
    final active = _activeProfile;
    if (active == null || _profiles.length <= 1) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('删除方案')),
        content: Text(trf('确定删除「{n}」？此操作不可撤销。', {'n': active.name})),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            key: const ValueKey('auto-click-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final next = <AutoClickProfile>[
      for (final p in _profiles)
        if (p.id != active.id) p,
    ];
    final newActive = next.first.id;
    final cfg = next.first.config;
    setState(() {
      _profiles = next;
      _activeId = newActive;
      _config = cfg;
      _interval.text = '${cfg.intervalMs}';
      _randomDelay.text = '${cfg.randomDelayMs}';
      _repeat.text = '${cfg.repeat}';
    });
    await (widget.profilesSaver ?? AutoClickProfileStore.save)(next, newActive);
    if (!mounted) return;
    showToast(context, tr('方案已删除'));
  }

  /// 导出全部方案为 JSON 文件。
  Future<void> _exportProfiles() async {
    final json = AutoClickProfileStore.exportJson(_profiles, _activeId);
    final stamp = DateTime.now();
    final name = '自动点击方案-'
        '${stamp.year}${stamp.month.toString().padLeft(2, '0')}'
        '${stamp.day.toString().padLeft(2, '0')}-'
        '${stamp.hour.toString().padLeft(2, '0')}'
        '${stamp.minute.toString().padLeft(2, '0')}.json';
    try {
      final saver = widget.exporter;
      final saved = saver != null
          ? await saver(json, name)
          : await _exportViaPicker(json, name);
      if (saved != null && mounted) {
        showToast(context, trf('方案已导出：{p}', {'p': saved}));
      }
    } catch (e) {
      if (mounted) showToast(context, trf('导出失败：{e}', {'e': '$e'}));
    }
  }

  /// 默认导出：系统文件选择器；取消返回 null。
  static Future<String?> _exportViaPicker(String json, String name) async {
    final path = await FilePicker.platform.saveFile(
      fileName: name,
      type: FileType.custom,
      allowedExtensions: <String>['json'],
      bytes: utf8.encode(json),
    );
    return (path == null || path.isEmpty) ? null : path;
  }

  /// 导入方案 JSON（合并进现有列表，不改已有方案）。
  Future<void> _importProfiles() async {
    try {
      final text = await (widget.importer ?? _importViaPicker)();
      if (text == null || !mounted) return;
      final incoming = AutoClickProfileStore.parseJson(text);
      final before = _profiles.length;
      // 仓库的 import() 自带 id 重分配与去重；这里用当前列表作为基线，
      // 并让注入点接管落盘（测试场景不碰 SharedPreferences）。
      final merged = <AutoClickProfile>[..._profiles];
      final names = merged.map((p) => p.name).toSet();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < incoming.length; i++) {
        var name = incoming[i].name;
        var suffix = 1;
        while (names.contains(name)) {
          name = '${incoming[i].name}（导入${suffix > 1 ? suffix : ''}）';
          suffix++;
        }
        names.add(name);
        merged.add(
          incoming[i].copyWith(
            id: 'imp_${now}_${i}_${incoming[i].id.hashCode}',
            name: name,
            updatedAt: now + i,
          ),
        );
      }
      final added = merged.length - before;
      if (added <= 0) return;
      setState(() => _profiles = merged);
      await (widget.profilesSaver ?? AutoClickProfileStore.save)(
        merged,
        _activeId,
      );
      if (!mounted) return;
      showToast(context, trf('已导入 {n} 套方案', {'n': added}));
    } on FormatException catch (e) {
      if (mounted) showToast(context, trf('导入失败：{e}', {'e': e.message}));
    } catch (e) {
      if (mounted) showToast(context, trf('导入失败：{e}', {'e': '$e'}));
    }
  }

  /// 默认导入：系统文件选择器读取文本。
  static Future<String?> _importViaPicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['json'],
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return null;
    if (file.bytes != null) return utf8.decode(file.bytes!);
    if (file.path == null) return null;
    return File(file.path!).readAsString();
  }

  Future<void> _pickType() async {
    final type = await showDialog<AutoClickActionType>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr('选择动作类型')),
        children: <Widget>[
          for (final t in AutoClickActionType.values)
            SimpleDialogOption(
              key: ValueKey('auto-click-type-${t.id}'),
              onPressed: () => Navigator.of(context).pop(t),
              child: Text(tr(autoClickActionLabel(t))),
            ),
        ],
      ),
    );
    if (type == null || !mounted) return;
    await _editAction(
      AutoClickAction(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        type: type,
        durationMs: type == AutoClickActionType.wait ? 1000 : 100,
      ),
      null,
    );
  }

  Future<void> _editAction(AutoClickAction initial, int? index) async {
    final action = await showDialog<AutoClickAction>(
      context: context,
      builder: (_) => _ActionSheet(initial: initial),
    );
    if (action == null || !mounted) return;
    final next = <AutoClickAction>[..._config.actions];
    if (index == null) {
      next.add(action);
    } else {
      next[index] = action;
    }
    _setConfig(_config.copyWith(actions: next));
  }
}

/// 动作编辑弹窗：控制器由自己的 State 持有并释放。
class _ActionSheet extends StatefulWidget {
  const _ActionSheet({required this.initial});

  final AutoClickAction initial;

  @override
  State<_ActionSheet> createState() => _ActionSheetState();
}

class _ActionSheetState extends State<_ActionSheet> {
  late AutoClickActionType _type = widget.initial.type;
  late final TextEditingController _x =
      TextEditingController(text: _pct(widget.initial.x));
  late final TextEditingController _y =
      TextEditingController(text: _pct(widget.initial.y));
  late final TextEditingController _x2 =
      TextEditingController(text: _pct(widget.initial.x2));
  late final TextEditingController _y2 =
      TextEditingController(text: _pct(widget.initial.y2));
  late final TextEditingController _duration =
      TextEditingController(text: '${widget.initial.durationMs}');
  String? _error;

  @override
  void dispose() {
    _x.dispose();
    _y.dispose();
    _x2.dispose();
    _y2.dispose();
    _duration.dispose();
    super.dispose();
  }

  static String _pct(double value) => value.toStringAsFixed(1);

  double? _coord(TextEditingController controller, String name) {
    final value = double.tryParse(controller.text.trim());
    if (value == null || value < 0 || value > 100) {
      _error = trf('{name} 需为 0~100 之间的数字', {'name': name});
      return null;
    }
    return value;
  }

  void _submit() {
    _error = null;
    final duration = int.tryParse(_duration.text.trim());
    if (duration == null || duration < 10 || duration > 60000) {
      setState(() => _error = tr('时长需为 10~60000 毫秒'));
      return;
    }
    double x = widget.initial.x;
    double y = widget.initial.y;
    double x2 = widget.initial.x2;
    double y2 = widget.initial.y2;
    final needPoint =
        _type == AutoClickActionType.tap || _type == AutoClickActionType.swipe;
    if (needPoint) {
      final px = _coord(_x, 'X');
      final py = _coord(_y, 'Y');
      if (px == null || py == null) {
        setState(() {});
        return;
      }
      x = px;
      y = py;
    }
    if (_type == AutoClickActionType.swipe) {
      final px2 = _coord(_x2, 'X2');
      final py2 = _coord(_y2, 'Y2');
      if (px2 == null || py2 == null) {
        setState(() {});
        return;
      }
      x2 = px2;
      y2 = py2;
    }
    Navigator.of(context).pop(
      widget.initial.copyWith(
        type: _type,
        x: x,
        y: y,
        x2: x2,
        y2: y2,
        durationMs: duration,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final needPoint =
        _type == AutoClickActionType.tap || _type == AutoClickActionType.swipe;
    return AlertDialog(
      title: Text(tr('编辑动作')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wrap(
              spacing: 6,
              children: <Widget>[
                for (final t in AutoClickActionType.values)
                  ChoiceChip(
                    key: ValueKey('auto-click-sheet-type-${t.id}'),
                    label: Text(tr(autoClickActionLabel(t))),
                    selected: t == _type,
                    onSelected: (_) => setState(() => _type = t),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (needPoint) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: _field('auto-click-sheet-x', _x, tr('X（%）')),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _field('auto-click-sheet-y', _y, tr('Y（%）')),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (_type == AutoClickActionType.swipe) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: _field('auto-click-sheet-x2', _x2, tr('终点 X（%）')),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _field('auto-click-sheet-y2', _y2, tr('终点 Y（%）')),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            _field(
              'auto-click-sheet-duration',
              _duration,
              _type == AutoClickActionType.wait
                  ? tr('等待时长（毫秒）')
                  : tr('手势时长（毫秒）'),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('取消')),
        ),
        FilledButton(
          key: const ValueKey('auto-click-sheet-save'),
          onPressed: _submit,
          child: Text(tr('保存')),
        ),
      ],
    );
  }

  Widget _field(String key, TextEditingController controller, String label) =>
      TextField(
        key: ValueKey(key),
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, isDense: true),
      );
}

/// 方案名输入弹窗：controller 由自己的 State 持有并释放。
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.confirmLabel,
  });

  final String title;
  final String initial;
  final String confirmLabel;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          key: const ValueKey('auto-click-name-field'),
          controller: _controller,
          autofocus: true,
          maxLength: 40,
          decoration: InputDecoration(
            labelText: tr('方案名称'),
            isDense: true,
          ),
          onSubmitted: (_) => _submit(),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            key: const ValueKey('auto-click-name-confirm'),
            onPressed: _submit,
            child: Text(widget.confirmLabel),
          ),
        ],
      );
}
