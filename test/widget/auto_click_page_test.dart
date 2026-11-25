import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/platform/auto_click.dart';
import 'package:toolbox/features/tools/autoclick/auto_click_models.dart';
import 'package:toolbox/features/tools/autoclick/auto_click_page.dart';

import '../support/test_env.dart';

void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  installCleanEnv();

  testWidgets('权限、动作序列与启停全部可操作', (tester) async {
    _bigScreen(tester);
    var config = AutoClickConfig.defaults();
    final started = <Map<String, dynamic>>[];
    var stopped = false;
    final host = AutoClickHost(
      canDraw: () async => true,
      requestOverlay: () async => true,
      accessibility: () async => true,
      openSettings: () async => true,
      start: (value) async {
        started.add(value);
        return true;
      },
      stop: () async => stopped = true,
      isRunning: () async => false,
      listenPoints: (_) {},
    );

    await tester.pumpWidget(MaterialApp(
      home: AutoClickPage(
        host: host,
        loader: () async => config,
        saver: (value) async => config = value,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('自动点击'), findsOneWidget);
    expect(find.text('悬浮窗'), findsOneWidget);
    expect(find.text('无障碍'), findsOneWidget);
    // 两项权限都已就绪时不出现「去开启」。
    expect(find.text('去开启'), findsNothing);
    expect(find.text('动作序列（1）'), findsOneWidget);

    // 添加一个滑动动作。
    await tester.tap(find.byKey(const ValueKey('auto-click-add')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('auto-click-type-swipe')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('auto-click-sheet-x2')),
      '80',
    );
    await tester.tap(
      find.byKey(const ValueKey('auto-click-sheet-save')),
    );
    await tester.pumpAndSettle();

    expect(find.text('动作序列（2）'), findsOneWidget);
    expect(find.text('滑动'), findsOneWidget);
    expect(config.actions.last.type, AutoClickActionType.swipe);
    expect(config.actions.last.x2, 80);

    // 启动把整份配置交给原生，并切换成停止按钮。
    await tester.tap(find.byKey(const ValueKey('auto-click-start')));
    await tester.pumpAndSettle();
    expect(started, hasLength(1));
    expect(started.single['actions'], hasLength(2));
    expect(
      find.byKey(const ValueKey('auto-click-stop')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('auto-click-stop')));
    await tester.pumpAndSettle();
    expect(stopped, isTrue);
    expect(
      find.byKey(const ValueKey('auto-click-start')),
      findsOneWidget,
    );
  });

  testWidgets('缺权限时引导开启，且不会下发空动作序列', (tester) async {
    _bigScreen(tester);
    var requested = 0;
    var starts = 0;
    final host = AutoClickHost(
      canDraw: () async => false,
      requestOverlay: () async {
        requested++;
        return true;
      },
      accessibility: () async => false,
      openSettings: () async => true,
      start: (_) async {
        starts++;
        return true;
      },
      stop: () async {},
      isRunning: () async => false,
      listenPoints: (_) {},
    );
    await tester.pumpWidget(MaterialApp(
      home: AutoClickPage(
        host: host,
        loader: () async => AutoClickConfig.defaults(),
        saver: (_) async {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('去开启'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('auto-click-start')));
    await tester.pumpAndSettle();
    // 悬浮窗权限没拿到时只做引导，不下发动作。
    expect(starts, 0);
    expect(requested, 1);
  });

  testWidgets('悬浮面板取点后自动追加一个点击动作并落盘', (tester) async {
    _bigScreen(tester);
    var config = AutoClickConfig.defaults();
    AutoClickConfig? saved;
    var pushed = 0;
    void Function(double x, double y)? pick;
    final host = AutoClickHost(
      canDraw: () async => true,
      requestOverlay: () async => true,
      accessibility: () async => true,
      openSettings: () async => true,
      start: (_) async => true,
      stop: () async {},
      isRunning: () async => false,
      updateConfig: (_) async {
        pushed++;
        return true;
      },
      listenPoints: (listener) => pick = listener,
    );

    await tester.pumpWidget(MaterialApp(
      home: AutoClickPage(
        host: host,
        loader: () async => config,
        saver: (value) async {
          config = value;
          saved = value;
        },
      ),
    ));
    await tester.pumpAndSettle();

    // 原生侧把取到的百分比回传过来。
    expect(pick, isNotNull);
    pick!.call(42.0, 63.5);
    await tester.pumpAndSettle();

    expect(config.actions, hasLength(2));
    final added = config.actions.last;
    expect(added.type, AutoClickActionType.tap);
    expect(added.x, 42.0);
    expect(added.y, 63.5);
    expect(saved?.actions, hasLength(2));
    // 页面还没启动面板，不该把配置推给原生。
    expect(pushed, 0);
    expect(find.textContaining('已添加点击动作'), findsOneWidget);
  });
}
