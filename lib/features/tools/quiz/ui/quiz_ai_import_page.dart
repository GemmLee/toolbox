import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/ai_status_indicator.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/storage/store_picker.dart';
import '../../assistant/data/document_extractor.dart';
import '../data/quiz_repository.dart';
import '../logic/quiz_ai_convert.dart';
import '../logic/quiz_import.dart';
import '../state/quiz_conversion_controller.dart';
import 'quiz_common.dart';
import 'quiz_import_page.dart';

/// 刷题工具的「AI 导入」：拖入 / 选择文件 → 调用内置「题库转换」技能 →
/// 进度条 → 转换结果确认后直接导入题库。
///
/// 任务状态放在 [QuizConversionController] 单例里，页面只是订阅者：
/// 退出本页、切后台、息屏都不会中断转换，再次进入直接接着看进度或结果。
class QuizAiImportPage extends StatefulWidget {
  const QuizAiImportPage({
    super.key,
    required this.repo,
    this.converter,
    this.initialFile,
  });

  final QuizRepository repo;

  /// 测试可注入假的转换服务。
  final QuizAiConverter? converter;

  /// 测试专用：跳过文件选择，直接从这个文件开始转换。
  final ({String name, List<int> bytes})? initialFile;

  @override
  State<QuizAiImportPage> createState() => _QuizAiImportPageState();
}

class _QuizAiImportPageState extends State<QuizAiImportPage> {
  final QuizConversionController _controller =
      QuizConversionController.instance;

  late final QuizAiConverter _converter = widget.converter ?? QuizAiConverter();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    unawaited(_controller.loadPreference());
    final seed = widget.initialFile;
    if (seed != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startWithFile(seed.name, seed.bytes);
      });
    }
  }

  @override
  void dispose() {
    // 只解绑监听，绝不在 dispose 里取消任务。
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  // —— 文件选择 ——

  Future<void> _pickSource() async {
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
              subtitle: Text(tr('支持 Word / Excel / 文本 / 题库文件')),
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
    await _pickFile(fromStore: source == 'store');
  }

  Future<void> _pickFile({required bool fromStore}) async {
    String? name;
    List<int>? bytes;
    if (fromStore) {
      final stored = await pickStoredFile(
        context,
        title: tr('选择题库源文件'),
        extensions: DocumentExtractor.supportedExtensions,
      );
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
      final picked = result?.files.single;
      if (picked == null || !mounted) return;
      name = picked.name;
      try {
        bytes = picked.bytes ??
            await File.fromUri(Uri.file(picked.path!)).readAsBytes();
      } catch (e) {
        if (mounted) showToast(context, trf('文件读取失败：{e}', {'e': '$e'}));
        return;
      }
    }
    if (!mounted) return;
    await _startWithFile(name, bytes);
  }

  /// 解析文件正文并自动开始转换（选择文件 / 拖入 / 测试注入共用）。
  Future<void> _startWithFile(String name, List<int> bytes) async {
    String text;
    try {
      text = DocumentExtractor.extract(fileName: name, bytes: bytes).text;
    } catch (_) {
      if (mounted) showToast(context, tr('文件解析失败'));
      return;
    }
    _controller.reset();
    await _controller.start(
      text: text,
      fileName: name,
      converter: _converter,
    );
  }

  // —— 转换控制：全部委托给进程级单例 ——

  Future<void> _retry() => _controller.retry(converter: _converter);

  void _cancel() => _controller.cancel();

  void _reset() => _controller.reset();

  Future<void> _confirmImport() async {
    final result = _controller.result;
    if (result == null) return;
    ImportPreview preview;
    try {
      preview = QuizImporter.parse(result.rawJson);
    } on ImportError catch (e) {
      _controller.showImportError('${tr('导入失败')}：$e');
      return;
    }
    if (!mounted) return;
    final ok = await Navigator.of(context).push<bool>(
      quizRoute<bool>(
        builder: (_) => QuizImportPage(repo: widget.repo, preview: preview),
      ),
    );
    if (ok == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _controller.busy;
    final fileName = _controller.fileName;
    final result = _controller.result;
    final error = _controller.error;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('AI 导入题库')),
        actions: [
          if (fileName != null)
            IconButton(
              tooltip: tr('重新选择'),
              onPressed: busy ? null : _reset,
              icon: const Icon(Icons.restart_alt),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _DropZone(
            fileName: fileName,
            enabled: !busy,
            onTap: _pickSource,
            onDropped: (name, bytes) => _startWithFile(name, bytes),
          ),
          const SizedBox(height: 14),
          _backgroundCard(theme),
          const SizedBox(height: 14),
          if (busy) _progressCard(theme),
          if (result != null) _resultCard(theme, result),
          if (error != null) _errorCard(theme, error),
          if (!busy && fileName == null && result == null && error == null) ...[
            const SizedBox(height: 4),
            SmallHint(
              text: tr('选择文件后会自动调用内置「题库转换」技能转成题库 JSON，'
                  '转换完成即可确认导入。'),
              maxLines: 3,
            ),
          ],
        ],
      ),
    );
  }

  /// 息屏保活设置：默认关闭（CPU 仍保活，任务照跑），可按需常亮。
  Widget _backgroundCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const ValueKey('quiz-ai-keep-awake'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _controller.keepScreenOn,
              onChanged: (v) => unawaited(_controller.setKeepScreenOn(v)),
              title: Text(tr('转换时保持屏幕常亮'), style: theme.textTheme.bodyMedium),
            ),
            SmallHint(
              text: tr('关闭后息屏仍会继续转换，退出本页再回来可查看进度或结果。'),
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressCard(ThemeData theme) {
    final label = _controller.label;
    final fraction = _controller.fraction;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (fraction <= 0)
                  const AiThinkingDots(size: 5)
                else
                  const AiTypingCursor(height: 14),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label.isEmpty ? tr('转换中…') : label,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text('${(fraction * 100).clamp(0, 100).toStringAsFixed(0)}%',
                    style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                key: const ValueKey('quiz-ai-progress'),
                value: fraction <= 0 ? null : fraction,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: Text(tr('取消')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard(ThemeData theme, QuizConvertResult result) {
    return Card(
      key: const ValueKey('quiz-ai-result'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle_outline,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(tr('转换完成'),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 10),
            Text(result.bankName, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              trf('已转换 {n} 题', {'n': result.count}),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            if (result.warning != null) ...[
              const SizedBox(height: 8),
              Text(result.warning!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.orange)),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _retry,
                    child: Text(tr('重新转换')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('quiz-ai-confirm'),
                    onPressed: _confirmImport,
                    child: Text(tr('确定导入')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(ThemeData theme, String message) {
    return Card(
      color: theme.colorScheme.errorContainer.withOpacity(0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline,
                    size: 20, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Text(tr('转换失败'),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 8),
            Text(message, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: _reset, child: Text(tr('重新选择'))),
                const SizedBox(width: 8),
                FilledButton(onPressed: _retry, child: Text(tr('重新转换'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 拖入 / 点击选择的投放区。
///
/// 手机端以点击选择为主；桌面端也可以把文件拖到这块区域上（拖拽数据为
/// 文件路径字符串或 `List<int>` 字节 + 名称）。
class _DropZone extends StatelessWidget {
  const _DropZone({
    required this.fileName,
    required this.enabled,
    required this.onTap,
    required this.onDropped,
  });

  final String? fileName;
  final bool enabled;
  final VoidCallback onTap;
  final void Function(String name, List<int> bytes) onDropped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = fileName != null;
    return DragTarget<Object>(
      onAcceptWithDetails: (details) {
        final data = details.data;
        if (data is File) {
          onDropped(data.uri.pathSegments.last, data.readAsBytesSync());
        } else if (data is String && File(data).existsSync()) {
          onDropped(
              File(data).uri.pathSegments.last, File(data).readAsBytesSync());
        }
      },
      builder: (context, candidates, rejects) {
        final highlight = candidates.isNotEmpty;
        return InkWell(
          key: const ValueKey('quiz-ai-dropzone'),
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 26),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: highlight
                  ? theme.colorScheme.primaryContainer.withOpacity(0.5)
                  : theme.colorScheme.surfaceContainerHighest.withOpacity(0.35),
              border: Border.all(
                color: active || highlight
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
                width: active || highlight ? 1.4 : 1,
              ),
            ),
            child: Column(
              children: [
                Icon(
                  active ? Icons.description_outlined : Icons.upload_file,
                  size: 34,
                  color: active
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                const SizedBox(height: 10),
                Text(
                  active ? fileName! : tr('把文件拖到这里'),
                  style: theme.textTheme.titleSmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
