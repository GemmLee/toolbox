import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/core/platform/browser_opener.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_remote_index.dart';
import 'package:toolbox/features/user/app_update_service.dart';
import 'package:toolbox/features/user/download_station_page.dart';
import '../support/test_env.dart';

void main() {
  installCleanEnv();

  testWidgets('下载站展示安装包与题库，点击各自打开公开直链', (tester) async {
    const channel = MethodChannel('toolbox/browser-station-test');
    final opened = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        opened.add(call.arguments['url'] as String);
        return true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final update = AppUpdateService(
      client: MockClient((_) async => http.Response(
            jsonEncode(<String, dynamic>{
              'version': '1.0.6',
              'notes': '测试安装包',
              'apkFile': 'XMtools-1.0.6.apk',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          )),
    );
    final index = QuizIndexService(
      client: MockClient((_) async => http.Response(
            jsonEncode(<String, dynamic>{
              'files': <Object?>[
                <String, Object?>{
                  'id': 'bank-1',
                  'title': '示例题库',
                  'file': '示例题库.json',
                  'questions': 10,
                  'types': <String, Object?>{'single': 10},
                  'size': 2048,
                },
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          )),
    );

    await tester.pumpWidget(MaterialApp(
      home: DownloadStationPage(
        updateService: update,
        indexService: index,
        opener: BrowserOpener(channel: channel),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('下载站'), findsOneWidget);
    expect(find.textContaining('安装包 · 1.0.6'), findsOneWidget);
    expect(find.text('题库资源'), findsOneWidget);
    expect(find.text('示例题库'), findsOneWidget);
    expect(find.textContaining('10 题'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('download-station-apk')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('download-station-bank-bank-1')));
    await tester.pumpAndSettle();

    expect(opened, <String>[
      'https://xmonline-sgcc.r2.dev/xmapk/XMtools-1.0.6.apk',
      'https://xmonline-sgcc.r2.dev/quiz-bank/%E7%A4%BA%E4%BE%8B%E9%A2%98%E5%BA%93.json',
    ]);
    update.dispose();
    index.dispose();
  });
}
