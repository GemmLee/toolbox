import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/core/settings/tool_texts.dart';
import 'package:toolbox/core/storage/local_store.dart';
import 'package:toolbox/core/settings/assistant_platforms.dart';
import 'package:toolbox/features/tools/assistant/ui/assistant_profile_edit_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalStore.remove('app_settings');
    SettingsController.instance.resetForTest();
    await SettingsController.instance.load();
  });

  group('自定义平台数据', () {
    test('parsePlatformModels 支持逗号/换行/分号并去重', () {
      expect(
        parsePlatformModels('a, b\nc，d; e'),
        <String>['a', 'b', 'c', 'd', 'e'],
      );
      expect(parsePlatformModels('m1 m1\nm2'), <String>['m1', 'm2']);
      expect(parsePlatformModels('  \n , ; '), isEmpty);
    });

    test('fromJson/toJson 往返保留 id 与模型列表', () {
      final p = AssistantPlatform.fromJson(<String, dynamic>{
        'id': 'cp-1',
        'name': '某厂商',
        'baseUrl': 'https://api.example.com/v1',
        'models': <String>['m1', 'm2'],
      });
      expect(p.isCustom, isTrue);
      expect(p.id, 'cp-1');
      expect(p.balanceKind, BalanceKind.none);

      final back = AssistantPlatform.fromJson(
          jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.name, '某厂商');
      expect(back.baseUrl, 'https://api.example.com/v1');
      expect(back.models, <String>['m1', 'm2']);
      expect(back.id, 'cp-1');
    });

    test('match：自定义优先、预设回退、无匹配返回 null', () {
      final custom = <AssistantPlatform>[
        AssistantPlatform.fromJson(<String, dynamic>{
          'id': 'c1',
          'name': '自建',
          'baseUrl': 'https://api.example.com/v1',
          'models': <String>['m1'],
        }),
      ];
      expect(
        AssistantPlatform.match('https://api.example.com/v1', custom)!.name,
        '自建',
      );
      expect(
        AssistantPlatform.match('https://api.deepseek.com/v1', custom)!.name,
        'DeepSeek',
      );
      expect(AssistantPlatform.match('https://unknown.example/v1', custom),
          isNull);
      // 不传自定义列表时保持旧行为（只匹配预设）
      expect(AssistantPlatform.match('https://api.example.com/v1'), isNull);
      expect(
        AssistantPlatform.all(custom).length,
        AssistantPlatform.presets.length + 1,
      );
    });

    test('GLM 预设含最新官方模型，isKnownModel 忽略大小写与空格', () {
      final glm =
          AssistantPlatform.match('https://open.bigmodel.cn/api/paas/v4')!;
      expect(glm.name, '智谱 GLM');
      for (final m in <String>[
        'glm-5.3',
        'glm-5.3-flash',
        'glm-4.6',
        'glm-4.5-flash',
        'glm-4.7-flash',
      ]) {
        expect(glm.models, contains(m), reason: '$m 应为 GLM 预设模型');
        expect(isKnownModel(m, glm), isTrue);
      }
      // 官方展示名大小写 / 粘贴空格都不再误报。
      expect(isKnownModel(' GLM-5.3-Flash ', glm), isTrue);
      expect(isKnownModel('GLM-4.6', glm), isTrue);
      expect(isKnownModel('my-custom-model', glm), isFalse);
      expect(isKnownModel('', glm), isTrue, reason: '空值交给默认回退，不提示');
    });

    test('其余预设平台模型记录跟随官方更新（2026-11）', () {
      void expectModels(String url, List<String> models) {
        final p = AssistantPlatform.match(url)!;
        for (final m in models) {
          expect(p.models, contains(m), reason: '$url 应含 $m');
        }
      }

      expectModels('https://api.deepseek.com/v1', <String>[
        'deepseek-v4-flash',
        'deepseek-v4-pro',
      ]);
      // 官方仍兼容的旧别名保留给已有配置。
      expectModels('https://api.deepseek.com/v1', <String>[
        'deepseek-chat',
        'deepseek-reasoner',
      ]);
      expectModels('https://dashscope.aliyuncs.com/compatible-mode/v1',
          <String>['qwen3.8-max', 'qwen3.8-flash', 'qwen-plus']);
      // moonshot-v1 / kimi-k2 系列已下线，不应再作为推荐出现。
      final kimi = AssistantPlatform.match('https://api.moonshot.cn/v1')!;
      for (final m in <String>['kimi-k3.1-pro', 'kimi-k3', 'kimi-k2.6']) {
        expect(kimi.models, contains(m));
      }
      expect(kimi.models, isNot(contains('moonshot-v1-8k')));
      expect(kimi.models, isNot(contains('kimi-k2-turbo-preview')));
      expectModels('https://api.siliconflow.cn/v1', <String>[
        'deepseek-ai/DeepSeek-V4.1-Flash',
        'zai-org/GLM-5.3-Flash',
      ]);
      expectModels('https://api.openai.com/v1', <String>[
        'gpt-5.5',
        'gpt-5.4',
        'gpt-5-mini',
      ]);
    });
  });

  test('自定义平台 CRUD 与重启后持久化', () async {
    final settings = SettingsController.instance;
    final p = await settings.addCustomAssistantPlatform(
      name: '某厂商',
      baseUrl: 'https://api.example.com/v1',
      models: <String>['m1', 'm2'],
    );
    expect(settings.customAssistantPlatforms.length, 1);
    expect(
      AssistantPlatform.match(
              'https://api.example.com/v1', settings.customAssistantPlatforms)!
          .name,
      '某厂商',
    );

    await settings.updateCustomAssistantPlatform(
      p.id,
      name: '新名字',
      baseUrl: 'https://api.example.com/v2',
      models: <String>['m2'],
    );
    expect(settings.customAssistantPlatforms.single.name, '新名字');
    expect(settings.customAssistantPlatforms.single.models, <String>['m2']);

    // 重新 load 模拟重启，自定义平台不应丢失
    settings.resetForTest();
    await settings.load();
    expect(settings.customAssistantPlatforms.length, 1);
    expect(settings.customAssistantPlatforms.single.name, '新名字');

    await settings.removeCustomAssistantPlatform(p.id);
    settings.resetForTest();
    await settings.load();
    expect(settings.customAssistantPlatforms, isEmpty);
  });

  group('配置编辑页：自定义平台', () {
    testWidgets('显示入口，新建后自动填充接口地址与模型', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: AssistantProfileEditPage()),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('add-custom-platform')), findsOneWidget);
      expect(find.text(tr('平台')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('add-custom-platform')));
      await tester.pumpAndSettle();
      expect(find.text(tr('新建自定义平台')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('cp-name')), '某厂商');
      await tester.enterText(
          find.byKey(const ValueKey('cp-url')), 'https://api.example.com/v1');
      await tester.enterText(find.byKey(const ValueKey('cp-models')), 'm1, m2');
      await tester.tap(find.byKey(const ValueKey('cp-save')));
      await tester.pumpAndSettle();

      expect(find.text('某厂商'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('profile-base-url')))
            .controller!
            .text,
        'https://api.example.com/v1',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('profile-model')))
            .controller!
            .text,
        'm1',
      );
      expect(
        SettingsController.instance.customAssistantPlatforms.length,
        1,
      );
    });

    testWidgets('表单校验：平台名称为空时提示', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: AssistantProfileEditPage()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-custom-platform')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('cp-save')));
      await tester.pumpAndSettle();
      expect(find.text(tr('请填写平台名称')), findsOneWidget);
      expect(
        SettingsController.instance.customAssistantPlatforms,
        isEmpty,
      );
    });

    testWidgets('选中自定义平台后可编辑删除', (tester) async {
      await SettingsController.instance.addCustomAssistantPlatform(
        name: '待删除',
        baseUrl: 'https://del.example/v1',
        models: <String>['m1'],
      );
      await tester.pumpWidget(
        const MaterialApp(home: AssistantProfileEditPage()),
      );
      await tester.pumpAndSettle();

      // 填入自定义平台的接口地址后，平台识别为该自定义平台并出现编辑入口。
      await tester.enterText(find.byKey(const ValueKey('profile-base-url')),
          'https://del.example/v1');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-edit-custom-platform')),
        findsOneWidget,
      );
      await tester
          .tap(find.byKey(const ValueKey('profile-edit-custom-platform')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr('删除')).first);
      await tester.pumpAndSettle();
      expect(find.text(tr('删除该平台？')), findsOneWidget);

      await tester.tap(find.text(tr('删除')).last);
      await tester.pumpAndSettle();
      expect(
        SettingsController.instance.customAssistantPlatforms,
        isEmpty,
      );
    });
  });
}
