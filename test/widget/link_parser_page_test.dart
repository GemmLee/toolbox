import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/core/storage/app_files.dart';
import 'package:toolbox/features/tools/link_parser/douyin_webview.dart';
import 'package:toolbox/features/tools/link_parser/link_credentials.dart';
import 'package:toolbox/features/tools/link_parser/link_parser.dart';
import 'package:toolbox/features/tools/link_parser/link_parser_page.dart';

import '../support/test_env.dart';

void main() {
  installCleanEnv();

  testWidgets('网盘分享列出文件，点下载走协议取链并保存', (tester) async {
    final parser = LinkParser(
      client: MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/sharepage/token')) {
          return http.Response(
            '{"status":200,"data":{"stoken":"ST","title":"演示"}}',
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        if (url.contains('/sharepage/detail')) {
          return http.Response(
            '{"status":200,"data":{"list":[{"fid":"f1","file_name":"a.txt",'
            '"size":3,"dir":false,"pdir_fid":"0","share_fid_token":"tok"}]}}',
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        if (url.contains('/file/download')) {
          return http.Response(
            '{"status":200,"data":[{"download_url":"https://cdn.example.com/a.txt",'
            '"size":3}]}',
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      }),
    );

    Future<StoredFile> fakeSaver(String name, List<int> bytes) async => StoredFile(
          category: AppStoreCategory.other,
          file: File(name),
          size: bytes.length,
          modified: DateTime.now(),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: LinkParserPage(
          parser: parser,
          credentialLoader: () async => <LinkCredential>[],
          downloader: (url) async => Uint8List.fromList(utf8.encode('abc')),
          saver: fakeSaver,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('link-input')),
      'https://pan.quark.cn/s/abc',
    );
    await tester.tap(find.byKey(const ValueKey('link-parse')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('link-file-f1')), findsOneWidget);
    expect(find.text('a.txt'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('link-file-action-f1')));
    await tester.pumpAndSettle();

    expect(find.text('已下载'), findsOneWidget);
    expect(find.text('已保存：a.txt'), findsOneWidget);
  });

  testWidgets('输入框为空时点登录按钮，按所选平台打开官方登录页', (tester) async {
    String? calledPlatform;
    String? calledUrl;
    Object? calledDesktop;
    final bridge = LinkLoginBridge(
      invoker: (method, args) async {
        expect(method, 'openLogin');
        calledPlatform = args['platform'] as String;
        calledUrl = args['url'] as String;
        calledDesktop = args['desktop'];
        return <dynamic, dynamic>{
          'cookies': 'a=1',
          'storage': '{}',
          'url': calledUrl,
        };
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LinkParserPage(
          parser: LinkParser(
            client: MockClient((request) async => http.Response('{}', 200)),
          ),
          credentialLoader: () async => <LinkCredential>[],
          loginBridge: bridge,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 登录面板默认折叠：点标题展开。
    await tester.tap(find.text('网盘登录与下载'));
    await tester.pumpAndSettle();

    // 输入框保持为空 —— 这正是此前「按钮看起来没反应」的场景。
    expect(find.byKey(const ValueKey('link-login')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('link-login')));
    await tester.pumpAndSettle();

    expect(calledPlatform, '夸克网盘');
    expect(calledUrl, loginUrlFor('夸克网盘'));
    // 网盘移动端首页常常只有「下载 App」，默认按桌面端网页打开。
    expect(calledDesktop, isTrue);
    expect(desktopLoginFor('139 云盘'), isFalse);
  });

  testWidgets('粘贴框下方有可选提取码输入框，且不影响只粘链接的解析', (tester) async {
    final parser = LinkParser(
      client: MockClient((request) async {
        return http.Response('{"code":0,"data":{"InfoList":[],"Next":"-1"}}', 200,
            headers: <String, String>{'content-type': 'application/json'});
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LinkParserPage(
          parser: parser,
          credentialLoader: () async => <LinkCredential>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('link-extract-code')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('link-input')),
      'https://www.123pan.com/s/2785Vv-T4Ded',
    );
    await tester.enterText(
      find.byKey(const ValueKey('link-extract-code')),
      '8888',
    );
    await tester.tap(find.byKey(const ValueKey('link-parse')));
    await tester.pumpAndSettle();

    // 解析走通（没有文件时 note 提示提取码或空目录），不因提取码框报错。
    expect(find.textContaining('123 云盘'), findsWidgets);
  });

  testWidgets('抖音图集解析后铺两列缩略图，点任意一张进全屏预览', (tester) async {
    final bridge = DouyinWebViewBridge(
      invoker: (method, args) async => jsonEncode(<String, dynamic>{
        'title': '海边的一天',
        'images': <String>[
          'https://p3.douyinpic.com/a.webp',
          'https://p3.douyinpic.com/b.webp',
          'https://p3.douyinpic.com/c.webp',
        ],
        'src': 'ssr',
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LinkParserPage(
          parser: LinkParser(
            client: MockClient((request) async => http.Response('{}', 200)),
          ),
          credentialLoader: () async => <LinkCredential>[],
          douyinBridge: bridge,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('link-input')),
      'https://www.douyin.com/note/7312345678901234567',
    );
    await tester.tap(find.byKey(const ValueKey('link-parse')));
    await tester.pumpAndSettle();

    // 测试环境没有网络，缩略图必然加载失败；errorBuilder 已经兜住显示，
    // 这里把「图片资源服务」记下的异常丢掉，否则会被算成未处理异常。
    while (tester.takeException() != null) {}

    expect(find.byKey(const ValueKey('link-media-grid')), findsOneWidget);
    expect(find.byKey(const ValueKey('link-media-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('link-media-2')), findsOneWidget);

    // 网格在结果卡里，可能落在视口下方：先滚到可见再点。
    await tester.ensureVisible(find.byKey(const ValueKey('link-media-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-media-1')));
    await tester.pumpAndSettle();
    while (tester.takeException() != null) {}
    // 点第 2 张，预览直接停在第 2 张。
    expect(find.text('2 / 3'), findsOneWidget);
  });
}
