import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../data/quiz_repository.dart';
import '../logic/quiz_import.dart';
import 'quiz_common.dart';

/// 导入预览：题数 / 分题型数 / 错误 / 重复提示，确认后事务写入。
class QuizImportPage extends StatefulWidget {
  const QuizImportPage({super.key, required this.repo, required this.preview});

  final QuizRepository repo;
  final ImportPreview preview;

  @override
  State<QuizImportPage> createState() => _QuizImportPageState();
}

class _QuizImportPageState extends State<QuizImportPage> {
  bool _busy = false;

  Future<void> _commit() async {
    setState(() => _busy = true);
    try {
      final result = await QuizImporter.commit(widget.repo, widget.preview);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(trf('导入成功：{n} 题', {'n': result.count})),
        ),
      );
    } on ImportError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('导入失败')}：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = widget.preview;
    return Scaffold(
      appBar: AppBar(title: Text(tr('导入预览'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(preview.bankName, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            trf('版本 {v} · 共 {n} 题', {'v': preview.version, 'n': preview.total}),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: preview.typeCounts.entries
                .map((e) => Chip(
                    label: Text('${typeLabel(e.key)} ${e.value}')))
                .toList(),
          ),
          if (preview.errors.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              trf('错误 {n} 条', {'n': preview.errors.length}),
              style: theme.textTheme.titleSmall?.copyWith(color: Colors.red),
            ),
            const SizedBox(height: 6),
            ...preview.errors.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('${trf('第 {n} 题', {'n': e.no})}：${e.message}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.red)),
              ),
            ),
          ],
          if (preview.warnings.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              trf('重复提示 {n} 条', {'n': preview.warnings.length}),
              style: theme.textTheme.titleSmall?.copyWith(color: Colors.orange),
            ),
            const SizedBox(height: 6),
            ...preview.warnings.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${trf('第 {n} 题', {'n': e.no})}：${e.message}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(tr('取消')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('import-confirm'),
                  onPressed: preview.canImport && !_busy ? _commit : null,
                  child: Text(_busy ? tr('导入中') : tr('确认导入')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
