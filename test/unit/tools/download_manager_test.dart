import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/features/tools/link_parser/download_manager.dart';
import 'package:toolbox/features/tools/link_parser/download_task.dart';
import 'package:toolbox/features/tools/link_parser/link_downloader.dart';
import 'package:toolbox/features/tools/link_parser/link_settings.dart';

/// 三条字节的假响应，不支持 Range：下载器会走单流分支，最容易验证。
http.Client _okClient({Duration delay = Duration.zero}) => MockClient(
      (request) async {
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        return http.Response.bytes(
          const <int>[1, 2, 3],
          200,
          headers: <String, String>{'content-length': '3'},
        );
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late DownloadManager manager;

  Future<void> boot({
    LinkSettings settings = const LinkSettings(),
    http.Client? client,
    PublicDownloadSaver? saver,
    Future<PublicSaveResult> Function(DownloadTask, File, LinkSettings)?
        saveHook,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'link_settings_v1': jsonEncode(settings.toJson()),
    });
    manager = DownloadManager(
      tempDirLoader: () async => dir,
      publicSaver: saver,
      saver: saveHook,
      downloaderFactory: () => LinkDownloader(
        client: client ?? _okClient(),
        threads: 1,
        tempDirLoader: () async => dir,
      ),
    );
    await manager.ensureLoaded();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('toolbox_dl_');
    LinkSettingsStore.resetForTest();
  });

  tearDown(() async {
    manager.dispose();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('下载完成后归档并把路径写回任务', () async {
    await boot(
      saveHook: (task, file, settings) async {
        final target = File(p.join(dir.path, 'saved_${task.name}'));
        await file.copy(target.path);
        return PublicSaveResult(
          displayPath: target.path,
          localPath: target.path,
        );
      },
    );

    final task = manager.enqueue(
      url: 'https://cdn.example.com/a.bin',
      name: 'a.bin',
    );
    final finished = await task.completer.future;

    expect(finished.status, DownloadStatus.done);
    expect(finished.done, 3);
    expect(finished.total, 3);
    expect(finished.savedPath, endsWith('saved_a.bin'));
    expect(manager.tasks.single.status, DownloadStatus.done);
  });

  test('保存位置选手机目录时走系统导出，并标记 savedToPhone', () async {
    Map<String, dynamic>? captured;
    await boot(
      settings: const LinkSettings(
        saveTarget: LinkSaveTarget.phone,
        phoneDir: 'Toolbox/下载',
      ),
      saver: PublicDownloadSaver(
        invoker: (args) async {
          captured = args;
          return <dynamic, dynamic>{
            'displayPath': 'Download/Toolbox/下载/b.bin',
            'localPath': '/storage/emulated/0/Download/Toolbox/下载/b.bin',
          };
        },
      ),
    );

    final task = manager.enqueue(
      url: 'https://cdn.example.com/b.bin',
      name: 'b.bin',
    );
    final finished = await task.completer.future;

    expect(finished.status, DownloadStatus.done);
    expect(finished.savedToPhone, isTrue);
    expect(finished.savedPath, 'Download/Toolbox/下载/b.bin');
    expect(captured?['relativeDir'], 'Download/Toolbox/下载');
    expect(captured?['name'], 'b.bin');
  });

  test('HTTP 失败时任务标记为 failed 并保留可读原因', () async {
    await boot(
      settings: const LinkSettings(retries: 0),
      client: MockClient((request) async => http.Response('nope', 500)),
      saveHook: (task, file, settings) async =>
          const PublicSaveResult(displayPath: 'x', localPath: 'x'),
    );

    final task = manager.enqueue(
      url: 'https://cdn.example.com/c.bin',
      name: 'c.bin',
    );
    final finished = await task.completer.future;

    expect(finished.status, DownloadStatus.failed);
    expect(finished.error, contains('HTTP 500'));
  });

  test('并发上限为 1 时第二个任务保持排队，取消排队任务直接生效', () async {
    await boot(
      settings: const LinkSettings(concurrency: 1),
      client: _okClient(delay: const Duration(milliseconds: 200)),
      saveHook: (task, file, settings) async =>
          const PublicSaveResult(displayPath: 'x', localPath: 'x'),
    );

    final first = manager.enqueue(
      url: 'https://cdn.example.com/1.bin',
      name: '1.bin',
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final second = manager.enqueue(
      url: 'https://cdn.example.com/2.bin',
      name: '2.bin',
    );

    expect(second.status, DownloadStatus.queued);
    await manager.cancel(second);
    expect(second.status, DownloadStatus.canceled);

    await first.completer.future;
    expect(first.status, DownloadStatus.done);
  });

  test('记录持久化：重启后 running 变 paused，已完成的路径还在', () async {
    await boot();
    final running = DownloadTask(
      id: '1',
      url: 'https://cdn.example.com/1.bin',
      name: '1.bin',
      createdAt: 100,
      status: DownloadStatus.running,
      total: 100,
      done: 40,
    );
    final done = DownloadTask(
      id: '2',
      url: 'https://cdn.example.com/2.bin',
      name: '2.bin',
      createdAt: 200,
      status: DownloadStatus.done,
      total: 10,
      done: 10,
      savedPath: '/data/app/app_storage/other/2.bin',
      localPath: '/data/app/app_storage/other/2.bin',
    );

    await DownloadTaskStore.save(<DownloadTask>[running, done]);
    final restored = await DownloadTaskStore.load();

    expect(restored, hasLength(2));
    final byId = <String, DownloadTask>{
      for (final task in restored) task.id: task,
    };
    expect(byId['1']!.status, DownloadStatus.paused);
    expect(byId['1']!.done, 40);
    expect(byId['2']!.status, DownloadStatus.done);
    expect(byId['2']!.savedPath, endsWith('2.bin'));
  });

  test('删除记录不动成品文件，清空记录会删临时文件', () async {
    await boot(
      saveHook: (task, file, settings) async {
        final target = File(p.join(dir.path, 'saved_${task.name}'));
        await file.copy(target.path);
        return PublicSaveResult(
          displayPath: target.path,
          localPath: target.path,
        );
      },
    );

    final task = manager.enqueue(
      url: 'https://cdn.example.com/d.bin',
      name: 'd.bin',
    );
    final finished = await task.completer.future;
    final saved = File(finished.localPath);
    expect(saved.existsSync(), isTrue);

    await manager.remove(finished);
    expect(manager.tasks, isEmpty);
    expect(saved.existsSync(), isTrue);

    // 造一个残留的临时文件，确认 clearAll 会清掉它。
    final leftover = File(p.join(dir.path, 'xmt_leftover_tmp'));
    await leftover.writeAsBytes(const <int>[1]);
    await manager.clearAll();
    expect(leftover.existsSync(), isFalse);
  });
}
