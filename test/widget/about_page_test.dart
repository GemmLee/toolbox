import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/core/platform/browser_opener.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/features/user/about_page.dart';
import 'package:toolbox/features/user/app_update_service.dart';
import '../support/test_env.dart';

/// 关于页：应用信息 + 简介与反馈合卡 + 两个可点进的说明入口。
void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  tearDown(restoreSystemLanguage);

  testWidgets('简介与反馈合并成一张卡，紧跟在应用信息后面', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    await tester.pumpAndSettle();

    // 简介正文与反馈信息在同一屏内可见，说明反馈已上移并与简介合并。
    expect(find.textContaining('XMtools'), findsWidgets);
    expect(find.text('反馈与建议'), findsOneWidget);
    expect(find.textContaining('ljm123aa@163.com'), findsOneWidget);
    expect(find.textContaining('欢迎提出任何意见与建议'), findsOneWidget);

    // 入口卡只显示标题与一行概述，具体条目不在首屏展开。
    expect(find.text('快速上手'), findsOneWidget);
    expect(find.text('常用工具'), findsOneWidget);
    expect(find.text('找工具'), findsNothing);
    expect(find.text('刷题助手'), findsNothing);

    // 反馈卡在入口卡上方。
    expect(
      tester.getCenter(find.text('反馈与建议')).dy,
      lessThan(tester.getCenter(find.text('快速上手')).dy),
    );
  });

  testWidgets('快速上手以刷题为核心，导入题库教程已移到搜题页', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('about-guide-start')));
    await tester.pumpAndSettle();

    expect(find.byType(AboutGuidePage), findsOneWidget);
    expect(find.text('开始刷题'), findsOneWidget);
    expect(find.text('三种搜题'), findsOneWidget);
    expect(find.text('把资料变成题库'), findsOneWidget);
    expect(find.text('导入文档与文件位置'), findsOneWidget);
    expect(find.textContaining('搜题 → 使用教程'), findsOneWidget);
    // 独立的「导入题库」教程已从关于页移除，改到搜题教程里。
    expect(find.text('导入题库'), findsNothing);
    expect(find.text('找工具'), findsNothing);
    // 首条是「开始刷题」。
    expect(
      tester.getCenter(find.text('开始刷题')).dy,
      lessThan(tester.getCenter(find.text('三种搜题')).dy),
    );
  });

  testWidgets('常用工具入口点进去后展示刷题、搜题与证件照', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    await tester.pumpAndSettle();

    final tools = find.byKey(const ValueKey('about-guide-tools'));
    await tester.scrollUntilVisible(
      tools,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(tools);
    await tester.pumpAndSettle();

    expect(find.byType(AboutGuidePage), findsOneWidget);
    expect(find.text('刷题助手'), findsOneWidget);
    expect(find.text('搜题工具'), findsOneWidget);
    expect(find.text('文字阅读器'), findsOneWidget);
    expect(find.text('证件照'), findsOneWidget);
    expect(find.text('智能助手'), findsOneWidget);
    expect(
      find.textContaining('离线识别中文 / 英文印刷体'),
      findsOneWidget,
    );
  });

  testWidgets('检测更新：有新版本时显示版本号与下载按钮，点击跳浏览器', (tester) async {
    final opened = <String>[];
    final client = MockClient((request) async {
      expect(request.url.path, '/xmapk/version.json');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'version': '9.9.9',
          'notes': '测试新版本',
          'apkFile': 'XMtools-9.9.9.apk',
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final service = AppUpdateService(client: client);
    final channelCalls = <MethodCall>[];
    const testChannel = MethodChannel('toolbox/browser-test');
    final opener = BrowserOpener(channel: testChannel);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      testChannel,
      (call) async {
        channelCalls.add(call);
        opened.add(call.arguments['url'] as String);
        return true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(testChannel, null));

    await tester.pumpWidget(MaterialApp(
      home: AboutPage(updateService: service, updateServiceOpener: opener),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('about-check-update')));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 9.9.9'), findsOneWidget);
    expect(find.text('测试新版本'), findsOneWidget);
    expect(find.byKey(const ValueKey('about-download-update')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('about-download-update')));
    await tester.pumpAndSettle();
    expect(channelCalls, hasLength(1));
    expect(
        opened.single, 'https://xmonline-sgcc.r2.dev/xmapk/XMtools-9.9.9.apk');
    service.dispose();
  });

  testWidgets('切换到英文后入口卡与详情页文案同步切换', (tester) async {
    await SettingsController.instance.setLanguage(AppLanguage.english);
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    await tester.pumpAndSettle();

    expect(find.text('Feedback & suggestions'), findsOneWidget);
    expect(find.textContaining('ljm123aa@163.com'), findsOneWidget);
    expect(
        find.textContaining('XMtools gathers everyday tools'), findsOneWidget);

    // 英文简介比中文长，入口卡落到折叠线以下，先滚过去再断言与点击。
    final start = find.byKey(const ValueKey('about-guide-start'));
    await tester.scrollUntilVisible(
      start,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Getting started'), findsOneWidget);
    expect(find.text('Popular tools'), findsOneWidget);

    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(find.text('Start quizzing'), findsOneWidget);
    expect(find.text('Three search modes'), findsOneWidget);
    expect(find.text('Typhoon alerts'), findsNothing);
  });
}
