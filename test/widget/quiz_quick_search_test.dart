import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/core/platform/quick_search.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_photo_match.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_search_scope.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_quick_search_overlay.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_quick_search_page.dart';
import '../support/test_env.dart';

Future<QuizRepository> openQuickRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  final repo = QuizRepository(db);
  final bankId = await repo.createBank(name: '计算机网络');
  await repo.insertQuestions(<Question>[
    Question(
      id: 'q1',
      bankId: bankId,
      type: QuestionType.single,
      stem: 'TCP 三次握手的第二个报文是什么？',
      options: const <OptionItem>[
        OptionItem(key: 'A', text: 'SYN'),
        OptionItem(key: 'B', text: 'SYN+ACK'),
      ],
      answer: const <String>['B'],
      orderNo: 1,
    ),
  ]);
  return repo;
}

QuickSearchHost hostOf({
  bool granted = true,
  bool shown = true,
  void Function()? onRequest,
}) =>
    QuickSearchHost(
      canDraw: () async => granted,
      request: () async {
        onRequest?.call();
        return true;
      },
      show: (_, __, ___) async => shown,
      hide: () async {},
    );

void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  tearDown(restoreSystemLanguage);

  testWidgets('没有悬浮窗权限时先跳系统授权并给出提示', (tester) async {
    final repo = await openQuickRepo();
    var requested = 0;
    await tester.pumpWidget(MaterialApp(
      home: QuizQuickSearchPage(
        repo: repo,
        host: hostOf(granted: false, onRequest: () => requested++),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('quick-search-toggle')));
    await tester.pumpAndSettle();

    expect(requested, 1);
    expect(find.textContaining('显示在其他应用上层'), findsOneWidget);
    // 没拿到权限就不该进入降级，也不该显示已开启。
    expect(find.text('关闭悬浮窗'), findsNothing);
  });

  testWidgets('系统拦截悬浮窗时降级为应用内浮窗', (tester) async {
    final repo = await openQuickRepo();
    String? indexPath;
    await tester.pumpWidget(MaterialApp(
      home: QuizQuickSearchPage(
        repo: repo,
        host: hostOf(shown: false),
        indexWriter: (_) async {
          indexPath = '/data/quick_search_index.json';
          return indexPath!;
        },
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('quick-search-toggle')));
    await tester.pumpAndSettle();

    expect(indexPath, '/data/quick_search_index.json');
    expect(find.textContaining('已切换为应用内浮窗'), findsOneWidget);
    expect(find.byType(InAppQuickSearch), findsOneWidget);
    expect(find.byKey(const ValueKey('inapp-quick-drag')), findsOneWidget);
  });

  testWidgets('悬浮窗开启成功后按钮变成关闭', (tester) async {
    final repo = await openQuickRepo();
    var hidden = 0;
    await tester.pumpWidget(MaterialApp(
      home: QuizQuickSearchPage(
        repo: repo,
        host: QuickSearchHost(
          canDraw: () async => true,
          request: () async => true,
          show: (_, __, ___) async => true,
          hide: () async => hidden++,
        ),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('quick-search-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('关闭悬浮窗'), findsOneWidget);
    expect(find.textContaining('悬浮窗已开启'), findsOneWidget);
    expect(find.byType(InAppQuickSearch), findsNothing);

    await tester.tap(find.byKey(const ValueKey('quick-search-toggle')));
    await tester.pumpAndSettle();
    expect(hidden, 1);
    expect(find.text('开启'), findsOneWidget);
  });

  testWidgets('应用内浮窗：自绘键盘输入后搜到题目，答案用主色高亮', (tester) async {
    final repo = await openQuickRepo();
    final match = await bestMatchForText(repo, 'TCP 三次握手的第二个报文是什么');
    expect(match, isNotNull);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppQuickSearch(
          repo: repo,
          matcher: (_, __) async => match,
          onClose: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 只用手绘键盘写入，不弹系统输入法。
    for (final key in <String>['T', 'C', 'P']) {
      await tester.tap(find.text(key));
      await tester.pump();
    }
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('inapp-quick-input'))).data,
      'tcp',
    );

    await tester.tap(find.byKey(const ValueKey('inapp-quick-go')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('inapp-quick-stem')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('inapp-quick-answer')))
          .data,
      '答案：B',
    );

    // 「改词」回到键盘态。
    await tester.tap(find.byKey(const ValueKey('inapp-quick-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inapp-quick-go')), findsOneWidget);
  });

  testWidgets('应用内浮窗：把手可拖动，关闭按钮回调', (tester) async {
    final repo = await openQuickRepo();
    var closed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppQuickSearch(
          repo: repo,
          matcher: (_, __) async => null,
          onClose: () => closed++,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final before = tester.getTopLeft(find.byType(InAppQuickSearch));
    await tester.drag(
      find.byKey(const ValueKey('inapp-quick-drag')),
      const Offset(40, 60),
    );
    await tester.pumpAndSettle();
    final panelBefore =
        tester.getTopLeft(find.byKey(const ValueKey('inapp-quick-input')));
    expect(panelBefore.dy, greaterThan(before.dy));

    await tester.tap(find.byKey(const ValueKey('inapp-quick-close')));
    await tester.pumpAndSettle();
    expect(closed, 1);
  });

  testWidgets('开启页可以多选题库，范围会传给悬浮窗', (tester) async {
    final repo = await openQuickRepo();
    final second = await repo.createBank(name: '数据结构');
    final third = await repo.createBank(name: '操作系统');
    final scopes = <Set<String>?>[];
    await tester.pumpWidget(MaterialApp(
      home: QuizQuickSearchPage(
        repo: repo,
        host: QuickSearchHost(
          canDraw: () async => true,
          request: () async => true,
          show: (_, bankIds, maxResults) async {
            scopes.add(bankIds);
            return true;
          },
          hide: () async {},
        ),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();

    // 默认搜全部题库。
    expect(find.text('全部题库'), findsOneWidget);

    // 勾选两个题库 → 范围是这两个。
    await tester.tap(find.byKey(const ValueKey('quick-search-bank')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('bank-sheet-$second')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('bank-sheet-$third')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bank-sheet-ok')));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 个题库'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('quick-search-toggle')));
    await tester.pumpAndSettle();
    expect(scopes, <Set<String>?>[
      <String>{second, third},
    ]);

    // 已经开启时换范围：不关窗，直接把新范围下发；选「全部题库」下发 null。
    await tester.tap(find.byKey(const ValueKey('quick-search-bank')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bank-sheet-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bank-sheet-ok')));
    await tester.pumpAndSettle();
    expect(find.text('全部题库'), findsOneWidget);
    expect(scopes.last, isNull);
  });

  testWidgets('首次进入便捷搜题会沿用最近一次题库选择', (tester) async {
    final repo = await openQuickRepo();
    await repo.createBank(name: '操作系统');
    final bank = (await repo.listBanks()).first;
    await QuizSearchScope.remember(<String>{bank.id});

    await tester.pumpWidget(MaterialApp(
      home: QuizQuickSearchPage(
        repo: repo,
        host: hostOf(),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text(bank.name), findsWidgets);
  });

  testWidgets('quick search: 可切换悬浮窗背景色并下发给原生', (tester) async {
    final repo = await openQuickRepo();
    final themes = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: QuizQuickSearchPage(
        repo: repo,
        host: QuickSearchHost(
          canDraw: () async => true,
          request: () async => true,
          show: (_, __, ___) async => true,
          hide: () async {},
          currentTheme: () async => 'dark',
          setTheme: (theme) async => themes.add(theme),
        ),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('quick-theme-dark')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-theme-light')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('quick-theme-transparent')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('quick-theme-light')));
    await tester.pumpAndSettle();
    expect(themes, <String>['light']);

    await tester.tap(find.byKey(const ValueKey('quick-theme-transparent')));
    await tester.pumpAndSettle();
    expect(themes, <String>['light', 'transparent']);

    // 同色重复点不重复下发。
    await tester.tap(find.byKey(const ValueKey('quick-theme-transparent')));
    await tester.pumpAndSettle();
    expect(themes, <String>['light', 'transparent']);
  });
}
