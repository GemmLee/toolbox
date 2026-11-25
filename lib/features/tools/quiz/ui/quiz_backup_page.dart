import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/storage/app_files.dart';
import '../../../../core/storage/store_picker.dart';
import '../data/quiz_backup_repository.dart';
import '../data/quiz_repository.dart';
import '../../../../core/widgets/app_widgets.dart';

/// 备份恢复 + 模块设置。
class QuizBackupPage extends StatefulWidget {
  const QuizBackupPage({super.key, required this.repo});

  final QuizRepository repo;

  @override
  State<QuizBackupPage> createState() => _QuizBackupPageState();
}

class _QuizBackupPageState extends State<QuizBackupPage> {
  /// 整库快照与日常查询分开维护，见 [QuizBackupRepository]。
  QuizBackupRepository get _backup => QuizBackupRepository(widget.repo.db);

  String? _lastPath;
  bool _busy = false;
  final TextEditingController _score = TextEditingController();
  final TextEditingController _wrongThreshold =
      TextEditingController(text: '1');
  bool _shuffleOptions = true;
  bool _shuffleQuestions = true;
  bool _onlyUnseen = false;
  bool _lockAfterConfirm = false;
  bool _autoNextOnCorrect = false;
  bool _simpleMode = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final score = await widget.repo.getSetting('globalScore');
    final so = await widget.repo.getSetting('shuffleOptions');
    final sq = await widget.repo.getSetting('shuffleQuestions');
    final unseen = await widget.repo.getSetting('onlyUnseen');
    final lock = await widget.repo.getSetting('lockAfterConfirm');
    final autoNext = await widget.repo.getSetting('autoNextOnCorrect');
    final threshold = await widget.repo.getSetting('wrongRemoveThreshold');
    final simple = await widget.repo.getSetting('simpleMode');
    if (!mounted) return;
    setState(() {
      _score.text = score ?? '2';
      _shuffleOptions = so != 'false';
      _shuffleQuestions = sq != 'false';
      _onlyUnseen = unseen == 'true';
      _simpleMode = simple == 'true';
      _lockAfterConfirm = lock == 'true';
      _autoNextOnCorrect = autoNext == 'true';
      final n = int.tryParse(threshold ?? '');
      if (n != null) _wrongThreshold.text = '${n.clamp(1, 99)}';
    });
  }

  /// 导出备份到「存储空间 › 工具输出 › 刷题助手」。
  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final data = await _backup.export();
      final stamp = DateTime.now();
      final name = '刷题备份-${stamp.year}'
          '${stamp.month.toString().padLeft(2, '0')}'
          '${stamp.day.toString().padLeft(2, '0')}-'
          '${stamp.hour.toString().padLeft(2, '0')}'
          '${stamp.minute.toString().padLeft(2, '0')}.json';
      final file = await AppStore.saveText(
        category: AppStoreCategory.quiz,
        name: name,
        content: QuizBackupRepository.encode(data),
      );
      if (!mounted) return;
      setState(() => _lastPath = file.path);
      showToast(context, trf('备份已保存到存储空间：{n}', {'n': file.name}));
    } catch (e) {
      if (mounted) showToast(context, '${tr('导出失败')}：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(tr('选择备份文件'),
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
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
    String text;
    if (source == 'store') {
      final stored = await pickStoredFile(context,
          extensions: const <String>['json'], title: tr('选择备份文件'));
      if (stored == null || !mounted) return;
      try {
        text = await AppStore.readText(stored);
      } catch (e) {
        if (mounted) showToast(context, trf('文件读取失败：{e}', {'e': '$e'}));
        return;
      }
    } else {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['json'],
        withData: true,
      );
      final file = result?.files.single;
      if (file == null) return;
      try {
        text = file.bytes != null
            ? utf8.decode(file.bytes!)
            : await File.fromUri(Uri.file(file.path!)).readAsString();
      } catch (e) {
        if (mounted) showToast(context, trf('文件读取失败：{e}', {'e': '$e'}));
        return;
      }
    }
    if (!mounted) return;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      if (mounted) showToast(context, tr('备份文件不是合法 JSON'));
      return;
    }
    if (decoded is! Map) {
      if (mounted) showToast(context, tr('备份结构不完整'));
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('恢复备份')),
        content: Text(tr('恢复将覆盖当前所有数据，确认继续？')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('覆盖恢复')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await _backup.restore(Map<String, dynamic>.from(decoded));
      if (mounted) showToast(context, tr('恢复成功'));
      await _loadSettings();
    } on QuizBackupError catch (e) {
      if (mounted) showToast(context, '${tr('恢复失败')}：$e');
    } catch (e) {
      if (mounted) showToast(context, '${tr('恢复失败')}：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _score.dispose();
    _wrongThreshold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('备份恢复'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(tr('备份'), style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  SmallHint(
                    text: tr('备份会保存在「存储空间 › 存储文件 › 刷题助手」'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const ValueKey('backup-export'),
                    icon: const Icon(Icons.download_outlined),
                    label: Text(tr('导出备份')),
                    onPressed: _busy ? null : _export,
                  ),
                  if (_lastPath != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _lastPath!,
                            style: theme.textTheme.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy_all_outlined),
                          onPressed: () => copyWithToast(context, _lastPath!),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('backup-restore'),
                    icon: const Icon(Icons.upload_outlined),
                    label: Text(tr('恢复备份')),
                    onPressed: _busy ? null : _restore,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('默认设置'), style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      SizedBox(width: 90, child: Text(tr('全局分值'))),
                      Expanded(
                        child: NumberStepField(
                          controller: _score,
                          fieldKey: const ValueKey('setting-score'),
                          stepKeyPrefix: 'setting-score',
                          min: 1,
                          max: 10,
                          step: 0.5,
                          width: 124,
                          allowDecimal: true,
                          onChanged: (value) =>
                              widget.repo.setSetting('globalScore', value),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('选项乱序')),
                    value: _shuffleOptions,
                    onChanged: (v) async {
                      setState(() => _shuffleOptions = v);
                      await widget.repo
                          .setSetting('shuffleOptions', v ? 'true' : 'false');
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('题目乱序')),
                    value: _shuffleQuestions,
                    onChanged: (v) async {
                      setState(() => _shuffleQuestions = v);
                      await widget.repo
                          .setSetting('shuffleQuestions', v ? 'true' : 'false');
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('已做过的题不出现')),
                    value: _onlyUnseen,
                    onChanged: (v) async {
                      setState(() => _onlyUnseen = v);
                      await widget.repo
                          .setSetting('onlyUnseen', v ? 'true' : 'false');
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(tr('简易刷题')),
                        InfoHint(
                          key: const ValueKey('setting-simple-mode-hint'),
                          text: tr('单选和判断题选完即自动确认，不再显示确认按钮；'
                              '上一题 / 下一题按钮也会隐藏，左右滑动即可翻页'),
                        ),
                      ],
                    ),
                    value: _simpleMode,
                    onChanged: (v) async {
                      setState(() => _simpleMode = v);
                      await widget.repo
                          .setSetting('simpleMode', v ? 'true' : 'false');
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('确认后禁止修改')),
                    value: _lockAfterConfirm,
                    onChanged: (v) async {
                      setState(() => _lockAfterConfirm = v);
                      await widget.repo.setSetting(
                          'lockAfterConfirm', v ? 'true' : 'false');
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('答对切换下一题')),
                    value: _autoNextOnCorrect,
                    onChanged: (v) async {
                      setState(() => _autoNextOnCorrect = v);
                      await widget.repo.setSetting(
                          'autoNextOnCorrect', v ? 'true' : 'false');
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tr('答对错题移出错题本次数'),
                            maxLines: 2,
                          ),
                        ),
                        NumberStepField(
                          controller: _wrongThreshold,
                          fieldKey:
                              const ValueKey('setting-wrong-threshold'),
                          stepKeyPrefix: 'setting-wrong-threshold',
                          min: 1,
                          max: 99,
                          width: 104,
                          hint: '1',
                          onChanged: (value) => widget.repo
                              .setSetting('wrongRemoveThreshold', value),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
