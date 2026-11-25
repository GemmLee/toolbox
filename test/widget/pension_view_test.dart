import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/profile/profile_basic_page.dart';
import 'package:toolbox/features/profile/profile_model.dart';
import 'package:toolbox/features/profile/profile_repository.dart';
import 'package:toolbox/features/user/profile_hub_page.dart';
import 'package:toolbox/features/profile/profile_pension_page.dart';
import 'package:toolbox/features/tools/salary/salary_page.dart';

import '../support/test_env.dart';

void main() {
  installCleanEnv();

  testWidgets('工资计算器展示养老金测算与税优两张卡', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SalaryPage()));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('养老金领取测算'),
      400,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('salary-calculator-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('养老金领取测算'), findsOneWidget);
    expect(find.byKey(const ValueKey('pension-monthly')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('个人养老金税优'),
      400,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('salary-calculator-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('个人养老金税优'), findsOneWidget);
    expect(find.text('年度缴纳策略对比'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('salary-open-pension-profile')),
      findsOneWidget,
    );
  });

  testWidgets('个人信息里有养老与税优入口，可进入填写', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ProfileHubPage()));
    await tester.pumpAndSettle();

    expect(find.text('养老与税优信息'), findsOneWidget);
    await tester.tap(find.text('养老与税优信息'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePensionPage), findsOneWidget);
    expect(find.text('所在城市养老政策'), findsOneWidget);
    expect(find.text('年薪估计值'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('计划年度缴纳额'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('计划年度缴纳额'), findsOneWidget);
  });

  Finder fieldOf(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );

  testWidgets('基本信息与工资计算器共用「每月专项附加扣除」', (tester) async {
    await ProfileRepository.update((data) {
      UserProfile.putNumber(data, UserProfile.specialDeductionKey, '1500');
    });

    await tester.pumpWidget(const MaterialApp(home: ProfileBasicPage()));
    await tester.pumpAndSettle();
    expect(fieldOf('每月专项附加扣除'), findsOneWidget);
    expect(
      tester.widget<TextField>(fieldOf('每月专项附加扣除')).controller!.text,
      '1500',
    );

    // 基本信息里改值并保存 → 档案字段更新。
    await tester.enterText(fieldOf('每月专项附加扣除'), '2000');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存个人信息'));
    await tester.pumpAndSettle();
    expect(
      (await ProfileRepository.load()).specialDeduction,
      2000,
    );

    // 工资计算器自动载入同一字段；「导入个人信息」也应读到新值。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const MaterialApp(home: SalaryPage()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      fieldOf('每月专项附加扣除'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(fieldOf('每月专项附加扣除')).controller!.text,
      '2000',
    );
  });
}
