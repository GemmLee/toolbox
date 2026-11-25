import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';
import 'package:toolbox/features/tools/quiz/ui/bank_detail_page.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_common.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_stats_ring.dart';
import '../support/test_env.dart';

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

  Future<String> importBank() async {
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    return result.bankId;
  }

  testWidgets('笔记卡片：逐条新增 / 编辑 / 删除，回到首页计数同步', (tester) async {
    final bankId = await importBank();
    final bank = (await repo.listBanks()).first;
    await tester
        .pumpWidget(MaterialApp(home: BankDetailPage(repo: repo, bank: bank)));
    await tester.pumpAndSettle();
    expect(find.text('0 条笔记'), findsOneWidget);

    final card = find.byKey(const ValueKey('bank-card-notes'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.text('还没有笔记，点右下角按钮记一条'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('note-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '第一题要注意单位');
    await tester.tap(find.byKey(const ValueKey('note-save')));
    await tester.pumpAndSettle();
    expect(find.text('第一题要注意单位'), findsOneWidget);
    expect(await repo.countNotes(bankId), 1);

    await tester.tap(find.text('第一题要注意单位'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '第一题要注意单位换算');
    await tester.tap(find.byKey(const ValueKey('note-save')));
    await tester.pumpAndSettle();
    expect(find.text('第一题要注意单位换算'), findsOneWidget);
    expect(await repo.countNotes(bankId), 1, reason: '编辑不新增条目');

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('删除笔记'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('还没有笔记，点右下角按钮记一条'), findsOneWidget);
    expect(await repo.countNotes(bankId), 0);

    await tester.tap(find.byType(BackButton).first);
    await tester.pumpAndSettle();
    expect(find.text('0 条笔记'), findsOneWidget);
  });

  testWidgets('统计大卡：圆环显示已刷 / 错题比例，详情页给出细分数据', (tester) async {
    final bankId = await importBank();
    final questions = await repo.questionsOfBank(bankId);
    await repo.addWrong(bankId, questions.first.id);
    await repo.db.insert('session_questions', <String, Object?>{
      'sessionId': 's1',
      'questionId': questions.first.id,
      'orderNo': 0,
      'userAnswerJson': '["B"]',
      'isCorrect': 1,
      'selfJudged': 0,
    });

    final stats = await repo.stats(bankId: bankId);
    expect(stats.seenCount, 1);
    expect(stats.wrongCount, 1);
    final fractions = ringFractions(stats);
    expect(fractions.seen, closeTo(0.5, 0.001));
    expect(fractions.wrong, closeTo(0.5, 0.001));

    final bank = (await repo.listBanks()).first;
    await tester
        .pumpWidget(MaterialApp(home: BankDetailPage(repo: repo, bank: bank)));
    await tester.pumpAndSettle();
    final total =
        tester.widget<Text>(find.byKey(const ValueKey('stats-ring-total')));
    expect(total.data, '2', reason: '圆环中心是题目总数');
    expect(find.text('已刷 1'), findsOneWidget);
    expect(find.text('错题 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bank-card-stats')));
    await tester.pumpAndSettle();
    expect(find.text('统计详情'), findsOneWidget);
    expect(find.text('刷题进度'), findsOneWidget);
    expect(find.text('已刷题目'), findsOneWidget);
    expect(find.text('未刷题目'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('作答表现'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('作答表现'), findsOneWidget);
  });

  testWidgets('卡片尺寸与工具总览相近，统计在左、预览错题竖排右侧', (tester) async {
    await importBank();
    final bank = (await repo.listBanks()).first;
    await tester
        .pumpWidget(MaterialApp(home: BankDetailPage(repo: repo, bank: bank)));
    await tester.pumpAndSettle();

    Rect rectOf(String key) =>
        tester.getRect(find.byKey(ValueKey<String>(key)));
    final stats = rectOf('bank-card-stats');
    final preview = rectOf('bank-card-preview');
    final wrong = rectOf('bank-card-wrong');
    final favorite = rectOf('bank-card-favorite');
    final notes = rectOf('bank-card-notes');

    // 小卡是正方形，边长与三列网格（工具总览同款）一致，约 120px。
    expect(preview.width, preview.height);
    expect(preview.width, lessThan(130));
    expect(preview.width, greaterThan(90));
    // 统计 2×2 在左，预览 / 错题竖排贴右侧同一列。
    expect(stats.left, closeTo(preview.left - 2 * preview.width - 20, 0.5),
        reason: '统计卡占左侧两列');
    expect(stats.width, closeTo(preview.width * 2 + 10, 0.5));
    expect(preview.left, closeTo(wrong.left, 0.5));
    expect(wrong.top, greaterThan(preview.bottom));
    expect(stats.bottom, closeTo(wrong.bottom, 0.5), reason: '两行高度对齐');
    // 收藏 / 笔记另起一行。
    expect(favorite.top, greaterThan(stats.bottom));
    expect(notes.top, closeTo(favorite.top, 0.5));
    expect(notes.left, greaterThan(favorite.left));
  });

  test('圆环内缘与题目数动态字号：位数越多字越小，宽度不压到圆环', () {
    const side = 160.0;
    final inner = ringInnerDiameter(side);
    expect(inner, lessThan(side), reason: '内缘要扣掉两侧粗环线宽');
    expect(inner, greaterThan(side * 0.6));

    final short = ringTotalFontSize(side: side, total: 12);
    expect(ringTotalFontSize(side: side, total: 1234), lessThan(short),
        reason: '一千多道题时数字明显缩小');
    expect(ringTotalFontSize(side: side, total: 123456),
        lessThan(ringTotalFontSize(side: side, total: 1234)));

    for (final total in <int>[0, 9, 99, 999, 1234, 9999, 99999, 999999]) {
      final font = ringTotalFontSize(side: side, total: total);
      final width = total.toString().length * font * kRingDigitWidthFactor;
      expect(width, lessThanOrEqualTo(inner * kRingInnerWidthFactor + 0.01),
          reason: '$total 的数字宽度不能压到圆环上');
      expect(font, greaterThanOrEqualTo(11.0));
    }
    expect(ringTotalFontSize(side: 250, total: 1234),
        greaterThan(ringTotalFontSize(side: 160, total: 1234)),
        reason: '详情页大圆环可以用更大的字号');
  });

  testWidgets('圆环内不显示「题目」，已刷 / 错题标记嵌在环里', (tester) async {
    const stats = QuizStats(
      questionCount: 1234,
      seenCount: 800,
      wrongCount: 120,
    );
    await tester.pumpWidget(const MaterialApp(
      home: Center(child: BankStatsRing(stats: stats, size: 160)),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('stats-ring')), findsOneWidget);
    expect(find.text('题目'), findsNothing, reason: '环内「题目」二字已删除');
    expect(find.text('已刷 800'), findsOneWidget);
    expect(find.text('错题 120'), findsOneWidget);

    final ring = tester.getRect(find.byKey(const ValueKey('stats-ring')));
    for (final label in <String>['已刷 800', '错题 120']) {
      final rect = tester.getRect(find.text(label));
      expect(ring.contains(rect.topLeft) && ring.contains(rect.bottomRight),
          isTrue,
          reason: '$label 标记应落在圆环范围内');
    }

    final totalText =
        tester.widget<Text>(find.byKey(const ValueKey('stats-ring-total')));
    expect(totalText.data, '1234');
    expect(totalText.style?.fontSize,
        closeTo(ringTotalFontSize(side: 160, total: 1234), 0.01));
    expect(totalText.style!.fontSize,
        lessThan(ringTotalFontSize(side: 160, total: 12)));
    // 极长数字还有 FittedBox 兜底，组件不会因缩放溢出。
    expect(find.byType(FittedBox), findsWidgets);
  });

  testWidgets('统计卡圆环放大到卡片尺寸的 3/4', (tester) async {
    await importBank();
    final bank = (await repo.listBanks()).first;
    await tester
        .pumpWidget(MaterialApp(home: BankDetailPage(repo: repo, bank: bank)));
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byKey(const ValueKey('bank-card-stats')));
    final ring =
        tester.widget<SizedBox>(find.byKey(const ValueKey('stats-ring')));
    expect(ring.width, closeTo(card.width * 0.76, 0.01));
    expect(ring.height, ring.width);
  });

  test('统计圆环：两层线宽都加粗，已刷环颜色比主题色浅', () {
    expect(kRingStrokeFactor, greaterThan(0.075));
    expect(
        kRingStrokeFactor * kWrongRingStrokeFactor, greaterThan(0.075 * 0.42),
        reason: '错题环也比旧版更粗');
    expect(kWrongRingStrokeFactor, lessThan(1), reason: '错题环仍细于已刷环，保持覆盖层次');

    for (final brightness in Brightness.values) {
      final scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF3E7BFA),
        brightness: brightness,
      );
      final seen = seenRingColor(scheme);
      expect(seen, isNot(scheme.primary));
      final surfaceLum = scheme.surface.computeLuminance();
      expect((seen.computeLuminance() - surfaceLum).abs(),
          lessThan((scheme.primary.computeLuminance() - surfaceLum).abs()),
          reason: '已刷环向卡片底色靠拢，视觉上更柔和');
    }
  });
}
