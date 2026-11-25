import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/user/settings_tile.dart';
import 'package:toolbox/features/user/user_page.dart';
import '../support/test_env.dart';

void main() {
  installCleanEnv();

  testWidgets('智能组不再包含个人信息，只保留 AI 配置', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UserPage()));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SettingsTile, '个人信息'), findsNothing);
    final ai = find.widgetWithText(SettingsTile, 'AI 配置');
    expect(ai, findsOneWidget);
    expect(
      find.ancestor(of: ai, matching: find.byType(Card)),
      findsOneWidget,
    );
  });

  testWidgets('单行列行高统一（含主题行）', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UserPage()));
    await tester.pumpAndSettle();

    final heights = <double>{};
    for (final tile
        in tester.widgetList<SettingsTile>(find.byType(SettingsTile))) {
      if (tile.subtitle != null) continue;
      heights.add(tester.getSize(find.byWidget(tile)).height);
    }
    expect(heights, hasLength(1), reason: '单行列高度应完全一致：$heights');
  });
}
