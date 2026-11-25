import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/settings/default_open_tools.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/features/user/default_open_tool_page.dart';
import 'package:toolbox/features/user/user_page.dart';

import '../support/test_env.dart';

void main() {
  installCleanEnv();

  testWidgets('json 默认进刷题助手，可切回文字阅读器；md / txt 只读展示', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DefaultOpenToolPage()));
    await tester.pumpAndSettle();

    expect(find.text('默认打开工具'), findsOneWidget);
    expect(find.text('.json'), findsOneWidget);
    expect(find.text('导入题库'), findsOneWidget);
    expect(find.byKey(const ValueKey('default-open-single-markdown')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('default-open-single-text')), findsOneWidget);

    final settings = SettingsController.instance;
    expect(settings.defaultOpenActionFor('a.json'), DefaultOpenAction.quizBank);

    await tester.tap(find.byKey(
      const ValueKey('default-open-json-reader'),
    ));
    await tester.pumpAndSettle();

    expect(settings.defaultOpenActionFor('a.json'), DefaultOpenAction.reader);
    final radio = tester.widget<RadioListTile<DefaultOpenAction>>(
      find.byKey(const ValueKey('default-open-json-reader')),
    );
    expect(radio.groupValue, DefaultOpenAction.reader);
  });

  testWidgets('用户页里能进入默认打开工具设置', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UserPage()));
    await tester.pumpAndSettle();

    expect(find.text('默认打开工具'), findsOneWidget);
    await tester.tap(find.text('默认打开工具'));
    await tester.pumpAndSettle();
    expect(find.byType(DefaultOpenToolPage), findsOneWidget);
  });
}
