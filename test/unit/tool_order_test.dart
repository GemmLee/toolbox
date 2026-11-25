import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/core/storage/local_store.dart';
import 'package:toolbox/core/tool_registry.dart';
import 'package:toolbox/features/overview/tool_order_page.dart';
import 'package:toolbox/features/overview/tools_overview_page.dart';
import '../support/test_env.dart';

ToolDefinition _tool(String id) => ToolDefinition(
      id: id,
      name: id,
      description: 'demo',
      icon: Icons.widgets_outlined,
      category: '测试',
      builder: (_) => const SizedBox.shrink(),
    );

List<String> get _ids => ToolRegistry.tools.map((tool) => tool.id).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    mockPrefs();
    await useChineseUi();
    ToolRegistry.resetForTest();
    for (final id in <String>['a', 'b', 'c']) {
      ToolRegistry.register(_tool(id));
    }
    await ToolRegistry.loadOrder();
  });

  tearDown(() {
    ToolRegistry.resetForTest();
    SettingsController.instance.setLanguage(AppLanguage.system);
  });

  test('自定义顺序会持久化，重载后仍保持', () async {
    await ToolRegistry.saveOrder(<String>['c', 'a', 'b']);
    expect(_ids, <String>['c', 'a', 'b']);

    // 模拟重启：先回到注册顺序，再从存储读回自定义顺序
    ToolRegistry.applyOrder(<String>['a', 'b', 'c']);
    expect(_ids, <String>['a', 'b', 'c']);
    await ToolRegistry.loadOrder();
    expect(_ids, <String>['c', 'a', 'b']);
  });

  test('重置顺序恢复注册顺序并清掉持久化记录', () async {
    await ToolRegistry.saveOrder(<String>['b', 'c', 'a']);
    expect(ToolRegistry.isDefaultOrder, isFalse);

    await ToolRegistry.resetOrder();
    expect(_ids, <String>['a', 'b', 'c']);
    expect(ToolRegistry.isDefaultOrder, isTrue);

    // 记录已清空，再次加载不会再改顺序
    await ToolRegistry.loadOrder();
    expect(_ids, <String>['a', 'b', 'c']);
  });

  test('未知 / 缺失的 id 不会丢工具', () async {
    ToolRegistry.applyOrder(<String>['c', 'missing', 'a']);
    expect(_ids, <String>['c', 'a', 'b']);
  });

  test('折叠状态单独持久化，不影响顺序', () async {
    await ToolRegistry.setFolded('b', true);
    expect(ToolRegistry.isFolded('b'), isTrue);
    expect(ToolRegistry.foldedTools.map((tool) => tool.id), <String>['b']);
    expect(ToolRegistry.pinnedTools.map((tool) => tool.id), <String>['a', 'c']);
    expect(_ids, <String>['a', 'b', 'c'], reason: '顺序不该被折叠改动');

    // 模拟重启：清内存后重新注册再读
    ToolRegistry.resetForTest();
    for (final id in <String>['a', 'b', 'c']) {
      ToolRegistry.register(_tool(id));
    }
    expect(ToolRegistry.isFolded('b'), isFalse);
    await ToolRegistry.loadFolded();
    expect(ToolRegistry.isFolded('b'), isTrue);

    await ToolRegistry.setFolded('b', false);
    expect(ToolRegistry.foldedTools, isEmpty);
  });

  test('重置顺序同时清空折叠栏', () async {
    await ToolRegistry.setFolded('a', true);
    await ToolRegistry.resetOrder();
    expect(ToolRegistry.foldedTools, isEmpty);
    await ToolRegistry.loadFolded();
    expect(ToolRegistry.foldedTools, isEmpty);
  });

  test('首次进入默认折叠低频工具，用户显式偏好优先', () async {
    const all = <String>[
      'salary',
      'id_photo',
      'crypto',
      'watermark',
      'chess',
      'typhoon',
      'qrcode',
      'news',
      'measure',
    ];
    ToolRegistry.resetForTest();
    for (final id in all) {
      ToolRegistry.register(_tool(id));
    }

    // 无记录 = 首次进入，套用默认折叠名单。
    await ToolRegistry.loadFolded();
    expect(
      ToolRegistry.foldedTools.map((tool) => tool.id).toList()..sort(),
      <String>[
        'chess',
        'crypto',
        'id_photo',
        'measure',
        'news',
        'qrcode',
        'typhoon',
      ],
    );
    expect(ToolRegistry.isFolded('salary'), isFalse);
    expect(ToolRegistry.isFolded('watermark'), isFalse, reason: '水印不再默认折叠');
    expect(ToolRegistry.isFolded('measure'), isTrue, reason: '测量工具默认折叠');

    // 老用户曾保存含 watermark 的折叠名单：一次性迁移把它放出，且只迁移一次。
    await LocalStore.writeMap('tool_folded', {
      'ids': <String>['watermark', 'chess'],
    });
    await LocalStore.remove('tool_folded_watermark_migrated');
    ToolRegistry.resetForTest();
    for (final id in all) {
      ToolRegistry.register(_tool(id));
    }
    await ToolRegistry.loadFolded();
    expect(ToolRegistry.isFolded('watermark'), isFalse, reason: '迁移后水印被放出');
    expect(ToolRegistry.isFolded('chess'), isTrue);

    // 迁移后用户可再次主动折叠水印，重启后保持。
    await ToolRegistry.setFolded('watermark', true);
    ToolRegistry.resetForTest();
    for (final id in all) {
      ToolRegistry.register(_tool(id));
    }
    await ToolRegistry.loadFolded();
    expect(ToolRegistry.isFolded('watermark'), isTrue,
        reason: '迁移只做一次，之后的显式偏好优先');

    // 用户主动全部移出（存了空列表）后重启，不再套用默认。
    await ToolRegistry.saveFolded(const <String>[]);
    ToolRegistry.resetForTest();
    for (final id in all) {
      ToolRegistry.register(_tool(id));
    }
    await ToolRegistry.loadFolded();
    expect(ToolRegistry.foldedTools, isEmpty);
  });

  test('测量工具改动只迁移一次，之后按用户偏好', () async {
    const all = <String>['salary', 'measure', 'chess', 'watermark'];
    ToolRegistry.resetForTest();
    for (final id in all) {
      ToolRegistry.register(_tool(id));
    }
    // 老用户的偏好里没有 measure：升级后一次性收进折叠栏。
    await LocalStore.writeMap('tool_folded', {
      'ids': <String>['chess'],
    });
    await ToolRegistry.loadFolded();
    expect(ToolRegistry.isFolded('measure'), isTrue);
    expect(ToolRegistry.isFolded('chess'), isTrue);

    // 迁移后用户主动放出测量工具，重启后仍保持。
    await ToolRegistry.setFolded('measure', false);
    ToolRegistry.resetForTest();
    for (final id in all) {
      ToolRegistry.register(_tool(id));
    }
    await ToolRegistry.loadFolded();
    expect(ToolRegistry.isFolded('measure'), isFalse);
  });

  testWidgets('排序页可以把工具收进 / 移出折叠栏', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ToolOrderPage()));
    await tester.pumpAndSettle();

    expect(find.text('折叠工具栏'), findsOneWidget);
    expect(find.text('把工具拖到这里，就收进折叠工具栏'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tool-order-fold-b')));
    await tester.pumpAndSettle();

    expect(ToolRegistry.isFolded('b'), isTrue);
    expect(find.text('把工具拖到这里，就收进折叠工具栏'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tool-order-fold-b')));
    await tester.pumpAndSettle();
    expect(ToolRegistry.isFolded('b'), isFalse);
  });

  testWidgets('总览页折叠栏默认收起，点开展示其中的工具', (tester) async {
    await ToolRegistry.setFolded('b', true);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ToolsOverviewPage())),
    );
    await tester.pumpAndSettle();

    expect(find.text('折叠工具栏'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('b'), findsNothing, reason: '收起时不占网格');

    await tester.tap(find.byKey(const ValueKey('overview-folded-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('排序页展示当前顺序，重置按钮生效', (tester) async {
    await ToolRegistry.saveOrder(<String>['c', 'b', 'a']);
    await tester.pumpWidget(const MaterialApp(home: ToolOrderPage()));
    await tester.pumpAndSettle();

    expect(find.text('c'), findsOneWidget);
    expect(find.text('a'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tool-order-reset')));
    // 用固定时长推进：pumpAndSettle 会一直推进到 SnackBar 自动消失。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(_ids, <String>['a', 'b', 'c']);
    expect(find.text('已恢复默认顺序'), findsOneWidget);
  });
}
