import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/app.dart';
import 'package:toolbox/core/settings/app_background.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/core/widgets/app_widgets.dart';
import 'package:toolbox/features/user/settings_tile.dart';
import 'package:toolbox/features/tools/builtin_tools.dart';
import '../support/test_env.dart';

/// 中文本地化下 pageBack 找不到英文 Back 提示，直接点 AppBar 返回按钮。
Future<void> goBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton).first);
  await tester.pumpAndSettle();
}

void main() {
  installCleanEnv();

  testWidgets('手机尺寸下各页可渲染且无溢出', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    registerBuiltinTools();
    await tester.pumpWidget(const ToolboxApp());
    await tester.pumpAndSettle();

    expect(find.text('工资计算器'), findsOneWidget);

    await tester.tap(find.text('工资计算器'));
    await tester.pumpAndSettle();
    expect(find.text('工资与基数'), findsOneWidget);

    // 滚到底部的年度预估，覆盖各分区布局。页面新增养老/税优卡片后
    // 固定滚动次数不够，直接滚到目标出现。
    await tester.dragUntilVisible(
      find.text('年度预估（12 个月）'),
      find.byType(ListView).last,
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(find.text('年度预估（12 个月）'), findsOneWidget);
  });

  testWidgets('计算器结果与口径切换正确', (tester) async {
    // 高视口，便于一次性断言全部内容
    tester.view.physicalSize = const Size(1080, 5200);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    registerBuiltinTools();
    await tester.pumpWidget(const ToolboxApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('工资计算器'));
    await tester.pumpAndSettle();

    expect(find.text('预计到手工资'), findsOneWidget);
    expect(find.text('缴纳明细'), findsOneWidget);

    // 切换为月度估算：12000 - 2700 - 220 = 9,080，且不再显示发放月份
    await tester.tap(find.text('月度估算'));
    await tester.pumpAndSettle();
    expect(find.text('9,080.00'), findsOneWidget);
    expect(find.text('发放月份'), findsNothing);
  });

  testWidgets('用户目录移除个人信息后，工具总览仍可进入各工具', (tester) async {
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    registerBuiltinTools();
    await tester.pumpWidget(const ToolboxApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('用户'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SettingsTile, '个人信息'), findsNothing);
    expect(find.widgetWithText(SettingsTile, 'AI 配置'), findsOneWidget);

    await tester.tap(find.text('工具总览'));
    await tester.pumpAndSettle();
    expect(find.text('工资计算器'), findsOneWidget);
    expect(find.text('自动点击'), findsOneWidget);
  });

  testWidgets('用户页：主题直切、主题色与语言即时生效', (tester) async {
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    registerBuiltinTools();
    await tester.pumpWidget(const ToolboxApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('用户'));
    await tester.pumpAndSettle();

    // 主题分段按钮直切深色（单行：系统/浅色/深色）
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(SettingsController.instance.themeMode, ThemeMode.dark);
    await tester.tap(find.text('系统'));
    await tester.pumpAndSettle();

    // 主题色
    await tester.tap(find.widgetWithText(SettingsTile, '主题色'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深海蓝'));
    await tester.pumpAndSettle();
    expect(SettingsController.instance.themeColorId, 'deepSeaBlue');

    await goBack(tester);

    // 语言改为 English
    await tester.tap(find.widgetWithText(SettingsTile, '语言'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(SettingsController.instance.language, AppLanguage.english);

    await goBack(tester);
    expect(find.text('Default open tool'), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);
  });

  testWidgets('字体大小可调整且有预览', (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    registerBuiltinTools();
    await tester.pumpWidget(const ToolboxApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('用户'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SettingsTile, '字体大小'));
    await tester.pumpAndSettle();

    expect(find.text('预览'), findsOneWidget);
    expect(find.text('100%'), findsWidgets);

    await tester.drag(find.byType(Slider), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(SettingsController.instance.fontScale, greaterThan(1.0));
  });

  testWidgets('背景：选择纯色后生效', (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    registerBuiltinTools();
    await tester.pumpWidget(const ToolboxApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('用户'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SettingsTile, '背景'));
    await tester.pumpAndSettle();

    expect(find.text('纯色背景'), findsOneWidget);
    expect(find.text('渐变背景'), findsOneWidget);
    expect(find.text('自定义图片'), findsOneWidget);

    // 选「晴空蓝」纯色
    await tester.tap(find.byKey(const ValueKey<String>('bg-color-sky')));
    await tester.pumpAndSettle();
    expect(SettingsController.instance.backgroundKind, BackgroundKind.color);
    expect(SettingsController.instance.backgroundColorId, 'sky');

    // 再选一个渐变
    await tester.tap(find.byKey(const ValueKey<String>('bg-gradient-forest')));
    await tester.pumpAndSettle();
    expect(SettingsController.instance.backgroundKind, BackgroundKind.gradient);

    // 关闭背景
    await tester.tap(find.text('无背景'));
    await tester.pumpAndSettle();
    expect(SettingsController.instance.backgroundKind, BackgroundKind.none);
  });

  testWidgets('总览卡片：每个工具的说明恢复为常驻小字', (tester) async {
    registerBuiltinTools();
    await tester.pumpWidget(const ToolboxApp());
    await tester.pumpAndSettle();

    expect(find.text('五险一金、个税与到手工资测算'), findsOneWidget);
    expect(find.text('每日 60 秒新闻简报'), findsOneWidget);
    expect(find.text('工资与基数'), findsNothing);
  });

  testWidgets('说明气泡：与说明主体同一行，不单独占一行', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            Expanded(child: Text('校准偏移')),
            InfoHint(text: '这是一段说明'),
          ],
        ),
      ),
    ));

    final titleCenter = tester.getCenter(find.text('校准偏移'));
    final hintCenter = tester.getCenter(find.byIcon(Icons.info_outline));
    expect((titleCenter.dy - hintCenter.dy).abs(), lessThan(4));
    expect(hintCenter.dx, greaterThan(titleCenter.dx));
  });

  testWidgets('短说明：常驻小字直接显示，不需要点击展开', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SmallHint(text: '重要数据请先备份')),
    ));

    expect(find.text('重要数据请先备份'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsNothing);
  });

  testWidgets('说明气泡：默认只有感叹号，点击后才展开文案', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: InfoHint(text: '这是一段较长的说明文案')),
    ));

    expect(find.text('这是一段较长的说明文案'), findsNothing);
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    expect(find.text('这是一段较长的说明文案'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('这是一段较长的说明文案'), findsNothing);
  });
}
