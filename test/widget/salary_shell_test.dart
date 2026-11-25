import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/salary/salary_page.dart';
import 'package:toolbox/features/tools/salary/salary_settings.dart';

import '../support/test_env.dart';

void main() {
  installCleanEnv();

  setUp(SalarySettings.resetForTest);

  testWidgets('工资计算器顶部三个页签可切换，房贷页能打开', (tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const MaterialApp(home: SalaryPage()));
    await tester.pumpAndSettle();

    // 默认停在「到手工资」，输入卡在；标题固定为工具名，不跟随页签。
    expect(find.text('工资与基数'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('salary-calculator-scroll')), findsOneWidget);
    expect(_titleOf(tester), '工资计算器');

    // 第二个页签：统计（嵌入式，没有自己的 AppBar）。
    await tester.tap(find.byKey(const ValueKey('salary-tab-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('salary-stats-add')), findsOneWidget);
    expect(find.text('平均'), findsNothing);
    expect(_titleOf(tester), '工资计算器');

    // 第三个页签：房贷。
    await tester.tap(find.byKey(const ValueKey('salary-tab-2')));
    await tester.pumpAndSettle();
    expect(find.text('贷款信息'), findsOneWidget);
    expect(find.byKey(const ValueKey('mortgage-monthly')), findsOneWidget);
    expect(_titleOf(tester), '工资计算器');

    // 切回第一页，输入状态还在（keepAlive）。
    await tester.tap(find.byKey(const ValueKey('salary-tab-0')));
    await tester.pumpAndSettle();
    expect(find.text('工资与基数'), findsOneWidget);
    expect(_titleOf(tester), '工资计算器');
  });

  testWidgets('页签胶囊上下边缘也能点中', (tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const MaterialApp(home: SalaryPage()));
    await tester.pumpAndSettle();

    final pill = tester.getCenter(find.byKey(const ValueKey('salary-tab-2')));
    // 胶囊高 38，距中心 15px 仍在胶囊内，但已落在图标行之外。
    await tester.tapAt(pill - const Offset(0, 15));
    await tester.pumpAndSettle();
    expect(find.text('贷款信息'), findsOneWidget);

    final first = tester.getCenter(find.byKey(const ValueKey('salary-tab-0')));
    await tester.tapAt(first + const Offset(0, 15));
    await tester.pumpAndSettle();
    expect(find.text('工资与基数'), findsOneWidget);
  });

  testWidgets('工资计算器输入自动缓存，关掉重开后恢复', (tester) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const MaterialApp(home: SalaryPage()));
    await tester.pumpAndSettle();
    // 输入卡默认收起，展开后才能拿到输入框。
    await tester.tap(find.text('工资与基数'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(fields, findsWidgets);
    await tester.enterText(fields.first, '20000');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(fields.first).controller!.text,
      '20000',
    );

    // 销毁页面再重建，模拟退出工具后重新打开。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const MaterialApp(home: SalaryPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工资与基数'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '20000',
    );
  });
}

String _titleOf(WidgetTester tester) {
  final bar = tester.widget<AppBar>(find.byType(AppBar).first);
  return (bar.title! as Text).data!;
}
