import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';
import 'package:toolbox/features/tools/quiz/ui/bank_detail_page.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_common.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_study_page.dart';
import '../support/test_env.dart';

const String kBank = '''
{
  "version": 1,
  "bankName": "演示题库",
  "questions": [
    {"id": "q1", "type": "single", "stem": "1 + 1 等于多少？",
     "options": [{"key": "A", "text": "1"}, {"key": "B", "text": "2"}],
     "answer": ["B"], "analysis": "基础加法"},
    {"id": "q2", "type": "true_false", "stem": "地球是圆的。",
     "options": [{"key": "true", "text": "正确"}, {"key": "false", "text": "错误"}],
     "answer": ["true"]}
  ]
}
''';

Future<QuizRepository> openRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

void main() {
  late QuizRepository repo;

  setUp(() async {
    mockPrefs();
    await useChineseUi();
    repo = await openRepo();
    QuizServices.testRepo = repo;
  });

  tearDown(() async {
    QuizServices.reset();
    await restoreSystemLanguage();
  });

  Future<String> importBank() async =>
      (await QuizImporter.commit(repo, QuizImporter.parse(kBank))).bankId;

  testWidgets('背题卡片在第二行，排在收藏之后、笔记之前', (tester) async {
    await importBank();
    final bank = (await repo.listBanks()).first;
    await tester
        .pumpWidget(MaterialApp(home: BankDetailPage(repo: repo, bank: bank)));
    await tester.pumpAndSettle();

    Rect rectOf(String key) =>
        tester.getRect(find.byKey(ValueKey<String>(key)));
    final favorite = rectOf('bank-card-favorite');
    final study = rectOf('bank-card-study');
    final notes = rectOf('bank-card-notes');

    expect(find.text('背题模式'), findsOneWidget);
    expect(study.top, closeTo(favorite.top, 0.5));
    expect(study.top, closeTo(notes.top, 0.5));
    expect(study.left, greaterThan(favorite.left));
    expect(study.left, lessThan(notes.left), reason: '背题排在笔记前面');
    expect(study.width, study.height, reason: '与错题收藏同款正方形卡');
    expect(study.width, closeTo(favorite.width, 0.5));
  });

  testWidgets('背题页可选范围与题型，题数随选择实时变化', (tester) async {
    final bankId = await importBank();
    final questions = await repo.questionsOfBank(bankId, limit: 100000);
    await repo.addWrong(bankId, questions.first.id);
    await repo.addFavorite(bankId, questions.last.id);

    await tester.pumpWidget(
        MaterialApp(home: QuizStudyPage(repo: repo, bankId: bankId)));
    await tester.pumpAndSettle();

    String count() => tester
        .widget<Text>(
            find.byKey(const ValueKey('study-count'), skipOffstage: false))
        .data!;
    expect(count(), '共 2 题');
    expect(find.text('按题型'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('study-scope-type')));
    await tester.pumpAndSettle();
    expect(find.text('选择题型'), findsOneWidget);
    expect(count(), '共 2 题', reason: '未勾选时包含全部题型');
    await tester.tap(find.byKey(const ValueKey('study-type-single')));
    await tester.pumpAndSettle();
    expect(count(), '共 1 题');

    await tester.tap(find.byKey(const ValueKey('study-scope-wrong')));
    await tester.pumpAndSettle();
    expect(count(), '共 1 题');
    expect(find.text('选择题型'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('study-scope-favorite')));
    await tester.pumpAndSettle();
    expect(count(), '共 1 题');
  });

  testWidgets('开始背题：进入即显示正确答案与解析，只读且不写练习记录', (tester) async {
    await importBank();
    final bank = (await repo.listBanks()).first;
    await tester
        .pumpWidget(MaterialApp(home: BankDetailPage(repo: repo, bank: bank)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bank-card-study')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('study-start')));
    await tester.pumpAndSettle();

    // 与刷题界面相似：题干、选项、进度条都在，标题标明背题。
    expect(find.text('背题 1 / 2'), findsOneWidget);
    expect(find.text('1 + 1 等于多少？'), findsOneWidget);
    expect(find.byKey(const ValueKey('answer-progress')), findsOneWidget);
    // 无需作答就显示答案与解析。
    expect(find.text('答案与解析'), findsOneWidget);
    expect(find.text('正确答案：B'), findsOneWidget);
    expect(find.text('基础加法'), findsOneWidget);
    // 只读：没有确认 / 交卷 / 自评入口。
    expect(find.byKey(const ValueKey('answer-confirm')), findsNothing);
    expect(find.byKey(const ValueKey('answer-submit')), findsNothing);
    expect(
      tester
          .widget<RadioListTile<String>>(find.byKey(const ValueKey('opt-A')))
          .onChanged,
      isNull,
      reason: '背题时选项不可点选',
    );

    // 会话纯内存，题库里不出现新的练习记录或错题。
    expect(await repo.sessions(status: SessionStatus.active), isEmpty);
    expect((await repo.db.query('session_questions')).isEmpty, isTrue);
    expect(await repo.wrongIds(), isEmpty);

    // 翻页后仍然默认展开答案，且不落库。
    await tester.tap(find.byKey(const ValueKey('answer-next')));
    await tester.pumpAndSettle();
    expect(find.text('背题 2 / 2'), findsOneWidget);
    expect(find.text('正确答案：正确'), findsOneWidget);
    expect(await repo.sessions(status: SessionStatus.active), isEmpty);

    // 退出直接返回，不弹「退出将保存进度」确认。
    await tester.tap(find.byType(BackButton).first);
    await tester.pumpAndSettle();
    expect(find.text('退出练习'), findsNothing);
    expect(find.text('背题模式'), findsOneWidget);
  });

  testWidgets('背题范围内没有题目时提示且不会进入答题页', (tester) async {
    final bankId = await importBank();
    await tester.pumpWidget(
        MaterialApp(home: QuizStudyPage(repo: repo, bankId: bankId)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('study-scope-wrong')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Text>(
                find.byKey(const ValueKey('study-count'), skipOffstage: false))
            .data,
        '共 0 题');
    await tester.tap(find.byKey(const ValueKey('study-start')));
    await tester.pumpAndSettle();
    expect(find.text('没有可背的题目'), findsOneWidget);
    expect(find.text('背题 1 / 2'), findsNothing);
  });

  testWidgets('背题选项：乱序与已背不出现开关、数量滑块与输入框联动', (tester) async {
    final bankId = await importBank();
    await tester.pumpWidget(
        MaterialApp(home: QuizStudyPage(repo: repo, bankId: bankId)));
    await tester.pumpAndSettle();

    // 默认：两个开关关、数量等于最大值 2（输入框留空，hint 显示 2）。
    final shuffle = tester.widget<Switch>(find.descendant(
        of: find.byKey(const ValueKey('study-shuffle')),
        matching: find.byType(Switch)));
    expect(shuffle.value, isFalse);
    final skip = tester.widget<Switch>(find.descendant(
        of: find.byKey(const ValueKey('study-skip-studied')),
        matching: find.byType(Switch)));
    expect(skip.value, isFalse);
    final countInput = tester
        .widget<TextField>(find.byKey(const ValueKey('study-count-input')));
    expect(countInput.controller!.text, isEmpty);
    expect(countInput.decoration!.hintText, '2');

    // 拖动滑块到 1 → 输入框与题数同步。
    await tester.tap(find.byKey(const ValueKey('study-shuffle')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Switch>(find.descendant(
                of: find.byKey(const ValueKey('study-shuffle')),
                matching: find.byType(Switch)))
            .value,
        isTrue);

    await tester.enterText(
        find.byKey(const ValueKey('study-count-input')), '1');
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Text>(
                find.byKey(const ValueKey('study-count'), skipOffstage: false))
            .data,
        '共 1 题');
  });

  testWidgets('背题记录栏：显示已背题、可清空且不污染练习数据', (tester) async {
    final bankId = await importBank();
    final questions = await repo.questionsOfBank(bankId, limit: 100000);
    await repo.markStudied(bankId, questions.first.id);

    await tester.pumpWidget(
        MaterialApp(home: QuizStudyPage(repo: repo, bankId: bankId)));
    await tester.pumpAndSettle();

    expect(find.text('背题记录'), findsOneWidget);
    expect(find.text('已背 1 题'), findsOneWidget);
    expect(find.textContaining('1 + 1 等于多少？'), findsWidgets);

    // 开启「已背过的题不出现」→ 题数从 2 变 1。
    await tester.tap(find.byKey(const ValueKey('study-skip-studied')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Text>(
                find.byKey(const ValueKey('study-count'), skipOffstage: false))
            .data,
        '共 1 题');

    await tester.tap(find.byKey(const ValueKey('study-history-clear')));
    await tester.pumpAndSettle();
    expect(await repo.studiedIds(bankId), isEmpty);
    expect(find.text('暂无背题记录'), findsOneWidget);
  });
}
