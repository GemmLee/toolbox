import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/storage/store_picker.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/quiz_repository.dart';
import '../logic/quiz_excel_import.dart';
import '../logic/quiz_import.dart';
import 'quiz_common.dart';
import 'quiz_import_page.dart';

/// Excel 导入：选 xlsx → 本地转换 → 结果卡 → 复用导入预览页入库。
///
/// 正常入口由导入菜单选好文件后传入 [initialFile]；页面单独打开时若未传入，
/// 则自行弹文件选择。
class QuizExcelImportPage extends StatefulWidget {
  const QuizExcelImportPage({
    super.key,
    required this.repo,
    this.initialFile,
  });

  final QuizRepository repo;
  final ({String name, List<int> bytes})? initialFile;

  @override
  State<QuizExcelImportPage> createState() => _QuizExcelImportPageState();
}

class _QuizExcelImportPageState extends State<QuizExcelImportPage> {
  ExcelImportResult? _result;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialFile;
    if (initial != null) {
      _convert(initial.name, initial.bytes);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickSource());
    }
  }

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
              subtitle: Text(tr('支持 .xlsx 表格文件')),
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
        title: tr('选择 Excel 文件'),
        extensions: const <String>['xlsx'],
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
        allowedExtensions: const <String>['xlsx'],
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
    _convert(name, bytes);
  }

  void _convert(String name, List<int> bytes) {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final result = QuizExcelImporter.parse(bytes, fileName: name);
      if (!mounted) return;
      setState(() {
        _result = result;
        _busy = false;
      });
    } on ExcelImportException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = trf('转换失败：{e}', {'e': '$e'});
        _busy = false;
      });
    }
  }

  Future<void> _viewAndImport() async {
    final result = _result;
    if (result == null) return;
    ImportPreview preview;
    try {
      preview = QuizImporter.parse(result.json);
    } on ImportError catch (e) {
      if (mounted) showToast(context, '${tr('导入失败')}：$e');
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
    return Scaffold(
      appBar: AppBar(title: Text(tr('Excel 导入'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_busy)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              _errorCard(theme, _error!)
            else if (_result != null)
              _resultCard(theme, _result!)
            else
              Center(
                child: FilledButton.icon(
                  onPressed: _pickSource,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: Text(tr('选择 Excel 文件')),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard(ThemeData theme, ExcelImportResult r) {
    return Card(
      key: const ValueKey('quiz-excel-result'),
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
            Text(r.bankName, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${trf('成功 {n} 题', {'n': r.imported})} · '
              '${trf('去重 {n} 题', {'n': r.duplicates})} · '
              '${trf('跳过 {n} 行', {'n': r.skipped})}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            if (r.typeCounts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: r.typeCounts.entries
                    .map((e) =>
                        Chip(label: Text('${typeLabel(e.key)} ${e.value}')))
                    .toList(),
              ),
            ],
            if (r.issues.isNotEmpty) ...[
              const SizedBox(height: 10),
              ...r.issues.map(
                (s) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(s,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.orange)),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _pickSource,
                    child: Text(tr('重新选择')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('quiz-excel-confirm'),
                    onPressed: r.imported > 0 ? _viewAndImport : null,
                    child: Text(tr('查看并导入')),
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
            const SizedBox(height: 10),
            Text(message, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _pickSource,
                child: Text(tr('重新选择')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
