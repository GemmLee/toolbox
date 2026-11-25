import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:toolbox/features/tools/quiz/data/quiz_backup_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';
import 'package:toolbox/features/tools/quiz/state/quiz_session_controller.dart';

const String kBank = '''
{
  "version": 1,
  "bankName": "背诵测试",
  "questions": [
    {"id": "q1", "type": "single", "stem": "1+1=?",
     "options": [{"key": "A", "text": "1"}, {"key": "B", "text": "2"}],
     "answer": ["B"], "analysis": "基础"},
    {"id": "q2", "type": "single", "stem": "2+2=?",
     "options": [{"key": "A", "text": "2"}, {"key": "B", "text": "4"}],
     "answer": ["B"], "analysis": "进阶"}
  ]
}
''';

Future<QuizRepository> openRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false));
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

void main() {
  test('schema v5：背题记录表存在，旧库升级补齐且不影响旧数据', () async {
    expect(quizSchemaVersion, 5);
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await migrateQuiz(db, 0, 4);
    final tablesV4 = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='study_history'");
    expect(tablesV4, isEmpty);
    await db
        .execute("INSERT INTO banks (id,name,createdAt) VALUES ('b0','旧题库',0)");
    await migrateQuiz(db, 4, 5);
    final rows = await db.query('study_history');
    expect(rows, isEmpty);
    expect((await db.query('banks')).single['name'], '旧题库');
    await db.close();
  });

  test('背题记录：累计去重、按题库隔离、时间倒序', () async {
    final repo = await openRepo();
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final questions = await repo.questionsOfBank(result.bankId, limit: 100000);
    expect(questions, hasLength(2));

    await repo.markStudied(result.bankId, questions[0].id, at: 1000);
    await repo.markStudied(result.bankId, questions[1].id, at: 2000);
    await repo.markStudied(result.bankId, questions[0].id,
        at: 3000); // 重复背诵，刷新时间

    expect(await repo.studiedIds(result.bankId),
        <String>{questions[0].id, questions[1].id});
    final list = await repo.studiedQuestions(result.bankId);
    expect(list, hasLength(2));
    expect(list.first.id, questions[0].id, reason: '最后一次背的（含重复背诵那位）排前面');
    expect(await repo.countStudied(result.bankId), 2);
    expect(await repo.studiedIds('other-bank'), isEmpty);

    await repo.clearStudyHistory(result.bankId);
    expect(await repo.studiedIds(result.bankId), isEmpty);
  });

  test('背题会话：翻题记录到背题表，但不写 session / 作答 / 错题', () async {
    final repo = await openRepo();
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final questions = await repo.questionsOfBank(result.bankId, limit: 100000);
    final recorded = <String>[];
    final controller = QuizSessionController(
      repo,
      onStudy: (bankId, questionId) async {
        await repo.markStudied(bankId, questionId);
        recorded.add(questionId);
      },
    );
    expect(await controller.startStudy(questions), isTrue);
    // 第 1 题在进入时记录
    expect(recorded, <String>[questions.first.id]);
    controller.next();
    // goTo 内的记录是异步的（unawaited），轮询等待写入完成。
    for (var i = 0; i < 20 && recorded.length < questions.length; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(recorded, questions.map((q) => q.id).toList());
    expect(await repo.studiedIds(result.bankId),
        questions.map((q) => q.id).toSet());
    // 不污染练习数据
    expect(await repo.sessions(status: SessionStatus.active), isEmpty);
    expect((await repo.db.query('session_questions')).isEmpty, isTrue);
    expect(await repo.wrongIds(), isEmpty);
    controller.dispose();
  });

  test('备份：整库导出含背题记录，恢复后还原', () async {
    final repo = await openRepo();
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final questions = await repo.questionsOfBank(result.bankId, limit: 100000);
    await repo.markStudied(result.bankId, questions.first.id);

    final backup = await QuizBackupRepository(repo.db).export();
    expect(backup['studyHistory'], isNotEmpty);

    await repo.clearStudyHistory(result.bankId);
    expect(await repo.studiedIds(result.bankId), isEmpty);

    await QuizBackupRepository(repo.db).restore(backup);
    expect(await repo.studiedIds(result.bankId), <String>{questions.first.id});
  });

  test('删题库级联清理背题记录', () async {
    final repo = await openRepo();
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final questions = await repo.questionsOfBank(result.bankId, limit: 100000);
    await repo.markStudied(result.bankId, questions.first.id);
    await repo.deleteBank(result.bankId);
    expect(await repo.studiedIds(result.bankId), isEmpty);
  });
}
