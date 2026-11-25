import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'quiz_schema.dart';

/// 题库整库备份的导出 / 恢复。
///
/// 与 [QuizRepository] 分开的原因：日常查询只需要「读写某张表」，
/// 而整库快照还需要列白名单、版本校验与覆盖式事务——两者的改动理由不同，
/// 混在一起会让每次加字段都要同时动常规查询和备份兼容逻辑。
class QuizBackupRepository {
  QuizBackupRepository(this.db);

  final Database db;

  /// 导出整库（错题仅含 bankId、questionId）。
  Future<Map<String, dynamic>> export() async {
    final banks = await db.query('banks');
    final questions = await db.query('questions');
    final sessions = await db.query('sessions');
    final sessionQuestions = await db.query('session_questions');
    final wrong = await db.query('wrong_entries');
    final favorites = await db.query('favorites');
    final notes = await db.query('notes');
    final studyHistory = await db.query('study_history');
    final settingsRows = await db.query('settings');
    return <String, dynamic>{
      'schemaVersion': quizSchemaVersion,
      'app': 'XMtools/quiz',
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'banks': banks,
      'questions': questions,
      'sessions': sessions,
      'sessionQuestions': sessionQuestions,
      'wrongEntries': wrong,
      'favorites': favorites,
      'notes': notes,
      'studyHistory': studyHistory,
      'settings': <String, dynamic>{
        for (final row in settingsRows)
          row['key'] as String: row['value'] as String?,
      },
    };
  }

  /// 整库覆盖恢复：先校验结构与版本，再事务清空并按父表→子表插入。
  ///
  /// 任一步失败都会回滚，不会破坏原数据；旧备份中的错误次数 / 时间字段忽略。
  Future<void> restore(Map<String, dynamic> data) async {
    final banks = _rowsOf(data['banks']);
    final questions = _rowsOf(data['questions']);
    if (banks == null || questions == null) {
      throw const QuizBackupError('备份结构不完整：缺少 banks / questions');
    }
    final version = data['schemaVersion'] as int? ?? 0;
    if (version > quizSchemaVersion) {
      throw QuizBackupError('备份版本 $version 高于当前 $quizSchemaVersion');
    }
    final sessions =
        _rowsOf(data['sessions']) ?? const <Map<String, Object?>>[];
    final sessionQuestions =
        _rowsOf(data['sessionQuestions']) ?? const <Map<String, Object?>>[];
    final wrong =
        _rowsOf(data['wrongEntries']) ?? const <Map<String, Object?>>[];
    final favs = _rowsOf(data['favorites']) ?? const <Map<String, Object?>>[];
    final notes = _rowsOf(data['notes']) ?? const <Map<String, Object?>>[];
    final studyHistory =
        _rowsOf(data['studyHistory']) ?? const <Map<String, Object?>>[];
    final settings = data['settings'] as Map? ?? const <String, Object?>{};

    await db.transaction((txn) async {
      await txn.delete('session_questions');
      await txn.delete('sessions');
      await txn.delete('wrong_entries');
      await txn.delete('favorites');
      await txn.delete('notes');
      await txn.delete('study_history');
      await txn.delete('questions');
      await txn.delete('banks');
      await txn.delete('settings');

      for (final row in banks) {
        await txn.insert('banks', _only(row, _bankColumns));
      }
      for (final row in questions) {
        await txn.insert('questions', _only(row, _questionColumns));
      }
      for (final row in sessions) {
        await txn.insert('sessions', _only(row, _sessionColumns));
      }
      for (final row in sessionQuestions) {
        await txn.insert('session_questions', _only(row, _sqColumns));
      }
      for (final row in wrong) {
        await txn.insert('wrong_entries', _only(row, _wrongColumns));
      }
      for (final row in favs) {
        await txn.insert('favorites', _only(row, _favColumns));
      }
      // 旧备份没有 notes / studyHistory 字段时为空列表，整库覆盖后一并清空。
      for (final row in notes) {
        await txn.insert('notes', _only(row, _noteColumns));
      }
      for (final row in studyHistory) {
        await txn.insert('study_history', _only(row, _studyHistoryColumns));
      }
      for (final entry in settings.entries) {
        await txn.insert('settings', <String, Object?>{
          'key': entry.key.toString(),
          'value': entry.value?.toString() ?? '',
        });
      }
    });
  }

  static List<Map<String, Object?>>? _rowsOf(Object? raw) {
    if (raw is! List) return null;
    return raw.map((e) => Map<String, Object?>.from(e as Map)).toList();
  }

  static const List<String> _bankColumns = <String>[
    'id',
    'name',
    'importId',
    'description',
    'createdAt',
  ];
  static const List<String> _questionColumns = <String>[
    'id',
    'bankId',
    'importId',
    'type',
    'stem',
    'optionsJson',
    'answerJson',
    'analysis',
    'tagsJson',
    'difficulty',
    'score',
    'contentHash',
    'orderNo',
  ];
  static const List<String> _sessionColumns = <String>[
    'id',
    'bankId',
    'mode',
    'configJson',
    'status',
    'startedAt',
    'elapsedMs',
    'durationSec',
    'scoreEnabled',
    'totalScore',
    'maxScore',
    'finishedAt',
    'lastIndex',
    'activeAt',
  ];
  static const List<String> _sqColumns = <String>[
    'sessionId',
    'questionId',
    'orderNo',
    'userAnswerJson',
    'isCorrect',
    'selfJudged',
    'optionOrderJson',
    'answeredAt',
  ];
  static const List<String> _wrongColumns = <String>['bankId', 'questionId'];
  static const List<String> _favColumns = <String>['bankId', 'questionId'];
  static const List<String> _noteColumns = <String>[
    'id',
    'bankId',
    'content',
    'createdAt',
    'updatedAt',
  ];
  static const List<String> _studyHistoryColumns = <String>[
    'bankId',
    'questionId',
    'studiedAt',
  ];

  /// 只保留目标列（忽略旧备份里的错误次数、时间等字段）。
  static Map<String, Object?> _only(
      Map<String, Object?> row, List<String> columns) {
    final out = <String, Object?>{};
    for (final column in columns) {
      if (row.containsKey(column)) out[column] = row[column];
    }
    return out;
  }

  /// 备份 JSON 序列化（供导出到文件）。
  static String encode(Map<String, dynamic> data) =>
      const JsonEncoder.withIndent('  ').convert(data);
}

/// 备份 / 恢复失败。
class QuizBackupError implements Exception {
  const QuizBackupError(this.message);

  final String message;

  @override
  String toString() => message;
}
