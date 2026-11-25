import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../../../../core/storage/app_files.dart';
import '../../quiz/logic/quiz_import.dart';
import '../../quiz/ui/quiz_common.dart';
import '../../../../core/settings/tool_texts.dart';

/// 从助手回复中提取题库 JSON（找不到返回 null）。
class QuizBankExtract {
  const QuizBankExtract({required this.raw, required this.bankName, required this.count});

  final String raw;
  final String bankName;
  final int count;

  /// 建议的文件名（去掉文件名中不允许的字符）。
  String get fileName =>
      '${bankName.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')}.json';

  /// 文件大小（UTF-8 字节数）。
  int get byteSize => utf8.encode(raw).length;

  String get sizeLabel {
    final kb = byteSize / 1024;
    return kb < 1 ? '$byteSize B' : '${kb.toStringAsFixed(1)} KB';
  }
}

/// 提取规则：优先 ```json 代码块，其次首尾大括号之间的内容。
QuizBankExtract? extractQuizBankJson(String text) {
  for (final match
      in RegExp(r'```(?:json)?\s*(\{.*?\})\s*```', dotAll: true).allMatches(text)) {
    final result = _tryParse(match.group(1)!);
    if (result != null) return result;
  }
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) {
    final result = _tryParse(text.substring(start, end + 1));
    if (result != null) return result;
  }
  return null;
}

/// 文本看起来是（但还无法解析的）JSON 对象：用于提示「输出被截断」。
///
/// 题库 JSON 一般以 `{` 开头、以 `}` 结尾；长度达到上限时模型会在半句停下。
bool looksLikeIncompleteJson(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith('{')) return false;
  return !trimmed.endsWith('}');
}

QuizBankExtract? _tryParse(String candidate) {
  Object? decoded;
  try {
    decoded = jsonDecode(candidate);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final questions = decoded['questions'];
  if (questions is! List || questions.isEmpty) return null;
  final name = (decoded['bankName'] ?? decoded['name'] ?? '').toString().trim();
  return QuizBankExtract(
    raw: const JsonEncoder.withIndent('  ').convert(decoded),
    bankName: name.isEmpty ? tr('未命名题库') : name,
    count: questions.length,
  );
}

/// 保存题库 JSON 到「存储空间 › 工具输出 › AI 助手」；返回是否已保存。
///
/// 顺带给一条「导出到手机」的动作，需要外部文件时不必再进存储空间。
Future<bool> saveQuizJson(BuildContext context, QuizBankExtract extract) async {
  StoredFile stored;
  try {
    stored = await AppStore.saveText(
      category: AppStoreCategory.assistant,
      name: extract.fileName,
      content: extract.raw,
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('保存失败')}：$e')),
      );
    }
    return false;
  }
  if (!context.mounted) return true;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(
    content: Text(trf('已保存到存储空间：{n}', {'n': stored.name})),
    action: SnackBarAction(
      label: tr('导出到手机'),
      onPressed: () async {
        await FilePicker.platform.saveFile(
          fileName: stored.name,
          bytes: utf8.encode(extract.raw),
        );
      },
    ),
  ));
  return true;
}

/// 校验并导入题库；结果通过 SnackBar / 对话框反馈。
Future<void> importQuizJson(BuildContext context, QuizBankExtract extract) async {
  final preview = QuizImporter.parse(extract.raw);
  if (!preview.canImport) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('无法导入')),
        content: SingleChildScrollView(
          child: Text(preview.errors.map((e) => e.toString()).join('\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
        ],
      ),
    );
    return;
  }
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('导入题库')),
      content: Text(trf(
        '将创建题库「{name}」，共 {n} 题，是否继续？',
        {'name': preview.bankName, 'n': preview.total},
      )),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr('导入')),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final repo = await QuizServices.repo();
    final result = await QuizImporter.commit(repo, preview);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(trf('已导入「{name}」共 {n} 题',
            {'name': preview.bankName, 'n': result.count})),
      ));
    }
  } on ImportError catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${tr('导入失败')}：$e')));
    }
  }
}
