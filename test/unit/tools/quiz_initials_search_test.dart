import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_initials.dart';

/// 假拼音表：只覆盖测试用到的汉字，够验证匹配与排序即可。
const Map<String, String> kPinyin = <String, String>{
  '中': 'z',
  '国': 'g',
  '的': 'd',
  '首': 's',
  '都': 'd',
  '是': 's',
  '北': 'b',
  '京': 'j',
  '上': 's',
  '海': 'h',
  '一': 'y',
  '个': 'g',
  '人': 'r',
  '数': 's',
  '据': 'j',
  '结': 'j',
  '构': 'g',
  '语': 'y',
  '文': 'w',
  '题': 't',
};

Future<({bool supported, List<String> initials})?> fakeConverter(
  List<String> texts,
) async =>
    (
      supported: true,
      initials: <String>[
        for (final text in texts)
          text
              .split('')
              .map((c) => kPinyin[c] ?? '')
              .where((c) => c.isNotEmpty)
              .join(),
      ],
    );

Future<QuizRepository> openInitialsRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

Question question(String id, String bankId, String stem, {int orderNo = 0}) =>
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
      orderNo: orderNo,
    );

void main() {
  late QuizRepository repo;
  late String bankA;
  late String bankB;

  setUp(() async {
    QuizInitials.resetForTest();
    QuizInitials.debugConverter = fakeConverter;
    repo = await openInitialsRepo();
    bankA = await repo.createBank(name: '地理');
    bankB = await repo.createBank(name: '数据结构');
    await repo.insertQuestions(<Question>[
      question('a1', bankA, '中国的首都是北京', orderNo: 0),
      question('a2', bankA, '上海是一个城市', orderNo: 1),
      question('a3', bankA, '北京的海拔', orderNo: 2),
      question('b1', bankB, '数据结构与算法', orderNo: 0),
      question('b2', bankB, '中国的数据结构教材', orderNo: 1),
    ]);
  });

  tearDown(() => QuizInitials.resetForTest());

  test('查询串归一：只保留英文字母并转小写', () {
    expect(QuizInitials.normalizeQuery(' ZG DD '), 'zgdd');
    expect(QuizInitials.normalizeQuery('z-g/dd'), 'zgdd');
    expect(QuizInitials.normalizeQuery('中国'), '');
  });

  test('空格 / 标点分隔多个首字母片段，逐段归一去重', () {
    expect(QuizInitials.splitQuery('ZGDD sh'), <String>['zgdd', 'sh']);
    expect(QuizInitials.splitQuery('zgdd，sh;sh'), <String>['zgdd', 'sh']);
    expect(QuizInitials.splitQuery('zg-dd sh'), <String>['zgdd', 'sh']);
    expect(QuizInitials.splitQuery('中国'), isEmpty);
    expect(QuizInitials.splitQuery('   '), isEmpty);
  });

  test('空格分隔的多个片段都要命中，不再被拼成一整串', () async {
    // 旧逻辑会把 'zgd bj' 归一成 'zgdbj'，任何题都搜不到。
    final result = await repo.searchInitials(query: 'zgd bj');
    expect(result.total, 1);
    expect(result.items.single.question.stem, '中国的首都是北京');

    // 标点分隔与空格等价。
    final punctuated = await repo.searchInitials(query: 'zgd,bj');
    expect(punctuated.total, 1);

    // 少一个片段命中就不算匹配（与「多个关键词句都要匹配」一致）。
    expect((await repo.searchInitials(query: 'zgd sh')).total, 0);

    // 单片段行为与旧版完全一致。
    expect((await repo.searchInitials(query: 'zgd')).total, 2);
    expect((await repo.searchInitials(query: 'zgd bj bj')).total, 1,
        reason: '重复片段自动去重');
  });

  test('首字母命中题干，开头命中排在前面', () async {
    final result = await repo.searchInitials(query: 'zgd');
    expect(result.total, 2, reason: '「中国的首都是北京」「中国的数据结构教材」');

    // 两条都从题干开头命中时，短题干优先；这里长度相同，按题库顺序稳定排序。
    final stems = result.items.map((e) => e.question.stem).toList();
    expect(stems, containsAll(<String>['中国的首都是北京', '中国的数据结构教材']));

    final prefixFirst = await repo.searchInitials(query: 'zgds');
    expect(prefixFirst.items.first.question.stem, '中国的首都是北京');
  });

  test('题库多选：只在勾选的题库里搜', () async {
    final onlyB = await repo.searchInitials(
      query: 'zg',
      bankIds: <String>{bankB},
    );
    expect(onlyB.total, 1);
    expect(onlyB.items.single.question.bankId, bankB);
    expect(onlyB.items.single.bankName, '数据结构');

    final both = await repo.searchInitials(
      query: 'zg',
      bankIds: <String>{bankA, bankB},
    );
    expect(both.total, 2);

    // 空集合 = 全部题库，与不传一致。
    expect((await repo.searchInitials(query: 'zg')).total, both.total);
  });

  test('普通搜索与关键词搜索也支持多题库范围', () async {
    final contains = await repo.search(
      query: '中国',
      bankIds: <String>{bankB},
    );
    expect(contains.total, 1);
    expect(contains.items.single.question.bankId, bankB);

    final keywords = await repo.searchKeywords(
      query: '中国',
      bankIds: <String>{bankA},
    );
    expect(keywords.total, 1);
    expect(keywords.items.single.question.bankId, bankA);
  });

  test('纯汉字查询归一等同于没输入，返回空结果', () async {
    final result = await repo.searchInitials(query: '中国');
    expect(result.total, 0);
    expect(result.items, isEmpty);
  });

  test('系统不支持首字母时返回空而不抛错', () async {
    QuizInitials.resetForTest();
    QuizInitials.debugConverter = (texts) async => null;
    final result = await repo.searchInitials(query: 'zg');
    expect(result.total, 0);
    expect(QuizInitials.supported, isFalse);
  });
}
