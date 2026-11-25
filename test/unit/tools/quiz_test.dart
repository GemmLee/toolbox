import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_backup_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_judge.dart';
import 'package:toolbox/features/tools/quiz/state/quiz_session_controller.dart';

/// 打开一个内存库（测试用）。
Future<QuizRepository> openRepo() async {
  sqfliteFfiInit();
  // singleInstance: false —— 每个测试拿到独立的内存库
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

const String kSampleBank = '''
{
  "version": 1,
  "bankName": "示例题库",
  "questions": [
    {"id": "q1", "type": "single", "stem": "1+1=?",
     "options": [{"key": "A", "text": "1"}, {"key": "B", "text": "2"}],
     "answer": ["B"], "analysis": "基础加法"},
    {"id": "q2", "type": "multiple", "stem": "选质数",
     "options": [{"key": "A", "text": "2"}, {"key": "B", "text": "4"}, {"key": "C", "text": "3"}],
     "answer": ["A", "C"]},
    {"id": "q3", "type": "true_false", "stem": "地球是圆的",
     "options": [{"key": "true", "text": "正确"}, {"key": "false", "text": "错误"}],
     "answer": ["true"]},
    {"id": "q4", "type": "fill", "stem": "中国首都", "answer": ["北京", "Beijing"]},
    {"id": "q5", "type": "short", "stem": "简述相对论", "answer": ["时空弯曲"]}
  ]
}
''';

Future<Question> importSample(QuizRepository repo) async {
  final preview = QuizImporter.parse(kSampleBank);
  final result = await QuizImporter.commit(repo, preview);
  final questions = await repo.questionsOfBank(result.bankId);
  return questions.first;
}

void main() {
  group('编辑题目持久化', () {
    test('withContent 重算指纹，保留 id / 题型 / 排序', () {
      const q = Question(
        id: 'q1',
        bankId: 'b1',
        type: QuestionType.single,
        stem: '旧题干',
        options: <OptionItem>[OptionItem(key: 'A', text: '1')],
        answer: <String>['A'],
        contentHash: 'old',
        orderNo: 7,
      );
      final edited = q.withContent(
        stem: '新题干',
        options: const <OptionItem>[OptionItem(key: 'A', text: '2')],
        answer: const <String>['A'],
        analysis: '新解析',
      );
      expect(edited.id, q.id);
      expect(edited.bankId, q.bankId);
      expect(edited.type, q.type);
      expect(edited.orderNo, 7);
      expect(edited.contentHash, isNot(q.contentHash));
      expect(
        edited.contentHash,
        contentHashOf('single|新题干|A:2|A'),
      );
    });

    test('updateQuestion 覆盖题干 / 选项 / 答案 / 解析且能读回', () async {
      final repo = await openRepo();
      final bankId = await repo.createBank(name: '编辑测试');
      const q = Question(
        id: 'e1',
        bankId: 'placeholder',
        type: QuestionType.single,
        stem: '旧题干',
        options: <OptionItem>[
          OptionItem(key: 'A', text: '1'),
          OptionItem(key: 'B', text: '2'),
        ],
        answer: <String>['A'],
        analysis: '旧解析',
      );
      await repo.insertQuestions(<Question>[q.copyWith(bankId: bankId)]);
      final stored = await repo.questionById('e1');
      expect(stored, isNotNull);
      final updated = stored!.withContent(
        stem: '新题干',
        options: const <OptionItem>[
          OptionItem(key: 'A', text: '10'),
          OptionItem(key: 'B', text: '20'),
        ],
        answer: const <String>['B'],
        analysis: '新解析',
      );
      await repo.updateQuestion(updated);
      final reread = await repo.questionById('e1');
      expect(reread!.stem, '新题干');
      expect(reread.options.last.text, '20');
      expect(reread.answer, <String>['B']);
      expect(reread.analysis, '新解析');
      expect(reread.contentHash, updated.contentHash);
      // 编辑不改变题目数量与归属。
      expect((await repo.questionsOfBank(bankId)).length, 1);
    });

    test('saveAnalysis 只写解析，保留题干 / 选项 / 答案 / 指纹', () async {
      final repo = await openRepo();
      final bankId = await repo.createBank(name: 'AI 解析写入');
      final q = Question(
        id: 'ai1',
        bankId: 'placeholder',
        type: QuestionType.single,
        stem: '水的沸点',
        options: const <OptionItem>[
          OptionItem(key: 'A', text: '90℃'),
          OptionItem(key: 'B', text: '100℃'),
        ],
        answer: <String>['B'],
        contentHash: contentHashOf('single|水的沸点|A:90℃|B:100℃|B'),
        orderNo: 3,
      );
      await repo.insertQuestions(<Question>[q.copyWith(bankId: bankId)]);

      final updated = await repo.saveAnalysis(
        (await repo.questionById('ai1'))!,
        '  标准大气压下是 100℃。  ',
      );
      final reread = (await repo.questionById('ai1'))!;
      expect(reread.analysis, '标准大气压下是 100℃。');
      expect(reread.stem, q.stem);
      expect(
        reread.options.map((o) => '${o.key}:${o.text}').toList(),
        q.options.map((o) => '${o.key}:${o.text}').toList(),
      );
      expect(reread.answer, q.answer);
      expect(reread.contentHash, q.contentHash);
      expect(reread.orderNo, 3);
      expect(updated.analysis, reread.analysis);
    });
  });

  group('判分规则', () {
    Question q(QuestionType type, List<String> answer,
            {List<OptionItem> options = const <OptionItem>[]}) =>
        Question(
          id: 'x',
          bankId: 'b',
          type: type,
          stem: 's',
          answer: answer,
          options: options,
        );

    test('单选：答案集合相等', () {
      final question = q(QuestionType.single, <String>['B']);
      expect(evaluateAnswer(question, <String>['B']), AnswerState.correct);
      expect(evaluateAnswer(question, <String>['A']), AnswerState.wrong);
      expect(evaluateAnswer(question, null), AnswerState.unanswered);
    });

    test('多选：必须全对，不做部分分', () {
      final question = q(QuestionType.multiple, <String>['A', 'C']);
      expect(evaluateAnswer(question, <String>['A', 'C']), AnswerState.correct);
      expect(evaluateAnswer(question, <String>['C', 'A']), AnswerState.correct);
      expect(evaluateAnswer(question, <String>['A']), AnswerState.wrong);
      expect(
          evaluateAnswer(question, <String>['A', 'B', 'C']), AnswerState.wrong);
    });

    test('判断：true / false', () {
      final question = q(QuestionType.trueFalse, <String>['true']);
      expect(evaluateAnswer(question, <String>['true']), AnswerState.correct);
      expect(evaluateAnswer(question, <String>['false']), AnswerState.wrong);
    });

    test('填空：去空格并忽略大小写，命中任一可接受答案即对', () {
      final question = q(QuestionType.fill, <String>['北京', 'Beijing']);
      expect(evaluateAnswer(question, <String>['北京']), AnswerState.correct);
      expect(evaluateAnswer(question, <String>[' 北 京 ']), AnswerState.correct);
      expect(
          evaluateAnswer(question, <String>['beijing']), AnswerState.correct);
      expect(evaluateAnswer(question, <String>['上海']), AnswerState.wrong);
    });

    test('简答：未自评为待判，自评后按用户选择', () {
      final question = q(QuestionType.short, <String>['参考']);
      expect(evaluateAnswer(question, <String>['我的答案']), AnswerState.pending);
      expect(evaluateAnswer(question, <String>['我的答案'], shortJudged: true),
          AnswerState.wrong);
      expect(
          evaluateAnswer(question, <String>['我的答案'],
              shortJudged: true, shortCorrect: true),
          AnswerState.correct);
    });
  });

  group('计分', () {
    test('分值优先级：单题 > 题型 > 全局', () {
      const config = QuizConfig(
        scoreEnabled: true,
        globalScore: 1,
        typeScores: <QuestionType, double>{QuestionType.single: 3},
      );
      Question q(double? score) => Question(
            id: 'x',
            bankId: 'b',
            type: QuestionType.single,
            stem: 's',
            score: score,
          );
      expect(scoreFor(q(5), config), 5);
      expect(scoreFor(q(null), config), 3);
      const noTypeScore = QuizConfig(scoreEnabled: true, globalScore: 1);
      expect(scoreFor(q(null), noTypeScore), 1);
    });

    test('对错模式不计分', () {
      const question = Question(
          id: 'x', bankId: 'b', type: QuestionType.single, stem: 's', score: 5);
      expect(scoreFor(question, const QuizConfig()), 0);
    });
  });

  group('导入', () {
    test('正常导入：题数、分题型统计、importId 落库', () async {
      final repo = await openRepo();
      final preview = QuizImporter.parse(kSampleBank);
      expect(preview.hasErrors, isFalse);
      expect(preview.total, 5);
      expect(preview.typeCounts[QuestionType.single], 1);
      expect(preview.typeCounts[QuestionType.multiple], 1);
      final result = await QuizImporter.commit(repo, preview);
      final rows = await repo.questionsOfBank(result.bankId);
      expect(rows.length, 5);
      expect(rows.first.importId, 'q1');
      expect(rows.first.hasAnalysis, isTrue);
    });

    test('逐题校验：缺 options、答案 key 不存在、题型不支持都报错并带题号', () async {
      const broken = '''
      {"version": 1, "bankName": "坏题库", "questions": [
        {"type": "single", "stem": "缺选项", "answer": ["A"]},
        {"type": "single", "stem": "答案不存在",
         "options": [{"key": "A", "text": "1"}], "answer": ["Z"]},
        {"type": "quiz", "stem": "题型不支持", "answer": ["A"]},
        {"type": "fill", "stem": "", "answer": ["x"]}
      ]}''';
      final preview = QuizImporter.parse(broken);
      expect(preview.canImport, isFalse);
      expect(preview.errors.map((e) => e.no).toList(), <int>[1, 2, 3, 4]);
      final repo = await openRepo();
      expect(
        () => QuizImporter.commit(repo, preview),
        throwsA(isA<ImportError>()),
      );
      expect(await repo.listBanks(), isEmpty, reason: '失败不应写入题库');
    });

    test('判断题可省略 options：自动补 true/false 两个选项', () {
      const text = '''
      {"version": 1, "bankName": "判断题", "questions": [
        {"type": "true_false", "stem": "1+1=2", "answer": ["true"]},
        {"type": "true_false", "stem": "地球是方的", "answer": ["false"]},
        {"type": "true_false", "stem": "空 options", "options": [], "answer": ["true"]}
      ]}''';
      final preview = QuizImporter.parse(text);
      expect(preview.errors, isEmpty);
      expect(preview.total, 3);
      for (final q in preview.questions) {
        expect(q.options.map((o) => o.key).toList(), <String>['true', 'false']);
      }
    });

    test('判断题忽略源 options 里的 t/f 标识符，界面只显示正确/错误', () {
      const text = '''
      {"version": 1, "bankName": "脏数据", "questions": [
        {"type": "true_false", "stem": "1+1=2",
         "options": [{"key": "true", "text": "true正确"},
                     {"key": "false", "text": "false错误"}],
         "answer": ["T"]},
        {"type": "true_false", "stem": "地球是方的",
         "options": [{"key": "A", "text": "T. 正确"},
                     {"key": "B", "text": "F. 错误"}],
         "answer": ["×"]},
        {"type": "single", "stem": "1+1=?",
         "options": [{"key": "A", "text": "1"}, {"key": "B", "text": "2"}],
         "answer": ["B"]}
      ]}''';
      final preview = QuizImporter.parse(text);
      expect(preview.errors, isEmpty);
      expect(preview.total, 3);
      expect(preview.questions[0].answer, <String>['true']);
      expect(preview.questions[1].answer, <String>['false']);

      for (final q in preview.questions.take(2)) {
        expect(q.options.map((o) => o.key).toList(), <String>['true', 'false']);
        expect(q.options.map((o) => o.text).toList(), <String>['正确', '错误']);
        for (final o in q.options) {
          final label = optionLabelOf(q, o);
          expect(label, isNot(contains('true')));
          expect(label, isNot(contains('false')));
          expect(label, isNot(contains('T')));
          expect(label, isNot(contains('F')));
        }
        expect(answerLabelOf(q), isNot(contains('true')));
        expect(answerLabelOf(q), isNot(contains('false')));
      }
      // 单选题仍保留 A./B. 标号。
      expect(
        optionLabelOf(preview.questions[2], preview.questions[2].options.first),
        'A. 1',
      );
    });

    test('normalizeJudgeAnswer 归一常见对错标记', () {
      expect(normalizeJudgeAnswer(' T '), 'true');
      expect(normalizeJudgeAnswer('√'), 'true');
      expect(normalizeJudgeAnswer('正确'), 'true');
      expect(normalizeJudgeAnswer('FALSE'), 'false');
      expect(normalizeJudgeAnswer('×'), 'false');
      expect(normalizeJudgeAnswer('错误'), 'false');
      expect(normalizeJudgeAnswer('不知道'), isNull);
    });

    test('文件级校验：非 JSON / 缺字段 / 空题库', () {
      expect(() => QuizImporter.parse('not json'), throwsA(isA<ImportError>()));
      expect(() => QuizImporter.parse('{"bankName":"x"}'),
          throwsA(isA<ImportError>()));
      expect(() => QuizImporter.parse('{"version":1,"bankName":"x"}'),
          throwsA(isA<ImportError>()));
      expect(
          () =>
              QuizImporter.parse('{"version":1,"bankName":"x","questions":[]}'),
          throwsA(isA<ImportError>()));
    });

    test('重复 importId 与重复内容给出提示，重复 id 只保留首次', () async {
      const dup = '''
      {"version": 1, "bankName": "重复题库", "questions": [
        {"id": "a", "type": "fill", "stem": "同一题", "answer": ["x"]},
        {"id": "a", "type": "fill", "stem": "同一题", "answer": ["x"]}
      ]}''';
      final preview = QuizImporter.parse(dup);
      expect(preview.warnings, isNotEmpty);
      expect(preview.total, 1, reason: '重复 id 的题目被跳过');
    });

    test('重导入默认新建题库，不合并', () async {
      final repo = await openRepo();
      await QuizImporter.commit(repo, QuizImporter.parse(kSampleBank));
      await QuizImporter.commit(repo, QuizImporter.parse(kSampleBank));
      expect((await repo.listBanks()).length, 2);
    });
  });

  group('错题与收藏', () {
    test('唯一约束：重复答错只保留一条；同一题可同时是错题和收藏', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      await repo.addWrong(first.bankId, first.id);
      await repo.addWrong(first.bankId, first.id);
      await repo.addFavorite(first.bankId, first.id);
      await repo.addFavorite(first.bankId, first.id);
      expect((await repo.wrongQuestions()).length, 1);
      expect((await repo.favoriteQuestions()).length, 1);
      expect(await repo.isWrong(first.bankId, first.id), isTrue);
      expect(await repo.isFavorite(first.bankId, first.id), isTrue);
    });

    test('错题表不保存次数与时间字段', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      await repo.addWrong(first.bankId, first.id);
      final columns =
          await repo.db.rawQuery('PRAGMA table_info(wrong_entries)');
      final names = columns.map((r) => r['name'] as String).toList();
      expect(names, <String>['bankId', 'questionId']);
    });

    test('错题与收藏按题库隔离，题库卡片带各自计数', () async {
      final repo = await openRepo();
      final a = await importSample(repo);
      final b = await QuizImporter.commit(
        repo,
        QuizImporter.parse(kSampleBank.replaceAll('示例题库', '第二个题库')),
      );

      await repo.addWrong(a.bankId, a.id);
      await repo.addFavorite(a.bankId, a.id);

      expect((await repo.wrongQuestions(bankId: a.bankId)).length, 1);
      expect((await repo.wrongQuestions(bankId: b.bankId)), isEmpty);
      expect((await repo.favoriteQuestions(bankId: b.bankId)), isEmpty);

      final banks = <String, Bank>{
        for (final bank in await repo.listBanks()) bank.id: bank,
      };
      expect(banks[a.bankId]!.wrongCount, 1);
      expect(banks[a.bankId]!.favoriteCount, 1);
      expect(banks[b.bankId]!.wrongCount, 0);
      expect(banks[b.bankId]!.favoriteCount, 0);

      // 会话也按题库归属
      await repo.insertSession(QuizSession(
        id: 'sa',
        bankId: a.bankId,
        mode: QuizMode.exam,
        status: SessionStatus.submitted,
        startedAt: 1,
      ));
      expect((await repo.sessionsOfBank(a.bankId)).length, 1);
      expect(await repo.sessionsOfBank(b.bankId), isEmpty);
    });

    test('重命名题库只改名字', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      await repo.renameBank(first.bankId, '新的名字');
      final bank = await repo.bankById(first.bankId);
      expect(bank?.name, '新的名字');
      expect(bank?.questionCount, 5);
    });

    test('删除题库级联删除错题、收藏与会话', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      await repo.addWrong(first.bankId, first.id);
      await repo.addFavorite(first.bankId, first.id);
      await repo.insertSession(QuizSession(
        id: 's1',
        bankId: first.bankId,
        mode: QuizMode.all,
        status: SessionStatus.active,
        startedAt: 0,
      ));
      await repo.insertSessionQuestions(<SessionQuestion>[
        SessionQuestion(sessionId: 's1', questionId: first.id, orderNo: 0),
      ]);
      final bank = (await repo.listBanks()).first;
      await repo.deleteBank(bank.id);
      expect(await repo.wrongQuestions(), isEmpty);
      expect(await repo.favoriteQuestions(), isEmpty);
      expect(await repo.sessionQuestions('s1'), isEmpty);
      expect(await repo.questionsByIds(<String>[first.id]), isEmpty);
    });
  });

  group('会话流程', () {
    test('练习：答错写入错题；错题练习答对移出；其他模式答对不移出', () async {
      final repo = await openRepo();
      final first = await importSample(repo); // 单选，答案 B

      // 1) 全部模式答错 → 进错题
      final all = QuizSessionController(repo);
      await all.start(
          bankId: first.bankId, mode: QuizMode.all, config: const QuizConfig());
      await all.answer(first.id, <String>['A']);
      expect(await repo.isWrong(first.bankId, first.id), isTrue);

      // 2) 全部模式答对 → 仍在错题本
      await all.answer(first.id, <String>['B']);
      expect(await repo.isWrong(first.bankId, first.id), isTrue);
      all.dispose();

      // 3) 错题练习答对 → 移出
      final drill = QuizSessionController(repo);
      await drill.start(
          bankId: first.bankId,
          mode: QuizMode.wrong,
          config: const QuizConfig());
      expect(drill.questions.length, 1);
      await drill.answer(first.id, <String>['B']);
      expect(await repo.isWrong(first.bankId, first.id), isFalse);
      drill.dispose();
    });

    test('简答自评：一次调用写入答案与判定，错题不重复', () async {
      final repo = await openRepo();
      const bank = '''
      {"version": 1, "bankName": "简答题库", "questions": [
        {"id": "s1", "type": "short", "stem": "说明原理", "answer": ["要点一"]}
      ]}''';
      final result = await QuizImporter.commit(repo, QuizImporter.parse(bank));
      final q = (await repo.questionsOfBank(result.bankId)).single;

      final c = QuizSessionController(repo);
      await c.start(
          bankId: result.bankId,
          mode: QuizMode.all,
          config: const QuizConfig());

      // 旧实现会先 answer() 再 selfJudge()，同一题写两次库并跑两遍错题规则。
      await c.judgeShortAnswer(q.id, <String>['我的回答'], true);
      expect(c.stateOf(q.id), AnswerState.correct);
      expect(await repo.isWrong(result.bankId, q.id), isFalse,
          reason: '自评答对不进错题本');
      expect(c.answerOf(q.id), <String>['我的回答'], reason: '答案应与自评一起落库');

      // 改判答错 → 写入错题，重复调用只保留一条
      await c.judgeShortAnswer(q.id, null, false);
      expect(c.stateOf(q.id), AnswerState.wrong);
      await c.judgeShortAnswer(q.id, null, false);
      expect((await repo.wrongQuestions()).length, 1);
      c.dispose();
    });

    test('多选题必须全对才移出错题', () async {
      final repo = await openRepo();
      final preview = QuizImporter.parse(kSampleBank);
      final result = await QuizImporter.commit(repo, preview);
      final questions = await repo.questionsOfBank(result.bankId);
      final multi =
          questions.firstWhere((q) => q.type == QuestionType.multiple);
      await repo.addWrong(multi.bankId, multi.id);
      final drill = QuizSessionController(repo);
      await drill.start(
          bankId: multi.bankId,
          mode: QuizMode.wrong,
          config: const QuizConfig());
      // 只选 A（不全对）→ 已答错（因为练习模式立即判分），再答全对才移出
      await drill.answer(multi.id, <String>['A']);
      expect(await repo.isWrong(multi.bankId, multi.id), isTrue);
      await drill.answer(multi.id, <String>['A', 'C']);
      expect(await repo.isWrong(multi.bankId, multi.id), isFalse);
      drill.dispose();
    });

    test('考试：交卷后统一判分，未答计 0 分且不写错题；答对不移出错题', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      await repo.addWrong(first.bankId, first.id);
      final exam = QuizSessionController(repo);
      await exam.start(
        bankId: first.bankId,
        mode: QuizMode.exam,
        config: const QuizConfig(
          scoreEnabled: true,
          globalScore: 2,
          typeCounts: <QuestionType, int>{QuestionType.single: 1},
        ),
      );
      final stats = await exam.submit();
      expect(stats, isNotNull);
      expect(stats!.correct, 0, reason: '未答不计正确');
      expect(stats.totalScore, 0, reason: '未答计 0 分');
      expect(await repo.isWrong(first.bankId, first.id), isTrue,
          reason: '未答不写错题但原本就在错题本');
      expect(await repo.sessionById(exam.session!.id), isNotNull);
      expect(exam.session!.status, SessionStatus.submitted);
      exam.dispose();
    });

    test('简答：考试中未自评按未答处理，自评后计入分数', () async {
      final repo = await openRepo();
      final preview = QuizImporter.parse(kSampleBank);
      final result = await QuizImporter.commit(repo, preview);
      final questions = await repo.questionsOfBank(result.bankId);
      final short = questions.firstWhere((q) => q.type == QuestionType.short);
      final exam = QuizSessionController(repo);
      await exam.start(
        bankId: short.bankId,
        mode: QuizMode.exam,
        config: const QuizConfig(
          scoreEnabled: true,
          globalScore: 5,
          typeCounts: <QuestionType, int>{QuestionType.short: 1},
        ),
      );
      await exam.answer(short.id, <String>['我的答案']);
      final before = await exam.submit();
      expect(before!.pending, 1);
      expect(before.totalScore, 0);
      await exam.selfJudge(short.id, true);
      await exam.refreshScore();
      expect(exam.stats().totalScore, 5, reason: '自评答对得满分');
      exam.dispose();
    });

    test('断点续答：恢复题目、作答与用时', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      final c = QuizSessionController(repo);
      await c.start(
          bankId: first.bankId, mode: QuizMode.all, config: const QuizConfig());
      await c.answer(first.id, <String>['A']);
      await c.saveProgress();
      final id = c.session!.id;
      c.dispose();

      final resumed = QuizSessionController(repo);
      final ok = await resumed.resume(id);
      expect(ok, isTrue);
      expect(resumed.questions.length, 5);
      expect(resumed.answerOf(first.id), <String>['A']);
      expect(resumed.stateOf(first.id), AnswerState.wrong);
      resumed.dispose();
    });

    test('断点续答：回到上次刷到的题号', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      final c = QuizSessionController(repo);
      await c.start(
          bankId: first.bankId, mode: QuizMode.all, config: const QuizConfig());
      c.goTo(3);
      await c.saveProgress();
      final id = c.session!.id;
      expect((await repo.sessionById(id))!.lastIndex, 3);
      c.dispose();

      final resumed = QuizSessionController(repo);
      expect(await resumed.resume(id), isTrue);
      expect(resumed.index, 3);
      resumed.dispose();

      // 题号越界（旧数据 / 题库变动）时退回第 1 题
      await repo.updateSessionIndex(id, 99);
      final fallback = QuizSessionController(repo);
      expect(await fallback.resume(id), isTrue);
      expect(fallback.index, 0);
      fallback.dispose();
    });

    test('考试恢复时若已超时直接自动交卷', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      final c = QuizSessionController(repo);
      await c.start(
        bankId: first.bankId,
        mode: QuizMode.exam,
        config: const QuizConfig(durationSec: 60),
      );
      await c.saveProgress();
      final session = (await repo.sessionById(c.session!.id))!;
      await repo.updateSession(session.copyWith(elapsedMs: 120000));
      c.dispose();

      final resumed = QuizSessionController(repo);
      await resumed.resume(session.id);
      expect(resumed.submitted, isTrue);
      resumed.dispose();
    });

    test('收藏幂等；取消收藏不影响本次会话题目', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      final c = QuizSessionController(repo);
      await c.start(
          bankId: first.bankId, mode: QuizMode.all, config: const QuizConfig());
      await c.toggleFavorite(first.id);
      await c.toggleFavorite(first.id);
      expect(c.isFavorite(first.id), isFalse);
      await c.toggleFavorite(first.id);
      expect(await repo.isFavorite(first.bankId, first.id), isTrue);
      expect(c.questions.length, 5, reason: '取消收藏不移除本次题目');
      c.dispose();
    });

    test('随机抽题库存不足时给出提示', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      final c = QuizSessionController(repo);
      final picked = await c.pick(
        bankId: first.bankId,
        mode: QuizMode.random,
        config: const QuizConfig(
          typeCounts: <QuestionType, int>{QuestionType.single: 10},
        ),
      );
      expect(picked.shortage, isNotEmpty);
      expect(picked.questions.length, 1, reason: '只有 1 道单选，按库存给');
      c.dispose();
    });

    test('只刷没做过的题：配置随会话持久化，旧数据默认关闭', () {
      const config = QuizConfig(onlyUnseen: true, shuffleQuestions: false);
      final restored = QuizConfig.fromJson(config.toJson());
      expect(restored.onlyUnseen, isTrue);
      expect(restored.shuffleQuestions, isFalse);
      expect(const QuizConfig().onlyUnseen, isFalse);
      expect(QuizConfig.fromJson(<String, dynamic>{}).onlyUnseen, isFalse);
      expect(config.copyWith(onlyUnseen: false).onlyUnseen, isFalse);
    });

    test('只刷没做过的题：排除已作答，抽到但没答的题仍可再抽', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      final c = QuizSessionController(repo);
      await c.start(
          bankId: first.bankId, mode: QuizMode.all, config: const QuizConfig());
      await c.answer(first.id, <String>['B']);
      c.dispose();

      // 会话预插入的 5 条空白作答记录不算「做过」，只有 q1 算。
      expect(await repo.answeredQuestionIds(), <String>{first.id});
      final unseen = await repo.unseenStockOf(first.bankId);
      expect(unseen.values.fold<int>(0, (a, b) => a + b), 4);
      expect(unseen[QuestionType.single] ?? 0, 0);

      final picker = QuizSessionController(repo);
      final all = await picker.pick(
        bankId: first.bankId,
        mode: QuizMode.random,
        config: const QuizConfig(),
      );
      expect(all.questions.length, 5);
      final filtered = await picker.pick(
        bankId: first.bankId,
        mode: QuizMode.random,
        config: const QuizConfig(onlyUnseen: true),
      );
      expect(filtered.questions.length, 4);
      expect(filtered.questions.map((q) => q.id), isNot(contains(first.id)));
      picker.dispose();
    });

    test('只刷没做过的题：全部做完后抽题为空，库存提示按剩余口径', () async {
      final repo = await openRepo();
      final preview = QuizImporter.parse(kSampleBank);
      final result = await QuizImporter.commit(repo, preview);
      final questions = await repo.questionsOfBank(result.bankId);
      final c = QuizSessionController(repo);
      await c.start(
          bankId: result.bankId,
          mode: QuizMode.all,
          config: const QuizConfig());
      for (final q in questions) {
        await c.answer(q.id, <String>['B']);
      }
      c.dispose();

      expect(await repo.unseenStockOf(result.bankId), isEmpty);
      final picker = QuizSessionController(repo);
      final shortage = await picker.pick(
        bankId: result.bankId,
        mode: QuizMode.random,
        config: const QuizConfig(
          onlyUnseen: true,
          typeCounts: <QuestionType, int>{QuestionType.single: 1},
        ),
      );
      expect(shortage.questions, isEmpty);
      expect(shortage.shortage.single, contains('仅有 0'));
      expect(
          await picker.start(
            bankId: result.bankId,
            mode: QuizMode.random,
            config: const QuizConfig(onlyUnseen: true),
          ),
          isFalse);
      picker.dispose();
    });
  });

  group('继续上次', () {
    test('多套未完成时取最近动过的那套', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      for (final (id, started, active) in <(String, int, int)>[
        ('s-a', 1000, 9000),
        ('s-b', 2000, 2000),
        ('s-c', 3000, 3000),
      ]) {
        await repo.insertSession(QuizSession(
          id: id,
          bankId: first.bankId,
          mode: QuizMode.all,
          status: SessionStatus.active,
          startedAt: started,
          activeAt: active,
        ));
      }

      // 创建时间最晚的是 C，但最近动过的是 A：首页必须指向 A。
      final home = await repo.sessions(status: SessionStatus.active, limit: 1);
      expect(home.single.id, 's-a');
      expect((await repo.activeSessionOfBank(first.bankId))!.id, 's-a');

      // 动一下 B，排序立刻跟着换。
      await repo.touchSession('s-b', at: 12000);
      expect(
          (await repo.sessions(status: SessionStatus.active, limit: 1))
              .single
              .id,
          's-b');
    });

    test('断点续答会把该套推到最前', () async {
      final repo = await openRepo();
      final first = await importSample(repo);

      final a = QuizSessionController(repo);
      await a.start(
          bankId: first.bankId, mode: QuizMode.all, config: const QuizConfig());
      final idA = a.session!.id;
      a.dispose();

      final b = QuizSessionController(repo);
      await b.start(
          bankId: first.bankId, mode: QuizMode.all, config: const QuizConfig());
      final idB = b.session!.id;
      b.dispose();

      // 固定时间戳，避免同毫秒创建导致排序不确定。
      await repo.touchSession(idA, at: 1000);
      await repo.touchSession(idB, at: 2000);
      expect(
          (await repo.sessions(status: SessionStatus.active, limit: 1))
              .single
              .id,
          idB);

      final again = QuizSessionController(repo);
      expect(await again.resume(idA), isTrue);
      again.dispose();
      expect(
          (await repo.sessions(status: SessionStatus.active, limit: 1))
              .single
              .id,
          idA,
          reason: '续答过的那套才是「上次未刷完」');
    });

    test('判断题 options 被清空的旧数据，读回时补回固定两项', () async {
      final repo = await openRepo();
      final bankId = await repo.createBank(name: '旧判断题');
      const broken = Question(
        id: 'j1',
        bankId: 'placeholder',
        type: QuestionType.trueFalse,
        stem: '地球是圆的',
        options: <OptionItem>[],
        answer: <String>['true'],
      );
      await repo.insertQuestions(<Question>[broken.copyWith(bankId: bankId)]);

      final stored = await repo.questionById('j1');
      expect(stored, isNotNull);
      expect(stored!.options.map((o) => o.key).toList(),
          <String>['true', 'false']);
    });

    test('练习刷完最后一题会结束会话，不再算「未完成」', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      final controller = QuizSessionController(repo);
      await controller.start(
        bankId: first.bankId,
        mode: QuizMode.all,
        config: const QuizConfig(),
      );

      // 逐题作答（单选题直接选对），简答题走自评，直到全部答完。
      for (final q in controller.questions) {
        if (q.type == QuestionType.short) {
          await controller.judgeShortAnswer(q.id, <String>['答'], true);
        } else {
          await controller.answer(q.id, q.answer);
        }
      }
      expect(controller.allAnswered, isTrue);
      expect(controller.submitted, isFalse, reason: '还没退出，先不自作主张结束');

      await controller.finishPractice();
      expect(controller.submitted, isTrue);
      expect(controller.session!.status, SessionStatus.submitted);
      final id = controller.session!.id;
      controller.dispose();

      final stored = await repo.sessionById(id);
      expect(stored!.status, SessionStatus.submitted);
      expect(stored.finishedAt, isNotNull);
      // 首页「继续上次」不该再挂这一套。
      expect(await repo.activeSessionOfBank(first.bankId), isNull);
    });
  });

  group('数据库迁移', () {
    test('v1 旧库升级到 v2：补上 lastIndex 且不丢原有会话', () async {
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
      final session = await repo.sessionById('old-session');
      expect(session, isNotNull);
      expect(session!.lastIndex, 0);
      await repo.updateSessionIndex('old-session', 2);
      expect((await repo.sessionById('old-session'))!.lastIndex, 2);
    });

    test('v3 旧库升级到 v4：补上 activeAt 并修复被清空的判断题选项', () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await migrateQuiz(db, 0, 3);
      await db.insert('sessions', <String, Object?>{
        'id': 'v3-session',
        'mode': QuizMode.all.key,
        'configJson': '{}',
        'status': SessionStatus.active.key,
        'startedAt': 4321,
      });
      await db.insert('questions', <String, Object?>{
        'id': 'v3-judge',
        'bankId': 'b1',
        'type': QuestionType.trueFalse.key,
        'stem': '旧判断题',
        'optionsJson': '[]',
        'answerJson': '["true"]',
        'tagsJson': '[]',
        'contentHash': 'h',
        'orderNo': 0,
      });
      await migrateQuiz(db, 3, quizSchemaVersion);

      final repo = QuizRepository(db);
      final session = await repo.sessionById('v3-session');
      expect(session, isNotNull);
      expect(session!.activeAt, 4321, reason: '旧会话退回创建时间，排序不会突变');
      expect(session.lastActiveAt, 4321);

      // 被旧编辑页清空的判断题选项在迁移里补回，导出 / 备份也带上。
      final raw = await db.query('questions',
          where: 'id = ?', whereArgs: <Object?>['v3-judge']);
      expect(raw.single['optionsJson'], contains('"true"'));
      final judge = await repo.questionById('v3-judge');
      expect(
          judge!.options.map((o) => o.key).toList(), <String>['true', 'false']);
    });
  });

  group('搜索与备份', () {
    test('全局搜索命中题干并能按题型、错题、收藏过滤', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      await repo.addWrong(first.bankId, first.id);
      final all = await repo.search(query: '1+1');
      expect(all.total, 1);
      expect(all.items.first.bankName, '示例题库');
      expect((await repo.search(query: '不存在的关键词')).total, 0);
      expect(
        (await repo.search(types: <QuestionType>{QuestionType.short})).total,
        1,
      );
      expect((await repo.search(onlyWrong: true)).total, 1);
      expect((await repo.search(onlyFavorite: true)).total, 0);
    });

    test('备份导出后整库覆盖恢复，旧备份里的错误次数等字段被忽略', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      await repo.addWrong(first.bankId, first.id);
      await repo.setSetting('globalScore', '3');
      final backup = await QuizBackupRepository(repo.db).export();

      // 清空后再恢复
      for (final bank in await repo.listBanks()) {
        await repo.deleteBank(bank.id);
      }
      expect(await repo.listBanks(), isEmpty);
      // 旧备份里塞入不存在的字段
      final dirty = Map<String, dynamic>.from(backup);
      dirty['wrongEntries'] = <Map<String, Object?>>[
        <String, Object?>{
          'bankId': first.bankId,
          'questionId': first.id,
          'errorCount': 9,
          'lastWrongAt': 123,
        },
      ];
      await QuizBackupRepository(repo.db).restore(dirty);
      final banks = await repo.listBanks();
      expect(banks.length, 1);
      expect(banks.first.name, '示例题库');
      expect((await repo.questionsOfBank(banks.first.id)).length, 5);
      expect(await repo.isWrong(first.bankId, first.id), isTrue);
      expect(await repo.getSetting('globalScore'), '3');
    });

    test('恢复时结构不完整或版本过高：抛错且不破坏原数据', () async {
      final repo = await openRepo();
      await importSample(repo);
      expect(
        () => QuizBackupRepository(repo.db)
            .restore(<String, dynamic>{'schemaVersion': 1}),
        throwsA(isA<QuizBackupError>()),
      );
      expect(
        () => QuizBackupRepository(repo.db).restore(<String, dynamic>{
          'schemaVersion': 99,
          'banks': <Object>[],
          'questions': <Object>[],
        }),
        throwsA(isA<QuizBackupError>()),
      );
      expect((await repo.listBanks()).length, 1, reason: '失败回滚，原数据保留');
    });
  });

  group('设置对旧会话生效', () {
    test('恢复旧会话时用最新设置覆盖行为开关', () async {
      final repo = await openRepo();
      final first = await importSample(repo);
      final controller = QuizSessionController(repo);
      expect(
        await controller.start(bankId: first.bankId, mode: QuizMode.all),
        isTrue,
      );
      final sessionId = controller.session!.id;
      expect(controller.session!.config.simpleMode, isFalse);

      // 会话建好之后才改设置：会话里存的是当时的快照，恢复时要被覆盖。
      await repo.setSetting('simpleMode', 'true');
      await repo.setSetting('lockAfterConfirm', 'true');
      await repo.setSetting('autoNextOnCorrect', 'true');
      await repo.setSetting('wrongRemoveThreshold', '3');

      final resumed = QuizSessionController(repo);
      expect(await resumed.resume(sessionId), isTrue);
      final config = resumed.session!.config;
      expect(config.simpleMode, isTrue);
      expect(config.lockAfterConfirm, isTrue);
      expect(config.autoNextOnCorrect, isTrue);
      expect(config.wrongRemoveThreshold, 3);
      controller.dispose();
      resumed.dispose();
    });
  });

  group('题目排序', () {
    test('按题型排序写回 orderNo，同题型内保持原顺序', () async {
      final repo = await openRepo();
      final bankId = await repo.createBank(name: '排序题库');
      final types = <QuestionType>[
        QuestionType.short,
        QuestionType.fill,
        QuestionType.trueFalse,
        QuestionType.multiple,
        QuestionType.single,
        QuestionType.single,
      ];
      await repo.insertQuestions([
        for (var i = 0; i < types.length; i++)
          Question(
            id: 'q$i',
            bankId: bankId,
            type: types[i],
            stem: '第 $i 题',
            orderNo: i + 1,
          ),
      ]);

      expect(
        (await repo.questionsOfBank(bankId, limit: 100))
            .map((q) => q.stem)
            .toList(),
        <String>['第 0 题', '第 1 题', '第 2 题', '第 3 题', '第 4 题', '第 5 题'],
      );

      await repo.sortQuestionsByType(bankId);
      final sorted = await repo.questionsOfBank(bankId, limit: 100);
      expect(
        sorted.map((q) => q.type).toList(),
        <QuestionType>[
          QuestionType.single,
          QuestionType.single,
          QuestionType.multiple,
          QuestionType.trueFalse,
          QuestionType.fill,
          QuestionType.short,
        ],
      );
      expect(
        sorted.map((q) => q.stem).toList(),
        <String>['第 4 题', '第 5 题', '第 3 题', '第 2 题', '第 1 题', '第 0 题'],
      );
      expect(sorted.map((q) => q.orderNo).toList(), <int>[1, 2, 3, 4, 5, 6]);
    });

    test('排序后错题、收藏与进行中的会话仍指向同一道题', () async {
      final repo = await openRepo();
      final bankId = await repo.createBank(name: '一致性题库');
      final questions = <Question>[
        Question(
            id: 'cw1',
            bankId: bankId,
            type: QuestionType.short,
            stem: '原第一题',
            orderNo: 1),
        Question(
            id: 'cf1',
            bankId: bankId,
            type: QuestionType.single,
            stem: '原第二题',
            orderNo: 2),
      ];
      await repo.insertQuestions(questions);
      await repo.addWrong(bankId, 'cw1');
      await repo.addFavorite(bankId, 'cf1');

      final c = QuizSessionController(repo);
      await c.start(
          bankId: bankId, mode: QuizMode.all, config: const QuizConfig());
      final sessionId = c.session!.id;
      // 停在第 1 题（简答），进度记为索引 1。
      c.goTo(1);
      await c.saveProgress();
      c.dispose();

      await repo.sortQuestionsByType(bankId);

      expect(await repo.wrongIds(bankId: bankId), <String>{'cw1'});
      expect(await repo.favoriteIds(bankId: bankId), <String>{'cf1'});
      expect((await repo.wrongQuestions(bankId: bankId)).single.stem, '原第一题');
      expect(
          (await repo.favoriteQuestions(bankId: bankId)).single.stem, '原第二题');

      // 会话题目顺序是创建时冻结的快照，排序不影响「继续上次」的题目。
      final resumed = QuizSessionController(repo);
      expect(await resumed.resume(sessionId), isTrue);
      expect(resumed.questions[resumed.index].stem, '原第二题');
      expect(resumed.index, 1);
      resumed.dispose();
    });
  });
}
