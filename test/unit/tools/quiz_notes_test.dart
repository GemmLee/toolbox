import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_backup_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';

Future<QuizRepository> openRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

const String kBank = '''
{
  "version": 1,
  "bankName": "演示题库",
  "questions": [
    {"id": "q1", "type": "single", "stem": "1 + 1 等于多少？",
     "options": [{"key": "A", "text": "1"}, {"key": "B", "text": "2"}],
     "answer": ["B"]},
    {"id": "q2", "type": "trueFalse", "stem": "地球是圆的。",
     "answer": ["true"]}
  ]
}
''';

QuizNote note(String id, String bankId, String content, int updatedAt) =>
    QuizNote(
      id: id,
      bankId: bankId,
      content: content,
      createdAt: updatedAt - 1000,
      updatedAt: updatedAt,
    );

void main() {
  test('v1 旧库升级到最新版：补上 notes 表与 activeAt 且不丢原有会话', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await migrateQuiz(db, 0, 1);
    await db.insert('sessions', <String, Object?>{
      'id': 'old-session',
      'mode': QuizMode.all.key,
      'configJson': '{}',
      'status': SessionStatus.active.key,
      'startedAt': 1,
    });
    await migrateQuiz(db, 1, quizSchemaVersion);

    final repo = QuizRepository(db);
    expect(quizSchemaVersion, 5);
    expect((await repo.sessionById('old-session'))!.lastIndex, 0);
    // v4 迁移后旧会话补上 activeAt（退回创建时间）
    expect((await repo.sessionById('old-session'))!.activeAt, 1);
    // v3 迁移后 notes 表可用
    expect(await repo.listNotes('old-session'), isEmpty);
  });

  test('笔记逐条增删改查，且按题库隔离', () async {
    final repo = await openRepo();
    final now = DateTime.now().millisecondsSinceEpoch;
    await repo.insertNote(note('n1', 'bank-a', '笔记 A1', now));
    await repo.insertNote(note('n2', 'bank-a', '笔记 A2', now + 1));
    await repo.insertNote(note('n3', 'bank-b', '笔记 B', now));

    expect(
      (await repo.listNotes('bank-a')).map((e) => e.id).toList(),
      <String>['n2', 'n1'],
      reason: '最近修改的排在前面',
    );
    expect(await repo.countNotes('bank-b'), 1);

    await repo.updateNote(note('n1', 'bank-a', '改过的 A1', now + 10));
    final items = await repo.listNotes('bank-a');
    expect(items.first.content, '改过的 A1');

    await repo.deleteNote('n1');
    expect(await repo.countNotes('bank-a'), 1);
    expect(await repo.countNotes('bank-b'), 1, reason: '删 A 不影响 B');
  });

  test('删除题库级联删除该题库的笔记', () async {
    final repo = await openRepo();
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final now = DateTime.now().millisecondsSinceEpoch;
    await repo.insertNote(note('n1', result.bankId, '随手记', now));
    await repo.insertNote(note('n2', 'other-bank', '别库的笔记', now));
    expect(await repo.countNotes(result.bankId), 1);

    await repo.deleteBank(result.bankId);
    expect(await repo.countNotes(result.bankId), 0);
    expect(await repo.countNotes('other-bank'), 1);
  });

  test('stats.seenCount 按题目去重，空白作答不算刷过', () async {
    final repo = await openRepo();
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final questions = await repo.questionsOfBank(result.bankId);
    final q1 = questions.first.id;
    final q2 = questions.last.id;

    // 历史作答次数按会话归属统计，先登记三条会话。
    for (final id in <String>['s1', 's2', 's3']) {
      await repo.db.insert('sessions', <String, Object?>{
        'id': id,
        'bankId': result.bankId,
        'mode': QuizMode.all.key,
        'configJson': '{}',
        'status': SessionStatus.submitted.key,
        'startedAt': 1,
      });
    }

    Future<void> answered(String session, String question) => repo.db.insert(
          'session_questions',
          <String, Object?>{
            'sessionId': session,
            'questionId': question,
            'orderNo': 0,
            'userAnswerJson': '["B"]',
            'isCorrect': 1,
            'selfJudged': 0,
          },
        );

    await answered('s1', q1);
    await answered('s2', q1); // 同一题刷两次仍只算一题
    await repo.db.insert('session_questions', <String, Object?>{
      'sessionId': 's3',
      'questionId': q2,
      'orderNo': 1,
      'userAnswerJson': null,
      'isCorrect': null,
      'selfJudged': 0,
    });

    final stats = await repo.stats(bankId: result.bankId);
    expect(stats.questionCount, 2);
    expect(stats.seenCount, 1);
    expect(stats.unseenCount, 1);
    expect(stats.seenPercent, closeTo(50, 0.001));
    expect(stats.answeredCount, 2, reason: '作答次数仍按次累计');
  });

  test('整库备份包含笔记，恢复后按快照还原', () async {
    final repo = await openRepo();
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final now = DateTime.now().millisecondsSinceEpoch;
    await repo.insertNote(note('n1', result.bankId, '备份里的笔记', now));

    final backup = QuizBackupRepository(repo.db);
    final snapshot = await backup.export();
    expect((snapshot['notes'] as List).length, 1);

    await repo.insertNote(note('n2', result.bankId, '恢复后应消失', now + 1));
    expect(await repo.countNotes(result.bankId), 2);

    await backup.restore(snapshot);
    final notes = await repo.listNotes(result.bankId);
    expect(notes.length, 1);
    expect(notes.single.content, '备份里的笔记');
  });
}
