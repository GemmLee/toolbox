import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/platform/file_import_bridge.dart';
import 'package:toolbox/core/settings/default_open_tools.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/core/storage/app_files.dart';

import '../../support/test_env.dart';

void main() {
  late Directory root;
  late Directory incoming;

  setUp(() async {
    mockPrefs();
    SettingsController.instance.resetForTest();
    root = await Directory.systemTemp.createTemp('default_open_unit');
    incoming = await Directory.systemTemp.createTemp('default_open_incoming');
    AppStore.useRootForTest(root);
    FileImportBridge.instance.resetForTest();
  });

  tearDown(() async {
    AppStore.useRootForTest(null);
    FileImportBridge.instance.resetForTest();
    SettingsController.instance.resetForTest();
    if (root.existsSync()) await root.delete(recursive: true);
    if (incoming.existsSync()) await incoming.delete(recursive: true);
  });

  group('格式与动作', () {
    test('全部支持的扩展名都能找到对应规则', () {
      expect(extensionOf('bank.JSON'), 'json');
      expect(extensionOf('note'), '');
      expect(ruleForFileName('a.json')!.id, 'json');
      expect(ruleForFileName('a.md')!.id, 'markdown');
      expect(ruleForFileName('a.csv')!.id, 'text');
      expect(ruleForFileName('a.pdf'), isNull);
      for (final ext in kSupportedImportExtensions) {
        expect(ruleForExtension(ext), isNotNull);
      }
      expect(FileImportBridge.isSupported('a.csv'), isTrue);
      expect(FileImportBridge.isSupported('a.pdf'), isFalse);
    });

    test('json 两个动作，md 与 txt 只有阅读器', () {
      expect(ruleForFileName('a.json')!.actions, hasLength(2));
      expect(ruleForFileName('a.md')!.actions,
          <DefaultOpenAction>[DefaultOpenAction.reader]);
      expect(ruleForFileName('a.txt')!.actions,
          <DefaultOpenAction>[DefaultOpenAction.reader]);
    });
  });

  group('设置持久化', () {
    test('json 默认进刷题助手导入，改成阅读器后重新 load 仍生效', () async {
      final settings = SettingsController.instance;
      expect(
          settings.defaultOpenActionFor('a.json'), DefaultOpenAction.quizBank);
      await settings.setDefaultOpenTool('json', DefaultOpenAction.reader);
      expect(settings.defaultOpenActionFor('a.json'), DefaultOpenAction.reader);
      expect(settings.defaultOpenActionFor('a.md'), DefaultOpenAction.reader);

      settings.resetForTest();
      await settings.load();
      expect(settings.defaultOpenActionFor('a.json'), DefaultOpenAction.reader);
    });

    test('非法动作值回落到该格式默认值', () async {
      final settings = SettingsController.instance;
      settings.defaultOpenTools = <String, String>{'json': 'unknown'};
      expect(
          settings.defaultOpenActionFor('a.json'), DefaultOpenAction.quizBank);
    });
  });

  group('外部导入按设置分流', () {
    Future<File> source(String name) async {
      final f = File('${incoming.path}/$name');
      await f.writeAsString('{"version":1}');
      return f;
    }

    test('json 默认进刷题助手：归档到 quiz 分类且动作是 quizBank', () async {
      final f = await source('bank.json');
      final stored = await FileImportBridge.instance.adoptPath(f.path);
      expect(stored, isNotNull);
      final pending = FileImportBridge.instance.takePending();
      expect(pending!.action, DefaultOpenAction.quizBank);
      expect(pending.file.category, AppStoreCategory.quiz);
      expect(FileImportBridge.instance.takePending(), isNull);
      expect(FileImportBridge.instance.takePendingOpen(), isNull);
    });

    test('改成阅读器：归档到 reader 分类且动作是 reader', () async {
      await SettingsController.instance
          .setDefaultOpenTool('json', DefaultOpenAction.reader);
      final f = await source('note.json');
      final stored = await FileImportBridge.instance.adoptPath(f.path);
      expect(stored!.category, AppStoreCategory.reader);
      final pending = FileImportBridge.instance.takePending();
      expect(pending!.action, DefaultOpenAction.reader);
    });

    test('md 不受 json 设置影响', () async {
      await SettingsController.instance
          .setDefaultOpenTool('json', DefaultOpenAction.reader);
      final f = await source('readme.md');
      final pending = FileImportBridge.instance.takePending();
      expect(pending, isNull);
      await FileImportBridge.instance.adoptPath(f.path);
      expect(FileImportBridge.instance.takePending()!.action,
          DefaultOpenAction.reader);
    });
  });
}
