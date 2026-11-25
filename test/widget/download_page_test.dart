import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/features/tools/link_parser/download_manager.dart';
import 'package:toolbox/features/tools/link_parser/download_page.dart';
import 'package:toolbox/features/tools/link_parser/download_task.dart';
import 'package:toolbox/features/tools/link_parser/link_settings.dart';

import '../support/test_env.dart';

DownloadTask _task({
  required String id,
  required String name,
  required DownloadStatus status,
  int total = 0,
  int done = 0,
  String savedPath = '',
  String error = '',
}) =>
    DownloadTask(
      id: id,
      url: 'https://cdn.example.com/$name',
      name: name,
      platform: '夸克网盘',
      createdAt: int.parse(id),
      total: total,
      done: done,
      status: status,
      savedPath: savedPath,
      localPath: savedPath,
      error: error,
    );

void main() {
  installCleanEnv();

  Future<DownloadManager> pumpPage(
    WidgetTester tester,
    List<DownloadTask> tasks,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      DownloadTaskStore.storeKey:
          jsonEncode(tasks.map((task) => task.toJson()).toList()),
    });
    LinkSettingsStore.resetForTest();
    // 真实文件 I/O 必须在 runAsync 里跑：testWidgets 默认是 FakeAsync。
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('toolbox_dl_page_'),
    ))!;
    addTearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });
    final manager = DownloadManager(
      tempDirLoader: () async => temp,
      publicSaver: PublicDownloadSaver(
        invoker: (args) async => <dynamic, dynamic>{
          'displayPath': 'Download/Toolbox/x',
          'localPath': '/tmp/x',
        },
      ),
    );
    await manager.ensureLoaded();
    await tester.pumpWidget(
      MaterialApp(home: DownloadPage(manager: manager)),
    );
    await tester.pumpAndSettle();
    return manager;
  }

  testWidgets('没有任务时给空态提示', (tester) async {
    await pumpPage(tester, <DownloadTask>[]);
    expect(find.text('还没有下载任务'), findsOneWidget);
    expect(find.textContaining('任务会出现在这里'), findsOneWidget);
  });

  testWidgets('已完成任务显示保存位置与打开入口', (tester) async {
    await pumpPage(tester, <DownloadTask>[
      _task(
        id: '100',
        name: '演示.mp4',
        status: DownloadStatus.done,
        total: 2048,
        done: 2048,
        savedPath: '/data/user/0/app_storage/other/演示.mp4',
      ),
    ]);

    expect(find.text('演示.mp4'), findsOneWidget);
    expect(find.textContaining('已保存到'), findsOneWidget);
    expect(find.byKey(const ValueKey('download-open-100')), findsOneWidget);
    expect(find.text('已完成 1 个'), findsOneWidget);
  });

  testWidgets('暂停的任务给「继续」按钮，失败任务显示原因', (tester) async {
    final manager = await pumpPage(tester, <DownloadTask>[
      _task(
        id: '200',
        name: '半截.zip',
        status: DownloadStatus.paused,
        total: 1000,
        done: 400,
      ),
      _task(
        id: '300',
        name: '坏链.bin',
        status: DownloadStatus.failed,
        error: '服务器拒绝访问（403），链接可能已过期或需要登录',
      ),
    ]);

    expect(find.byKey(const ValueKey('download-resume-200')), findsOneWidget);
    expect(find.textContaining('已暂停'), findsOneWidget);
    expect(find.textContaining('403'), findsOneWidget);

    await tester.runAsync(
      () => manager.cancel(manager.tasks.firstWhere((t) => t.id == '200')),
    );
    await tester.pumpAndSettle();
    expect(find.text('已取消'), findsOneWidget);
  });

  testWidgets('有任务时顶部摘要统计已完成数量', (tester) async {
    await pumpPage(tester, <DownloadTask>[
      _task(id: '10', name: 'a.jpg', status: DownloadStatus.done, done: 100),
      _task(id: '20', name: 'b.jpg', status: DownloadStatus.done, done: 200),
      _task(id: '30', name: 'c.jpg', status: DownloadStatus.failed),
    ]);

    expect(find.text('已完成 2 个'), findsOneWidget);
    expect(find.textContaining('失败 1'), findsOneWidget);
  });
}
