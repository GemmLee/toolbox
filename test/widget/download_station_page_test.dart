import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/core/platform/browser_opener.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_remote_index.dart';
import 'package:toolbox/features/user/app_update_service.dart'
    show AppUpdateService, kReleasePageUrl;
import 'package:toolbox/features/user/download_station_page.dart'
    show DownloadStationPage;
import '../support/test_env.dart';

void main() {
  installCleanEnv();

  const apkUrl =
      'https://github.com/GemmLee/toolbox/releases/download/v1.0.7/XMtools-1.0.7.apk';

  MockClient buildIndexClient() => MockClient((_) async => http.Response(
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
      ));

  MockClient buildReleaseClient() => MockClient((request) async {
        expect(
          request.url.toString(),
          'https://api.github.com/repos/GemmLee/toolbox/releases/latest',
        );
        return http.Response(
          jsonEncode(<String, dynamic>{
            'tag_name': 'v1.0.7',
            'assets': <Object?>[
              <String, Object?>{
                'name': 'XMtools-1.0.7.apk',
                'browser_download_url': apkUrl,
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

  testWidgets('下载站题库走 Pages 同源，APK 走 Release asset', (tester) async {
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

    final index = QuizIndexService(
      client: buildIndexClient(),
      baseUrl: QuizIndexService.kPagesResourceBaseUrl,
    );
    final update = AppUpdateService(client: buildReleaseClient());

    await tester.pumpWidget(MaterialApp(
      home: DownloadStationPage(
        indexService: index,
        updateService: update,
        opener: BrowserOpener(channel: channel),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('下载站'), findsOneWidget);
    expect(find.text('题库资源'), findsOneWidget);
    expect(find.text('示例题库'), findsOneWidget);
    expect(find.textContaining('10 题'), findsOneWidget);

    final apk = tester.widget<FilledButton>(
      find.byKey(const ValueKey('download-station-apk')),
    );
    expect(apk.onPressed, isNotNull);
    expect(find.text('下载安装包'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('download-station-apk')));
    await tester.pumpAndSettle();
    expect(opened.single, apkUrl);
    opened.clear();

    await tester
        .tap(find.byKey(const ValueKey('download-station-bank-bank-1')));
    await tester.pumpAndSettle();

    expect(opened, <String>[
      '${QuizIndexService.kPagesResourceBaseUrl}quiz-bank/%E7%A4%BA%E4%BE%8B%E9%A2%98%E5%BA%93.json',
    ]);
    expect(
      Uri.parse(opened.single).path,
      '/quiz-bank/%E7%A4%BA%E4%BE%8B%E9%A2%98%E5%BA%93.json',
    );
    index.dispose();
    update.dispose();
  });

  testWidgets('Release 拉取失败时 APK 回退发布页', (tester) async {
    const channel = MethodChannel('toolbox/browser-fallback-test');
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

    final index = QuizIndexService(client: buildIndexClient());
    final update = AppUpdateService(
      client: MockClient((_) async => http.Response('not found', 404)),
    );

    await tester.pumpWidget(MaterialApp(
      home: DownloadStationPage(
        indexService: index,
        updateService: update,
        opener: BrowserOpener(channel: channel),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('download-station-apk')));
    await tester.pumpAndSettle();
    expect(opened.single, kReleasePageUrl);
    index.dispose();
    update.dispose();
  });

  test('索引拉不到时降级 R2，下载链接随之切换', () async {
    var call = 0;
    final index = QuizIndexService(
      client: MockClient((request) async {
        call++;
        if (call == 1) return http.Response('not found', 404);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'files': <Object?>[
              <String, Object?>{
                'id': 'bank-2',
                'title': '回退题库',
                'file': 'b.json',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
      baseUrl: QuizIndexService.kPagesResourceBaseUrl,
      fallbackBaseUrl: QuizIndexService.kDefaultQuizResourceBaseUrl,
    );
    final files = await index.fetch();
    expect(files.single.title, '回退题库');
    expect(index.usedBaseUrl, QuizIndexService.kDefaultQuizResourceBaseUrl);
    expect(files.single.downloadUrl(index.usedBaseUrl),
        'https://xmonline-sgcc.r2.dev/quiz-bank/b.json');
    index.dispose();
  });
}
