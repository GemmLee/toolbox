import 'dart:convert';

import '../data/quiz_models.dart';

/// 把单个题库序列化成可再次导入的题库 JSON。
///
/// 输出格式与 `题库 JSON 规范` 一致：根节点 `version` / `bankName` /
/// `questions`，题目字段只保留题面相关内容（内部主键、内容指纹、排序号
/// 属于本地存储细节，导出时丢掉，重新导入时会重新生成）。
class QuizExporter {
  QuizExporter._();

  /// 题库 JSON 版本号，与导入校验接受的 version 保持一致。
  static const int version = 1;

  static Map<String, dynamic> bankToMap(Bank bank, List<Question> questions) {
    return <String, dynamic>{
      'version': version,
      'bankName': bank.name,
      if (bank.description != null && bank.description!.isNotEmpty)
        'description': bank.description,
      'questions': <Map<String, dynamic>>[
        for (var i = 0; i < questions.length; i++)
          _questionToMap(questions[i], i),
      ],
    };
  }

  static String encode(Bank bank, List<Question> questions) =>
      const JsonEncoder.withIndent('  ').convert(bankToMap(bank, questions));

  /// 导出文件名：题库名 + 时间戳，去掉路径非法字符。
  static String fileNameOf(Bank bank, DateTime now) {
    final safe = bank.name
        .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')
        .trim()
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    return '题库-${safe.isEmpty ? '未命名' : safe}-$stamp.json';
  }

  static Map<String, dynamic> _questionToMap(Question q, int index) {
    final importId = q.importId;
    return <String, dynamic>{
      'id': (importId == null || importId.isEmpty)
          ? 'q${index + 1}'
          : importId,
      'type': q.type.key,
      'stem': q.stem,
      // 判断题不写 options：App 固定用「正确 / 错误」两个选项。
      if (q.type != QuestionType.trueFalse && q.options.isNotEmpty)
        'options': <Map<String, dynamic>>[
          for (final o in q.options) o.toJson(),
        ],
      'answer': q.answer,
      if (q.analysis != null && q.analysis!.isNotEmpty) 'analysis': q.analysis,
      if (q.tags.isNotEmpty) 'tags': q.tags,
      if (q.difficulty != null) 'difficulty': q.difficulty,
      if (q.score != null) 'score': q.score,
    };
  }
}
