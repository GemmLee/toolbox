import 'dart:convert';

import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';

/// 导入校验问题（题号从 1 开始）。
class ImportIssue {
  const ImportIssue({required this.no, required this.message});

  /// 题号（1 基）。
  final int no;
  final String message;

  @override
  String toString() => '第 $no 题：$message';
}

/// 导入预览：题数 / 分题型数 / 错误 / 重复提示。
class ImportPreview {
  const ImportPreview({
    required this.bankName,
    required this.version,
    required this.questions,
    required this.errors,
    required this.warnings,
    required this.typeCounts,
  });

  final String bankName;
  final int version;

  /// 通过校验、待写入的题目（bankId 在提交时填充）。
  final List<Question> questions;
  final List<ImportIssue> errors;
  final List<ImportIssue> warnings;
  final Map<QuestionType, int> typeCounts;

  bool get hasErrors => errors.isNotEmpty;
  bool get canImport => questions.isNotEmpty && !hasErrors;

  int get total => questions.length;
}

/// 导入结果。
class ImportResult {
  const ImportResult({required this.bankId, required this.count});

  final String bankId;
  final int count;
}

/// 导入失败（含题号，便于定位）。
class ImportError implements Exception {
  const ImportError(this.message, {this.no});

  final String message;
  final int? no;

  @override
  String toString() => no == null ? message : '第 $no 题：$message';
}

/// 题库导入：选文件 → 校验 → 预览 → 事务写入。
class QuizImporter {
  /// 解析并校验 JSON 文本。
  static ImportPreview parse(String text) {
    final errors = <ImportIssue>[];
    final warnings = <ImportIssue>[];
    final questions = <Question>[];
    final counts = <QuestionType, int>{};

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw ImportError('文件不是合法 JSON：$e');
    }
    if (decoded is! Map) {
      throw const ImportError('文件根节点应为 JSON 对象');
    }
    final root = Map<String, dynamic>.from(decoded);
    final version = root['version'] is num
        ? (root['version'] as num).toInt()
        : int.tryParse(root['version']?.toString() ?? '');
    if (version == null) {
      throw const ImportError('缺少 version 字段');
    }
    final bankName = (root['bankName'] ?? root['name'])?.toString().trim();
    if (bankName == null || bankName.isEmpty) {
      throw const ImportError('缺少 bankName 字段');
    }
    final rawQuestions = root['questions'];
    if (rawQuestions is! List) {
      throw const ImportError('questions 应为数组');
    }
    if (rawQuestions.isEmpty) {
      throw const ImportError('题库为空：questions 没有题目');
    }

    final seenImportIds = <String, int>{};
    final seenHashes = <String, int>{};

    for (var i = 0; i < rawQuestions.length; i++) {
      final no = i + 1;
      final raw = rawQuestions[i];
      if (raw is! Map) {
        errors.add(ImportIssue(no: no, message: '题目应为 JSON 对象'));
        continue;
      }
      final map = Map<String, dynamic>.from(raw);
      final type = QuestionTypeExt.fromKey(map['type']?.toString());
      if (type == null) {
        errors.add(ImportIssue(no: no, message: '题型不支持：${map['type']}'));
        continue;
      }
      final stem = map['stem']?.toString().trim() ?? '';
      if (stem.isEmpty) {
        errors.add(ImportIssue(no: no, message: '题干为空'));
        continue;
      }

      // 选项：判断题一律使用固定的「正确 / 错误」，忽略源 options。
      // AI 转换常把判分用的 T/F、true/false 拼进选项文本（如「true正确」），
      // 这些标识符不属于题面，直接丢弃即可；判分只依赖 key。
      final options = <OptionItem>[];
      final rawOptions = map['options'];
      if (type == QuestionType.trueFalse) {
        options.addAll(kJudgeOptions);
      } else if (type.hasOptions) {
        if (rawOptions is! List || rawOptions.isEmpty) {
          errors.add(ImportIssue(no: no, message: '${type.key} 题缺少 options'));
          continue;
        }
        for (final item in rawOptions) {
          final option = OptionItem.fromJson(item);
          if (option == null) {
            errors.add(ImportIssue(no: no, message: '选项格式错误：$item'));
            continue;
          }
          options.add(option);
        }
        if (options.length < 2) {
          errors.add(ImportIssue(no: no, message: '选项至少需要 2 个'));
          continue;
        }
      } else if (rawOptions is List) {
        for (final item in rawOptions) {
          final option = OptionItem.fromJson(item);
          if (option != null) options.add(option);
        }
      }

      // 答案：判断题把 T/F、√/×、对/错、正确/错误等标识符归一成 true/false。
      final answer = _answerList(map['answer'])
          .map((a) => type == QuestionType.trueFalse
              ? (normalizeJudgeAnswer(a) ?? a)
              : a)
          .toList();
      if (answer.isEmpty) {
        errors.add(ImportIssue(no: no, message: '答案为空'));
        continue;
      }
      if (type == QuestionType.single && answer.length > 1) {
        errors.add(ImportIssue(no: no, message: '单选答案只能有 1 个'));
        continue;
      }
      if (type.hasOptions) {
        final keys = options.map((o) => o.key).toSet();
        final missing = answer.where((a) => !keys.contains(a)).toList();
        if (missing.isNotEmpty) {
          errors.add(
              ImportIssue(no: no, message: '答案 key 不存在：${missing.join(',')}'));
          continue;
        }
      }
      if (type == QuestionType.trueFalse &&
          !answer.every((a) => a == 'true' || a == 'false')) {
        errors
            .add(ImportIssue(no: no, message: '判断题答案应为 ["true"] 或 ["false"]'));
        continue;
      }

      final importId = map['id']?.toString().trim();
      final tags = (map['tags'] is List)
          ? (map['tags'] as List).map((e) => e.toString()).toList()
          : <String>[];
      final difficulty = map['difficulty'] is num
          ? (map['difficulty'] as num).toInt()
          : int.tryParse(map['difficulty']?.toString() ?? '');
      final score = map['score'] is num
          ? (map['score'] as num).toDouble()
          : double.tryParse(map['score']?.toString() ?? '');
      final analysis = map['analysis']?.toString().trim();
      final hash = contentHashOf('${type.key}|$stem|'
          '${options.map((o) => '${o.key}:${o.text}').join('|')}|${answer.join('|')}');

      if (importId != null && importId.isNotEmpty) {
        final first = seenImportIds[importId];
        if (first != null) {
          warnings.add(
              ImportIssue(no: no, message: 'id "$importId" 与第 $first 题重复，已跳过'));
          continue;
        }
        seenImportIds[importId] = no;
      }
      if (seenHashes.containsKey(hash)) {
        warnings
            .add(ImportIssue(no: no, message: '内容与第 ${seenHashes[hash]} 题重复'));
      }
      seenHashes[hash] = no;

      questions.add(Question(
        id: newId(),
        bankId: '',
        importId: importId?.isEmpty ?? true ? null : importId,
        type: type,
        stem: stem,
        options: options,
        answer: answer,
        analysis: (analysis == null || analysis.isEmpty) ? null : analysis,
        tags: tags,
        difficulty: difficulty,
        score: score,
        contentHash: hash,
        orderNo: questions.length,
      ));
      counts[type] = (counts[type] ?? 0) + 1;
    }

    return ImportPreview(
      bankName: bankName,
      version: version,
      questions: questions,
      errors: errors,
      warnings: warnings,
      typeCounts: counts,
    );
  }

  /// 确认写入：新建题库 + 题目，事务失败回滚并抛出带题号的错误。
  static Future<ImportResult> commit(
      QuizRepository repo, ImportPreview preview) async {
    if (!preview.canImport) {
      throw const ImportError('存在校验错误，未写入');
    }
    try {
      return await repo.db.transaction((txn) async {
        final id = newId();
        await txn.insert('banks', <String, Object?>{
          'id': id,
          'name': preview.bankName,
          'description': null,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        });
        var order = 0;
        for (final q in preview.questions) {
          try {
            final row = q.copyWith(bankId: id).toRow();
            row['orderNo'] = order;
            await txn.insert('questions', row);
          } catch (e) {
            throw ImportError('写入失败：$e', no: order + 1);
          }
          order++;
        }
        return ImportResult(bankId: id, count: order);
      });
    } on ImportError {
      rethrow;
    } catch (e) {
      throw ImportError('导入失败，已回滚：$e');
    }
  }

  static List<String> _answerList(Object? raw) {
    if (raw == null) return const <String>[];
    if (raw is List) {
      return raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    final text = raw.toString().trim();
    return text.isEmpty ? const <String>[] : <String>[text];
  }
}
