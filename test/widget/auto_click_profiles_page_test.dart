import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/platform/auto_click.dart';
import 'package:toolbox/features/tools/autoclick/auto_click_models.dart';
import 'package:toolbox/features/tools/autoclick/auto_click_page.dart';
import 'package:toolbox/features/tools/autoclick/auto_click_profiles.dart';

import '../support/test_env.dart';

void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
}

AutoClickHost _host() => AutoClickHost(
      canDraw: () async => true,
      requestOverlay: () async => true,
      accessibility: () async => true,
      openSettings: () async => true,
      start: (_) async => true,
      stop: () async {},
      isRunning: () async => false,
      listenPoints: (_) {},
    );

AutoClickProfile _profile(String id, String name, int interval) =>
    AutoClickProfile(
      id: id,
      name: name,
      updatedAt: 3,
      config: AutoClickConfig(
        intervalMs: interval,
        actions: <AutoClickAction>[
          AutoClickAction(id: 'a$id', x: 30, y: 40),
        ],
      ),
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<AutoClickProfile> profiles,
  required String activeId,
  required List<AutoClickProfile> Function(List<AutoClickProfile>, String) onSave,
  Future<String?> Function(String, String)? exporter,
  Future<String?> Function()? importer,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: AutoClickPage(
      host: _host(),
      profilesLoader: () async => List<AutoClickProfile>.from(profiles),
      activeIdLoader: (_) async => activeId,
      profilesSaver: (list, id) async => onSave(list, id),
      exporter: exporter,
      importer: importer,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  installCleanEnv();

  testWidgets('方案条展示当前方案，可下拉切换到另一套（配置随之更新）', (tester) async {
    _bigScreen(tester);
    var profiles = <AutoClickProfile>[
      _profile('a', '方案甲', 300),
      _profile('b', '方案乙', 900),
    ];
    String active = 'a';
    List<String> savedActive = const <String>[];
    await _pump(
      tester,
      profiles: profiles,
      activeId: active,
      onSave: (list, id) {
        profiles = list;
        savedActive = <String>[id];
        return list;
      },
    );

    expect(find.text('动作方案'), findsOneWidget);
    expect(find.text('方案甲'), findsOneWidget);
    // 当前方案甲的间隔 300 填进控制器。
    expect(find.text('300'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('auto-click-profile-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('auto-click-profile-item-b')));
    await tester.pumpAndSettle();

    expect(find.text('方案乙'), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
    expect(savedActive, <String>['b']);
    expect(find.textContaining('已切换到方案'), findsOneWidget);
  });

  testWidgets('另存为新建方案并成为当前方案', (tester) async {
    _bigScreen(tester);
    var profiles = <AutoClickProfile>[_profile('a', '方案甲', 300)];
    await _pump(
      tester,
      profiles: profiles,
      activeId: 'a',
      onSave: (list, id) {
        profiles = list;
        return list;
      },
    );

    await tester.tap(find.byKey(const ValueKey('auto-click-profile-save-as')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('auto-click-name-field')),
      '签到脚本',
    );
    await tester.tap(find.byKey(const ValueKey('auto-click-name-confirm')));
    await tester.pumpAndSettle();

    expect(profiles, hasLength(2));
    expect(profiles.first.name, '签到脚本');
    expect(find.text('签到脚本'), findsOneWidget);
    expect(find.textContaining('已保存方案'), findsOneWidget);
  });

  testWidgets('重命名方案后下拉项更新', (tester) async {
    _bigScreen(tester);
    var profiles = <AutoClickProfile>[_profile('a', '旧名字', 300)];
    await _pump(
      tester,
      profiles: profiles,
      activeId: 'a',
      onSave: (list, id) {
        profiles = list;
        return list;
      },
    );

    await tester.tap(find.byKey(const ValueKey('auto-click-profile-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('auto-click-name-field')),
      '新名字',
    );
    await tester.tap(find.byKey(const ValueKey('auto-click-name-confirm')));
    await tester.pumpAndSettle();

    expect(profiles.single.name, '新名字');
    expect(find.text('新名字'), findsOneWidget);
    expect(find.textContaining('已重命名为'), findsOneWidget);
  });

  testWidgets('只有一套方案时删除按钮禁用', (tester) async {
    _bigScreen(tester);
    await _pump(
      tester,
      profiles: <AutoClickProfile>[_profile('a', '方案甲', 300)],
      activeId: 'a',
      onSave: (list, id) => list,
    );
    final delete = tester.widget<IconButton>(
      find.byKey(const ValueKey('auto-click-profile-delete')),
    );
    expect(delete.onPressed, isNull);
  });

  testWidgets('删除确认后移除方案并切到剩下的一套', (tester) async {
    _bigScreen(tester);
    var profiles = <AutoClickProfile>[
      _profile('a', '方案甲', 300),
      _profile('b', '方案乙', 900),
    ];
    await _pump(
      tester,
      profiles: profiles,
      activeId: 'a',
      onSave: (list, id) {
        profiles = list;
        return list;
      },
    );

    await tester.tap(find.byKey(const ValueKey('auto-click-profile-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('auto-click-delete-confirm')));
    await tester.pumpAndSettle();

    expect(profiles, hasLength(1));
    expect(profiles.single.name, '方案乙');
    expect(find.text('方案乙'), findsOneWidget);
    expect(find.textContaining('已删除'), findsOneWidget);
  });

  testWidgets('导出按钮把全部方案 JSON 交给导出器并提示路径', (tester) async {
    _bigScreen(tester);
    String? exportedJson;
    String? exportedName;
    await _pump(
      tester,
      profiles: <AutoClickProfile>[_profile('a', '方案甲', 300)],
      activeId: 'a',
      onSave: (list, id) => list,
      exporter: (json, name) async {
        exportedJson = json;
        exportedName = name;
        return '/ Download/方案.json';
      },
    );

    await tester.tap(find.byKey(const ValueKey('auto-click-export')));
    await tester.pumpAndSettle();

    expect(exportedJson, contains('方案甲'));
    expect(exportedName, endsWith('.json'));
    expect(find.textContaining('方案已导出'), findsOneWidget);
  });

  testWidgets('导入按钮合并方案并提示导入数量', (tester) async {
    _bigScreen(tester);
    var profiles = <AutoClickProfile>[_profile('a', '本机方案', 300)];
    final incoming = AutoClickProfileStore.exportJson(
      <AutoClickProfile>[_profile('imp', '导入方案', 500)],
      'imp',
    );
    await _pump(
      tester,
      profiles: profiles,
      activeId: 'a',
      onSave: (list, id) {
        profiles = list;
        return list;
      },
      importer: () async => incoming,
    );

    await tester.tap(find.byKey(const ValueKey('auto-click-import')));
    await tester.pumpAndSettle();

    expect(profiles, hasLength(2));
    expect(profiles.map((p) => p.name), contains('导入方案'));
    expect(find.textContaining('已导入'), findsOneWidget);
  });
}
