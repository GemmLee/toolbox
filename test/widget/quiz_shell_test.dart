import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/core/widgets/app_widgets.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_common.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_page.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_search_guide_page.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_shell.dart';
import '../support/test_env.dart';

Future<QuizRepository> openShellRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  tearDown(() {
    QuizServices.reset();
    restoreSystemLanguage();
  });

  testWidgets('底部导航两栏：默认刷题，切到搜题显示三个搜题卡片', (tester) async {
    QuizServices.testRepo = await openShellRepo();
    await tester.pumpWidget(
      const MaterialApp(home: QuizScope(child: QuizShell())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('quiz-bottom-nav')), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(QuizPage), findsOneWidget);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    // 第二栏已经从「其他」改名「搜题」。
    expect(find.text('搜题'), findsOneWidget);
    expect(find.text('其他'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('quiz-tab-search')));
    await tester.pumpAndSettle();

    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1);
    expect(find.byKey(const ValueKey('quiz-search-photo')), findsOneWidget);
    expect(find.byKey(const ValueKey('quiz-search-quick')), findsOneWidget);
    expect(find.byKey(const ValueKey('quiz-search-smart')), findsOneWidget);
    expect(find.text('拍照搜题'), findsOneWidget);
    expect(find.text('便捷搜题'), findsOneWidget);
    expect(find.text('智能搜题'), findsOneWidget);
    expect(find.byType(QuizSearchTabPage), findsOneWidget);

    // 卡片能进对应页面。
    await tester.tap(find.byKey(const ValueKey('quiz-search-photo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('photo-search-camera')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quiz-search-quick')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick-search-toggle')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quiz-search-smart')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('smart-search-toggle')), findsOneWidget);
  });

  testWidgets('搜题页底部常驻免责小字', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: QuizSearchTabPage()));
    await tester.pumpAndSettle();
    final hint = find.text('本功能仅供学习参考，请勿用于考试');
    await tester.scrollUntilVisible(
      hint,
      120,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 20,
    );
    expect(hint, findsOneWidget);
  });

  testWidgets('搜题教程首节是完整的导入题库流程', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: QuizSearchTabPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('quiz-search-guide')));
    await tester.pumpAndSettle();
    expect(find.byType(QuizSearchGuidePage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quiz-guide-import-bank')),
      findsOneWidget,
    );
    expect(find.text('导入题库（详细步骤）'), findsOneWidget);
    expect(find.text('题库长什么样'), findsOneWidget);
    expect(find.text('方式一：内置 AI 导入'), findsOneWidget);
    expect(find.text('方式二：交给其他 AI'), findsOneWidget);
    expect(find.text('把题库文件放进存储空间'), findsOneWidget);
    expect(find.text('可选：设置默认打开工具'), findsOneWidget);
    expect(find.text('在刷题助手里导入'), findsOneWidget);
    expect(find.textContaining('version、bankName'), findsOneWidget);
    expect(find.textContaining('.xlsx：每行一题'), findsOneWidget);
    // 导入题库章节排在使用前准备之前（章节很长，按 children 顺序断言，
    // 不依赖两块同时在视口里）。
    final children = (tester
            .widget<ListView>(find.byType(ListView))
            .childrenDelegate as SliverChildListDelegate)
        .children;
    final importIndex = children
        .indexWhere((w) => w.key == const ValueKey('quiz-guide-import-bank'));
    final prepIndex = children.indexWhere(
      (w) => w is SectionCard && w.title == '使用前准备',
    );
    expect(importIndex, 0);
    expect(prepIndex, greaterThan(importIndex));
  });

  testWidgets('来回切换后刷题首页仍在树里，状态不被销毁', (tester) async {
    QuizServices.testRepo = await openShellRepo();
    await tester.pumpWidget(
      const MaterialApp(home: QuizScope(child: QuizShell())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quiz-tab-search')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quiz-tab-practice')));
    await tester.pumpAndSettle();

    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    expect(find.byType(QuizPage), findsOneWidget);
    // 未选中的子页被 PageView 的 keep-alive 保留在树里，状态不销毁。
    expect(find.byType(QuizSearchTabPage, skipOffstage: false), findsOneWidget);
  });

  testWidgets('左右滑动在刷题与搜题之间切换', (tester) async {
    QuizServices.testRepo = await openShellRepo();
    await tester.pumpWidget(
      const MaterialApp(home: QuizScope(child: QuizShell())),
    );
    await tester.pumpAndSettle();

    final pager = find.byKey(const ValueKey('quiz-pager'));
    expect(pager, findsOneWidget);

    // 左滑 → 搜题；底部导航同步高亮。
    await tester.drag(pager, const Offset(-520, 0));
    await tester.pumpAndSettle();
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1);
    expect(find.byKey(const ValueKey('quiz-search-photo')), findsOneWidget);

    // 右滑 → 回刷题。
    await tester.drag(pager, const Offset(520, 0));
    await tester.pumpAndSettle();
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    expect(find.byKey(const ValueKey('quiz-search-photo')), findsNothing);
  });
}
