import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/link_parser/download_manager.dart';
import 'package:toolbox/features/tools/link_parser/link_settings.dart';
import 'package:toolbox/features/tools/link_parser/link_settings_page.dart';

import '../support/test_env.dart';

void main() {
  installCleanEnv();

  Future<void> pumpPage(WidgetTester tester, {DownloadManager? manager}) async {
    LinkSettingsStore.resetForTest();
    await tester.pumpWidget(
      MaterialApp(
        home: LinkSettingsPage(
          manager: manager,
          preferences: () async => const LinkSettings(),
          usageLoader: () async => 100 * 1024 * 1024,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认保存到应用存储空间，并显示当前占用', (tester) async {
    await pumpPage(tester);
    expect(find.text('保存位置'), findsOneWidget);
    expect(find.text('应用存储空间'), findsWidgets);
    expect(find.textContaining('当前占用 100 MB'), findsOneWidget);
    expect(find.byKey(const ValueKey('link-settings-dir')), findsNothing);
  });

  testWidgets('切到手机下载目录后出现子目录设置，改动即时保存', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('手机下载目录'));
    await tester.pumpAndSettle();

    expect(LinkSettingsStore.current.value.toPhone, isTrue);
    expect(find.byKey(const ValueKey('link-settings-dir')), findsOneWidget);
    expect(find.textContaining('Download/'), findsWidgets);
  });

  testWidgets('线程与并发可切换，写入设置', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('8'));
    await tester.pumpAndSettle();
    expect(LinkSettingsStore.current.value.threads, 8);

    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();
    expect(LinkSettingsStore.current.value.concurrency, 3);
  });

  testWidgets('清除按钮会清空下载记录', (tester) async {
    final manager = DownloadManager();
    await pumpPage(tester, manager: manager);

    await tester.tap(find.byKey(const ValueKey('link-settings-clear')));
    await tester.pumpAndSettle();

    expect(manager.tasks, isEmpty);
    // 页面还挂着监听，先卸载再释放，避免「used after dispose」。
    await tester.pumpWidget(const SizedBox());
    manager.dispose();
  });
}
