import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/storage/app_files.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/mini_segmented.dart';
import 'download_manager.dart';
import 'link_settings.dart';

/// 链接解析的设置页：保存位置、分片线程、并发、限速、重试与记录清理。
///
/// 对齐 YunX「下载设置」里真正影响结果的那几项；通知栏进度、后台保活这类需要
/// 常驻服务的项目前不做，所以页面上不放。
class LinkSettingsPage extends StatefulWidget {
  const LinkSettingsPage({
    super.key,
    this.manager,
    this.preferences,
    this.usageLoader,
  });

  /// 测试注入：用于清记录、读设置与统计占用。
  final DownloadManager? manager;
  final Future<LinkSettings> Function()? preferences;
  final Future<int> Function()? usageLoader;

  @override
  State<LinkSettingsPage> createState() => _LinkSettingsPageState();
}

class _LinkSettingsPageState extends State<LinkSettingsPage> {
  LinkSettings _settings = LinkSettingsStore.current.value;
  int _usedBytes = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final loaded = await (widget.preferences ?? LinkSettingsStore.load)();
    var used = 0;
    try {
      used = await (widget.usageLoader ??
          () => AppStore.usedBytes(AppStoreCategory.other))();
    } catch (_) {
      used = 0;
    }
    if (!mounted) return;
    setState(() {
      _settings = loaded;
      _usedBytes = used;
    });
  }

  Future<void> _update(LinkSettings next) async {
    setState(() => _settings = next);
    await LinkSettingsStore.save(next);
  }

  Future<void> _editPhoneDir() async {
    final controller = TextEditingController(text: _settings.phoneDir);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('下载子目录')),
        content: TextField(
          key: const ValueKey('link-settings-dir-input'),
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: LinkSettings.defaultPhoneDir,
            helperText: trf('实际位置：{p}', {
              'p': phoneRelativeDir(_settings.phoneDir),
            }),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(tr('保存')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    await _update(_settings.copyWith(phoneDir: value.trim()));
  }

  Future<void> _clearRecords() async {
    setState(() => _busy = true);
    try {
      await (widget.manager ?? DownloadManager.instance).clearAll();
      if (mounted) showToast(context, tr('已清空下载记录'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('链接解析设置'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        children: <Widget>[
          SectionCard(
            title: tr('保存位置'),
            dense: true,
            children: <Widget>[
              MiniSegmented<LinkSaveTarget>(
                height: 30,
                fontSize: 12,
                expanded: true,
                options: <MiniSegmentedOption<LinkSaveTarget>>[
                  MiniSegmentedOption<LinkSaveTarget>(
                    value: LinkSaveTarget.appStorage,
                    label: tr('应用存储空间'),
                  ),
                  MiniSegmentedOption<LinkSaveTarget>(
                    value: LinkSaveTarget.phone,
                    label: tr('手机下载目录'),
                  ),
                ],
                selected: _settings.saveTarget,
                onChanged: (value) =>
                    _update(_settings.copyWith(saveTarget: value)),
              ),
              const SizedBox(height: 8),
              if (_settings.toPhone) ...<Widget>[
                ListTile(
                  key: const ValueKey('link-settings-dir'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  title: Text(tr('下载子目录')),
                  subtitle: Text(
                    phoneRelativeDir(_settings.phoneDir),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.edit_outlined, size: 18),
                  onTap: _editPhoneDir,
                ),
                SmallHint(
                  maxLines: 3,
                  text: tr('下载中的文件仍先写到应用缓存，完成后才复制到手机目录；系统相册 / 文件管理里能直接看到。'),
                ),
              ] else ...<Widget>[
                SmallHint(
                  maxLines: 3,
                  text: trf(
                    '文件保存在应用存储空间（其他），可在「用户 → 存储空间」查看和导出。当前占用 {v}。',
                    {'v': formatBytes(_usedBytes)},
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          SectionCard(
            title: tr('下载'),
            dense: true,
            children: <Widget>[
              _row(
                theme,
                tr('分片线程'),
                MiniSegmented<int>(
                  height: 26,
                  fontSize: 11,
                  options: const <MiniSegmentedOption<int>>[
                    MiniSegmentedOption<int>(value: 1, label: '1'),
                    MiniSegmentedOption<int>(value: 4, label: '4'),
                    MiniSegmentedOption<int>(value: 8, label: '8'),
                  ],
                  selected: _settings.threads,
                  onChanged: (value) =>
                      _update(_settings.copyWith(threads: value)),
                ),
              ),
              const SizedBox(height: 8),
              _row(
                theme,
                tr('同时下载'),
                MiniSegmented<int>(
                  height: 26,
                  fontSize: 11,
                  options: const <MiniSegmentedOption<int>>[
                    MiniSegmentedOption<int>(value: 1, label: '1'),
                    MiniSegmentedOption<int>(value: 2, label: '2'),
                    MiniSegmentedOption<int>(value: 3, label: '3'),
                  ],
                  selected: _settings.concurrency,
                  onChanged: (value) =>
                      _update(_settings.copyWith(concurrency: value)),
                ),
              ),
              const SizedBox(height: 8),
              _row(
                theme,
                tr('限速'),
                MiniSegmented<int>(
                  height: 26,
                  fontSize: 11,
                  options: <MiniSegmentedOption<int>>[
                    MiniSegmentedOption<int>(value: 0, label: tr('不限')),
                    const MiniSegmentedOption<int>(
                      value: 1024 * 1024,
                      label: '1 MB/s',
                    ),
                    const MiniSegmentedOption<int>(
                      value: 5 * 1024 * 1024,
                      label: '5 MB/s',
                    ),
                  ],
                  selected: _settings.speedLimitBps,
                  onChanged: (value) =>
                      _update(_settings.copyWith(speedLimitBps: value)),
                ),
              ),
              const SizedBox(height: 8),
              _row(
                theme,
                tr('失败重试'),
                MiniSegmented<int>(
                  height: 26,
                  fontSize: 11,
                  options: <MiniSegmentedOption<int>>[
                    MiniSegmentedOption<int>(value: 0, label: tr('不重试')),
                    MiniSegmentedOption<int>(
                      value: 1,
                      label: trf('{n} 次', {'n': 1}),
                    ),
                    MiniSegmentedOption<int>(
                      value: 2,
                      label: trf('{n} 次', {'n': 2}),
                    ),
                  ],
                  selected: _settings.retries,
                  onChanged: (value) =>
                      _update(_settings.copyWith(retries: value)),
                ),
              ),
              const SizedBox(height: 6),
              SmallHint(
                maxLines: 3,
                text: tr('服务端不支持分片时会自动退回单线程；暂停后继续会从已下载的位置续传。'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SectionCard(
            title: tr('记录与缓存'),
            dense: true,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      tr('清除下载记录'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('link-settings-clear'),
                    onPressed: _busy ? null : _clearRecords,
                    child: Text(tr('清除')),
                  ),
                ],
              ),
              SmallHint(
                maxLines: 3,
                text: tr('只删除记录和没下完的临时文件，已经保存好的成品文件保留。'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(ThemeData theme, String label, Widget control) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 68,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: control)),
      ],
    );
  }
}
