import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';
import 'package:toolbox/features/tools/quiz/state/quiz_session_controller.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_study_page.dart';

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
  "bankName": "背题题库",
  "questions": [
    {"id": "q1", "type": "single", "stem": "1+1=?",
     "options": [{"key": "A", "text": "1"}, {"key": "B", "text": "2"}],
     "answer": ["B"], "analysis": "基础加法"},
    {"id": "q2", "type": "multiple", "stem": "选偶数",
     "options": [{"key": "A", "text": "2"}, {"key": "B", "text": "3"}],
     "answer": ["A"]},
    {"id": "q3", "type": "true_false", "stem": "地球是圆的",
     "options": [{"key": "true", "text": "正确"}, {"key": "false", "text": "错误"}],
     "answer": ["true"]},
    {"id": "q4", "type": "fill", "stem": "中国首都", "answer": ["北京"]},
    {"id": "q5", "type": "short", "stem": "简述相对论", "answer": ["时空弯曲"]}
  ]
}
''';

void main() {
  test('QuizConfig.studyMode 参与 copyWith 与 JSON 往返', () {
    const base = QuizConfig();
    expect(base.studyMode, isFalse);
    final study = base.copyWith(studyMode: true);
    expect(study.studyMode, isTrue);
    final restored = QuizConfig.fromJson(study.toJson());
    expect(restored.studyMode, isTrue);
    expect(restored.copyWith().studyMode, isTrue);
    expect(QuizConfig.fromJson(<String, dynamic>{'simpleMode': true}).studyMode,
        isFalse,
        reason: '旧存档没有该字段时默认关闭');
  });

  test('StudyData.pick 按范围与题型筛选，空题型集合视为全部', () {
    Question q(String id, QuestionType type) => Question(
          id: id,
          bankId: 'b1',
          type: type,
          stem: id,
          answer: const <String>['x'],
          contentHash: id,
        );
    final all = <Question>[
      q('a', QuestionType.single),
      q('b', QuestionType.fill),
      q('c', QuestionType.single),
    ];
    final data = StudyData(
      all: all,
      wrong: <Question>[all[1]],
      favorite: <Question>[all[0], all[2]],
      studied: <Question>[all[0]],
    );
    expect(data.studiedIds, <String>{'a'});
    expect(data.pick(StudyScope.all, const <QuestionType>{}), hasLength(3));
    expect(
      data.pick(StudyScope.wrong, const <QuestionType>{}).map((e) => e.id),
      <String>['b'],
      reason: '错题范围取错题列表',
    );
    expect(data.pick(StudyScope.favorite, const <QuestionType>{}).length, 2);
    expect(
      data.pick(StudyScope.byType, const <QuestionType>{}).length,
      3,
      reason: '不选具体题型时包含全部题型',
    );
    expect(
      data.pick(StudyScope.byType, <QuestionType>{QuestionType.single}).map(
          (e) => e.id),
      <String>['a', 'c'],
    );
    expect(
      data.pick(StudyScope.byType, <QuestionType>{QuestionType.short}),
      isEmpty,
    );
  });

  test('startStudy 建立纯内存会话：不写 session / 作答 / 错题，翻页不落库', () async {
    final repo = await openRepo();
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final questions = await repo.questionsOfBank(result.bankId, limit: 100000);
    final controller = QuizSessionController(repo);

    expect(await controller.startStudy(<Question>[]), isFalse);
    expect(await controller.startStudy(questions), isTrue);
    expect(controller.session!.config.studyMode, isTrue);
    expect(controller.session!.config.scoreEnabled, isFalse);
    expect(controller.session!.config.shuffleOptions, isFalse);
    expect(controller.questions, hasLength(5));
    expect(controller.current!.id, questions.first.id);
    // 收藏 / 错题标记照常读取，但会话本身不入库。
    expect(await repo.sessions(status: SessionStatus.active), isEmpty);
    expect(await repo.sessionQuestions(controller.session!.id), isEmpty);

    controller.next();
    expect(controller.index, 1);
    await controller.answer(questions[1].id, <String>['A']);
    expect(controller.stateOf(questions[1].id), AnswerState.unanswered,
        reason: '背题不接受作答');
    expect(await repo.wrongIds(), isEmpty);
    expect((await repo.db.query('session_questions')).isEmpty, isTrue);
    expect(await repo.sessions(status: SessionStatus.active), isEmpty);

    // 退出相关的写库入口全部是空操作，不会留下「继续上次」。
    await controller.saveProgress();
    await controller.finishPractice();
    expect(await controller.submit(), isNull);
    expect(await repo.sessions(status: SessionStatus.active), isEmpty);
    expect((await repo.db.query('sessions')).isEmpty, isTrue);
    controller.dispose();
  });

  test('loadStudyData 取全量题目（不受默认 50 条分页限制）', () async {
    final repo = await openRepo();
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final questions = await repo.questionsOfBank(result.bankId, limit: 100000);
    final wrong = questions.first;
    final favorite = questions[2];
    await repo.addWrong(result.bankId, wrong.id);
    await repo.addFavorite(result.bankId, favorite.id);
    final data = await loadStudyData(repo, result.bankId);
    expect(data.all, hasLength(5));
    expect(data.wrong.map((e) => e.id), <String>[wrong.id]);
    expect(data.favorite.map((e) => e.id), <String>[favorite.id]);
    expect(data.all.first.analysis, '基础加法');
  });
}
