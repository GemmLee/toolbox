import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_search.dart';

Future<QuizRepository> openKeywordRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

Question question(
  String id,
  String bankId, {
  required String stem,
  String analysis = '',
  List<String> tags = const <String>[],
  int orderNo = 0,
}) =>
    Question(
      id: id,
      bankId: bankId,
      type: QuestionType.single,
      stem: stem,
      options: const <OptionItem>[
        OptionItem(key: 'A', text: '对'),
        OptionItem(key: 'B', text: '错'),
      ],
      answer: const <String>['A'],
      analysis: analysis.isEmpty ? null : analysis,
      tags: tags,
      orderNo: orderNo,
    );

void main() {
  group('关键词切分与词项等同匹配', () {
    test('按空格、逗号、顿号、分号切分，去重且忽略大小写', () {
      expect(splitKeywords('  北京 上海，北京、广州;SHENZHEN '),
          <String>['北京', '上海', '广州', 'shenzhen']);
      expect(splitKeywords(''), isEmpty);
      expect(splitKeywords('「光合作用」'), <String>['光合作用']);
    });

    test('英文按整词边界命中，cat 不会命中 category', () {
      expect(containsExactTerm('category theory', 'cat'), isFalse);
      expect(containsExactTerm('a cat here', 'cat'), isTrue);
      expect(containsExactTerm('CAT', 'cat'), isTrue);
      expect(containsExactTerm('cat2', 'cat'), isFalse);
    });

    test('中文按连续子串命中，带符号词按原样命中', () {
      expect(containsExactTerm('中国的首都是北京', '北京'), isTrue);
      expect(containsExactTerm('1+1=?', '1+1'), isTrue);
      expect(containsExactTerm('中国的首都是北京', '上海'), isFalse);
    });

    test('LIKE 模式转义通配符，用户输入不会被当成通配', () {
      expect(likePatternOf('a_b%c'), r'%a\_b\%c%');
      expect(likePatternOf('北京'), '%北京%');
    });
  });

  group('相关度打分', () {
    test('题干命中优于解析命中', () {
      final inStem = question('a', 'b', stem: '光合作用需要光照');
      final inAnalysis =
          question('b', 'b', stem: '无关题目', analysis: '光合作用');
      expect(relevanceOf(inStem, <String>['光合作用']),
          greaterThan(relevanceOf(inAnalysis, <String>['光合作用'])));
    });

    test('全部词项命中优于部分命中，不命中为 0', () {
      final q = question('a', 'b', stem: '光合作用需要光照');
      final full = relevanceOf(q, <String>['光合作用', '光照']);
      final partial = relevanceOf(q, <String>['光合作用', '不存在']);
      expect(full, greaterThan(partial));
      expect(relevanceOf(q, <String>['不存在']), 0);
      expect(full, inInclusiveRange(0, 1));
    });
  });

  group('仓库关键词搜索', () {
    test('按相关度降序返回，携带内部相关度且可分页', () async {
      final repo = await openKeywordRepo();
      final bankId = await repo.createBank(name: '关键词测试');
      await repo.insertQuestions(<Question>[
        question('q1', bankId, stem: '光合作用需要光照', orderNo: 1),
        question('q2', bankId, stem: '无关题目', analysis: '光合作用', orderNo: 2),
        question('q3', bankId,
            stem: '光合作用需要光照和叶绿素',
            tags: const <String>['光照'],
            orderNo: 3),
        question('q4', bankId, stem: 'CATEGORY theory', orderNo: 4),
      ]);

      final result = await repo.searchKeywords(query: '光合作用 光照');
      expect(result.total, 3);
      expect(result.items.map((h) => h.question.id).toList(),
          <String>['q3', 'q1', 'q2']);
      expect(result.items.every((h) => h.relevance > 0), isTrue);
      expect(result.items.first.relevance,
          greaterThan(result.items.last.relevance));

      final firstPage =
          await repo.searchKeywords(query: '光合作用', limit: 2, offset: 0);
      final secondPage =
          await repo.searchKeywords(query: '光合作用', limit: 2, offset: 2);
      expect(firstPage.total, 3);
      expect(firstPage.items.length, 2);
      expect(secondPage.items.length, 1);
      expect(secondPage.items.first.question.id,
          isNot(firstPage.items.first.question.id));
    });

    test('英文整词匹配：cat 不会把 category 搜出来', () async {
      final repo = await openKeywordRepo();
      final bankId = await repo.createBank(name: '英文测试');
      await repo.insertQuestions(<Question>[
        question('a', bankId, stem: 'a cat sits here'),
        question('b', bankId, stem: 'category theory'),
      ]);
      final hits = await repo.searchKeywords(query: 'cat');
      expect(hits.total, 1);
      expect(hits.items.first.question.id, 'a');
      // 原有「包含」模式仍按子串匹配，两题都命中，行为没有被改坏。
      expect((await repo.search(query: 'cat')).total, 2);
    });

    test('关键词为空时退回普通搜索，过滤条件仍然生效', () async {
      final repo = await openKeywordRepo();
      final bankId = await repo.createBank(name: '空词测试');
      await repo.insertQuestions(<Question>[
        question('a', bankId, stem: '甲'),
        question('b', bankId, stem: '乙'),
      ]);
      expect((await repo.searchKeywords()).total, 2);
      expect(
        (await repo.searchKeywords(
          types: <QuestionType>{QuestionType.multiple},
        )).total,
        0,
      );
    });
  });
}
