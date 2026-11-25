import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_initials.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_search_page.dart';
import '../support/test_env.dart';

Future<QuizRepository> openSearchRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  final repo = QuizRepository(db);
  final a = await repo.createBank(name: '地理');
  final b = await repo.createBank(name: '数据结构');
  await repo.insertQuestions(<Question>[
    Question(
      id: 'a1',
      bankId: a,
      type: QuestionType.single,
      stem: '中国的首都是北京',
      options: const <OptionItem>[
        OptionItem(key: 'A', text: '北京'),
        OptionItem(key: 'B', text: '上海'),
      ],
      answer: const <String>['A'],
      orderNo: 0,
    ),
    Question(
      id: 'b1',
      bankId: b,
      type: QuestionType.single,
      stem: '中国的数据结构教材',
      options: const <OptionItem>[
        OptionItem(key: 'A', text: '对'),
        OptionItem(key: 'B', text: '错'),
      ],
      answer: const <String>['A'],
      orderNo: 0,
    ),
  ]);
  return repo;
}

void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
    QuizInitials.resetForTest();
  });

  tearDown(() async {
    QuizInitials.resetForTest();
    await restoreSystemLanguage();
  });

  testWidgets('三种搜索口径都在，首字母模式带输入提示', (tester) async {
    final repo = await openSearchRepo();
    await tester.pumpWidget(MaterialApp(home: QuizSearchPage(repo: repo)));
    await tester.pumpAndSettle();

    expect(find.text('包含'), findsOneWidget);
    expect(find.text('关键词'), findsOneWidget);
    expect(find.text('首字母'), findsOneWidget);

    await tester.tap(find.text('首字母'));
    await tester.pumpAndSettle();
    expect(find.textContaining('输入汉字首字母'), findsOneWidget);
  });

  testWidgets('题库范围可以多选，一个都不选就是全部题库', (tester) async {
    final repo = await openSearchRepo();
    final banks = await repo.listBanks();
    final geo = banks.firstWhere((b) => b.name == '地理');
    final ds = banks.firstWhere((b) => b.name == '数据结构');

    await tester.pumpWidget(MaterialApp(home: QuizSearchPage(repo: repo)));
    await tester.pumpAndSettle();

    // 默认全部题库。
    expect(find.text('全部题库'), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-banks')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('filter-banks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('bank-sheet-${geo.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('bank-sheet-${ds.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bank-sheet-ok')));
    await tester.pumpAndSettle();
    expect(find.text('题库 2'), findsOneWidget);

    // 回到「全部题库」：清空选择。
    await tester.tap(find.byKey(const ValueKey('filter-banks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bank-sheet-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bank-sheet-ok')));
    await tester.pumpAndSettle();
    expect(find.text('全部题库'), findsOneWidget);
  });

  testWidgets('重新进入全局搜索会保留上次题库选择', (tester) async {
    final repo = await openSearchRepo();
    final geo = (await repo.listBanks()).firstWhere((b) => b.name == '地理');

    await tester.pumpWidget(MaterialApp(home: QuizSearchPage(repo: repo)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-banks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('bank-sheet-${geo.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bank-sheet-ok')));
    await tester.pumpAndSettle();
    expect(find.text('题库 1'), findsOneWidget);

    // 销毁页面后重新进入，默认沿用刚才的范围，无需重选。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(MaterialApp(home: QuizSearchPage(repo: repo)));
    await tester.pumpAndSettle();
    expect(find.text('题库 1'), findsOneWidget);
  });

  testWidgets('搜素结果按题库范围过滤', (tester) async {
    final repo = await openSearchRepo();
    final banks = await repo.listBanks();
    final geo = banks.firstWhere((b) => b.name == '地理');

    await tester.pumpWidget(MaterialApp(home: QuizSearchPage(repo: repo)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('filter-banks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('bank-sheet-${geo.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bank-sheet-ok')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      '中国',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('共 1 条结果'), findsOneWidget);
    expect(find.text('中国的首都是北京'), findsOneWidget);
    expect(find.text('中国的数据结构教材'), findsNothing);
  });
}
