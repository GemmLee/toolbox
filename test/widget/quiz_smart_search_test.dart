import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/core/platform/smart_search.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_smart_search_page.dart';
import '../support/test_env.dart';

Future<QuizRepository> openSmartRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

SmartSearchHost hostOf({
  bool overlay = true,
  bool accessibility = true,
  bool shown = true,
  void Function()? onRequestOverlay,
  void Function()? onOpenSettings,
  void Function(String path)? onShow,
  void Function(String theme)? onSetTheme,
}) =>
    SmartSearchHost(
      canDraw: () async => overlay,
      requestOverlay: () async {
        onRequestOverlay?.call();
        return true;
      },
      accessibility: () async => accessibility,
      openSettings: () async {
        onOpenSettings?.call();
        return true;
      },
      show: (path, maxResults) async {
        onShow?.call(path);
        return shown;
      },
      hide: () async {},
      currentTheme: () async => 'dark',
      setTheme: (theme) async => onSetTheme?.call(theme),
    );

void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  tearDown(restoreSystemLanguage);

  testWidgets('没有悬浮窗权限时跳系统授权并提示，不启动', (tester) async {
    final repo = await openSmartRepo();
    var requested = 0;
    var shown = 0;
    await tester.pumpWidget(MaterialApp(
      home: QuizSmartSearchPage(
        repo: repo,
        host: hostOf(
          overlay: false,
          onRequestOverlay: () => requested++,
          onShow: (_) => shown++,
        ),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();

    await tester
        .ensureVisible(find.byKey(const ValueKey('smart-search-toggle')));
    await tester.tap(find.byKey(const ValueKey('smart-search-toggle')));
    await tester.pumpAndSettle();

    expect(requested, 1);
    expect(shown, 0);
    expect(find.textContaining('请在系统设置里打开'), findsOneWidget);
    expect(find.text('关闭悬浮窗'), findsNothing);
  });

  testWidgets('有悬浮窗但没开无障碍时跳无障碍设置并提示', (tester) async {
    final repo = await openSmartRepo();
    var opened = 0;
    var shown = 0;
    await tester.pumpWidget(MaterialApp(
      home: QuizSmartSearchPage(
        repo: repo,
        host: hostOf(
          accessibility: false,
          onOpenSettings: () => opened++,
          onShow: (_) => shown++,
        ),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();

    await tester
        .ensureVisible(find.byKey(const ValueKey('smart-search-toggle')));
    await tester.tap(find.byKey(const ValueKey('smart-search-toggle')));
    await tester.pumpAndSettle();

    expect(opened, 1);
    expect(shown, 0);
    expect(find.textContaining('无障碍'), findsWidgets);
  });

  testWidgets('两项授权齐全后启动悬浮窗，按钮变关闭', (tester) async {
    final repo = await openSmartRepo();
    String? indexPath;
    var hidden = 0;
    await tester.pumpWidget(MaterialApp(
      home: QuizSmartSearchPage(
        repo: repo,
        host: SmartSearchHost(
          canDraw: () async => true,
          requestOverlay: () async => true,
          accessibility: () async => true,
          openSettings: () async => true,
          show: (path, maxResults) async {
            indexPath = path;
            return true;
          },
          hide: () async => hidden++,
        ),
        indexWriter: (_) async => '/data/quick_search_index.json',
      ),
    ));
    await tester.pumpAndSettle();

    await tester
        .ensureVisible(find.byKey(const ValueKey('smart-search-toggle')));
    await tester.tap(find.byKey(const ValueKey('smart-search-toggle')));
    await tester.pumpAndSettle();

    expect(indexPath, '/data/quick_search_index.json');
    expect(find.text('关闭悬浮窗'), findsOneWidget);
    expect(find.textContaining('点左上角框选题干'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('smart-search-toggle')));
    await tester.pumpAndSettle();
    expect(hidden, 1);
    expect(find.text('开启'), findsOneWidget);
  });

  testWidgets('系统拦截悬浮窗时给出可操作提示', (tester) async {
    final repo = await openSmartRepo();
    await tester.pumpWidget(MaterialApp(
      home: QuizSmartSearchPage(
        repo: repo,
        host: hostOf(shown: false),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();

    await tester
        .ensureVisible(find.byKey(const ValueKey('smart-search-toggle')));
    await tester.tap(find.byKey(const ValueKey('smart-search-toggle')));
    await tester.pumpAndSettle();

    expect(find.textContaining('系统拦截了悬浮窗'), findsOneWidget);
    expect(find.text('关闭悬浮窗'), findsNothing);
  });

  testWidgets('每次显示数默认 3，开启后调整会重新下发给悬浮窗', (tester) async {
    final repo = await openSmartRepo();
    final limits = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: QuizSmartSearchPage(
        repo: repo,
        host: SmartSearchHost(
          canDraw: () async => true,
          requestOverlay: () async => true,
          accessibility: () async => true,
          openSettings: () async => true,
          show: (path, maxResults) async {
            limits.add(maxResults);
            return true;
          },
          hide: () async {},
        ),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('smart-search-max'));
    expect(tester.widget<TextField>(field).controller!.text, '3');

    await tester
        .ensureVisible(find.byKey(const ValueKey('smart-search-toggle')));
    await tester.tap(find.byKey(const ValueKey('smart-search-toggle')));
    await tester.pumpAndSettle();
    expect(limits, <int>[3]);

    await tester
        .ensureVisible(find.byKey(const ValueKey('smart-search-max-plus')));
    await tester.tap(find.byKey(const ValueKey('smart-search-max-plus')));
    await tester.pumpAndSettle();
    expect(limits, <int>[3, 4]);
  });

  testWidgets('多个题库时可选搜索范围，选中后显示名称并持久化', (tester) async {
    final repo = await openSmartRepo();
    final second = await repo.createBank(name: '数据结构');
    final third = await repo.createBank(name: '操作系统');
    await tester.pumpWidget(MaterialApp(
      home: QuizSmartSearchPage(
        repo: repo,
        host: hostOf(),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();

    // 默认全部题库，范围卡在有两个以上题库时出现。
    expect(find.byKey(const ValueKey('smart-search-bank')), findsOneWidget);
    expect(find.text('全部题库'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('smart-search-bank')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('bank-sheet-$second')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('bank-sheet-$third')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bank-sheet-ok')));
    await tester.pumpAndSettle();

    expect(find.text('已选 2 个题库'), findsOneWidget);

    // 重建页面后仍保留刚才的范围，不用再选一遍。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(MaterialApp(
      home: QuizSmartSearchPage(
        repo: repo,
        host: hostOf(),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 个题库'), findsOneWidget);
  });

  testWidgets('smart search: 可切换悬浮窗背景色并下发给原生', (tester) async {
    final repo = await openSmartRepo();
    final themes = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: QuizSmartSearchPage(
        repo: repo,
        host: hostOf(onSetTheme: themes.add),
        indexWriter: (_) async => '/tmp/index.json',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('smart-theme-dark')), findsOneWidget);
    expect(find.byKey(const ValueKey('smart-theme-light')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('smart-theme-transparent')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('smart-theme-transparent')));
    await tester.pumpAndSettle();
    expect(themes, <String>['transparent']);
  });
}
