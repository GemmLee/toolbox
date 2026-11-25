import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/salary/salary_tab_switch.dart';

void main() {
  Future<void> pumpSwitch(WidgetTester tester, {int index = 0}) async {
    var current = index;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: <Widget>[
                SalaryTabSwitch(
                  items: const <SalaryTabItem>[
                    SalaryTabItem(icon: Icons.payments_outlined, label: '到手工资'),
                    SalaryTabItem(
                        icon: Icons.show_chart_outlined, label: '工资统计'),
                    SalaryTabItem(icon: Icons.home_outlined, label: '房贷计算'),
                  ],
                  index: current,
                  onChanged: (value) => setState(() => current = value),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Size pillSize(WidgetTester tester, int i) =>
      tester.getSize(find.byKey(ValueKey('salary-tab-$i')));

  testWidgets('选中项比未选中项长，未选中是等宽圆球', (tester) async {
    await pumpSwitch(tester);

    final selected = pillSize(tester, 0);
    final other = pillSize(tester, 1);
    expect(selected.width, greaterThan(other.width * 3));
    expect(other.width, other.height);
    expect(pillSize(tester, 2).width, other.width);
  });

  testWidgets('切换时宽度是渐变的，最终选中项接替变长', (tester) async {
    await pumpSwitch(tester);
    // 展开宽度按文案实测，不同字体/字号下不一样，测试里现取。
    final expanded = pillSize(tester, 0).width;
    const collapsed = 38.0;

    await tester.tap(find.byKey(const ValueKey('salary-tab-1')));
    // 动画中途：两个胶囊都停在中间态，没有瞬间跳变。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final midOld = pillSize(tester, 0).width;
    final midNew = pillSize(tester, 1).width;
    expect(midOld, lessThan(expanded));
    expect(midOld, greaterThan(collapsed));
    expect(midNew, greaterThan(collapsed));
    expect(midNew, lessThan(expanded));

    await tester.pumpAndSettle();
    expect(pillSize(tester, 0).width, collapsed);
    expect(pillSize(tester, 1).width, expanded);
  });

  testWidgets('切换全程总宽度不变，选中态从旧位置粘到新位置', (tester) async {
    await pumpSwitch(tester);
    double total() =>
        pillSize(tester, 0).width +
        pillSize(tester, 1).width +
        pillSize(tester, 2).width;
    final before = total();

    await tester.tap(find.byKey(const ValueKey('salary-tab-2')));
    for (var step = 0; step < 6; step++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(total(), closeTo(before, 0.5));
    }
    await tester.pumpAndSettle();
    expect(total(), closeTo(before, 0.5));
    expect(
        pillSize(tester, 2).width, greaterThan(pillSize(tester, 0).width * 3));
  });

  testWidgets('切换途中出现液桥，静止时无液桥', (tester) async {
    await pumpSwitch(tester);
    expect(find.byKey(const ValueKey('salary-liquid-bridge')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('salary-tab-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 两颗胶囊都占一半权重时画出粘连的液桥。
    expect(find.byKey(const ValueKey('salary-liquid-bridge')), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('salary-liquid-bridge')), findsNothing);
  });

  testWidgets('窄屏加大字号也不会溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: Scaffold(
            body: Center(
              child: SalaryTabSwitch(
                items: <SalaryTabItem>[
                  SalaryTabItem(icon: Icons.payments_outlined, label: '到手工资'),
                  SalaryTabItem(icon: Icons.show_chart_outlined, label: '工资统计'),
                  SalaryTabItem(icon: Icons.home_outlined, label: '房贷计算'),
                ],
                index: 0,
                onChanged: _noop,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

void _noop(int _) {}
