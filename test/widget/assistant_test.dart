import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/core/settings/tool_texts.dart';
import 'package:toolbox/features/tools/assistant/data/assistant_api.dart';
import 'package:toolbox/features/tools/assistant/data/skills.dart';
import 'package:toolbox/features/tools/assistant/logic/assistant_controller.dart';
import 'package:toolbox/features/tools/assistant/ui/assistant_bubble.dart';
import 'package:toolbox/features/tools/assistant/ui/assistant_page.dart';

void main() {
  // ---------- 气泡布局 ----------
  testWidgets('复制按钮在气泡下方（气泡外侧），不挤在气泡里', (tester) async {
    tester.view.physicalSize = const Size(1080, 1600);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final data = AssistantBubbleData.of(
        const ChatMessage(role: 'assistant', content: 'hello world'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: <Widget>[AssistantBubble(data: data)]),
      ),
    ));
    await tester.pumpAndSettle();

    final textRect = tester.getRect(find.text('hello world'));
    final buttonRect = tester.getRect(find.byIcon(Icons.copy_outlined));
    expect(buttonRect.top, greaterThan(textRect.bottom),
        reason: '按钮必须落在气泡下沿之外');
    expect(buttonRect.left, lessThan(textRect.left));
  });

  // ---------- 模型选择上拉面板 ----------
  testWidgets('聊天框下方点击/上拉选择模型', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsController.instance;
    settings.resetForTest();
    await settings.load();
    settings.setLanguage(AppLanguage.simplifiedChinese);
    await settings.addAssistantProfile(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
      apiKey: 'sk-test',
    );
    AssistantController.instance.resetForTest();
    await AssistantController.instance.load();

    await tester.pumpWidget(const MaterialApp(home: AssistantPage()));
    await tester.pumpAndSettle();

    // 模型条显示当前模型
    final bar = find.byKey(const ValueKey('assistant-model-bar'));
    expect(bar, findsOneWidget);
    expect(find.textContaining('deepseek-chat'), findsWidgets);

    // 点击打开模型面板（预设平台的模型列表）
    await tester.tap(bar);
    await tester.pumpAndSettle();
    expect(find.text(tr('选择模型')), findsOneWidget);
    expect(find.text('deepseek-reasoner'), findsOneWidget);

    await tester.tap(find.text('deepseek-reasoner'));
    await tester.pumpAndSettle();
    expect(settings.assistantModel, 'deepseek-reasoner');

    // 上拉也能打开面板
    await tester.fling(bar, const Offset(0, -50), 900);
    await tester.pumpAndSettle();
    expect(find.text(tr('选择模型')), findsOneWidget);

    // 手动输入模型名
    await tester.enterText(find.byType(TextField).last, 'my-model');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.assistantModel, 'my-model');
  });

  testWidgets('空态去掉中央小字与设置按钮，技能入口移到模型同一行右侧', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsController.instance;
    settings.resetForTest();
    await settings.load();
    settings.setLanguage(AppLanguage.simplifiedChinese);
    await settings.addAssistantProfile(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
      apiKey: 'sk-test',
    );
    AssistantController.instance.resetForTest();
    await AssistantController.instance.load();

    await tester.pumpWidget(const MaterialApp(home: AssistantPage()));
    await tester.pumpAndSettle();

    expect(
      find.text('支持上传 Word / Excel / 文本文件；题库转换结果可一键导入「刷题助手」'),
      findsNothing,
    );
    expect(find.widgetWithText(TextButton, '智能助手设置'), findsNothing,
        reason: '屏幕中央不再放设置按钮（侧栏入口保留）');
    expect(find.text('和 DeepSeek 聊一聊'), findsOneWidget, reason: '中央文案跟随当前模型');

    final model =
        tester.getRect(find.byKey(const ValueKey('assistant-model-bar')));
    final skill =
        tester.getRect(find.byKey(const ValueKey('assistant-skill-button')));
    expect(skill.left, greaterThan(model.left), reason: '模型在左、技能在最右');
    expect((skill.center.dy - model.center.dy).abs(), lessThan(8),
        reason: '两个入口同一行');

    await tester.tap(find.byKey(const ValueKey('assistant-skill-button')));
    await tester.pumpAndSettle();
    expect(find.text(tr('选择技能')), findsOneWidget);
  });

  testWidgets('空态中央文案随技能切换为「和 X 一起处理「技能」」', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsController.instance;
    settings.resetForTest();
    await settings.load();
    settings.setLanguage(AppLanguage.simplifiedChinese);
    await settings.addAssistantProfile(
      name: 'GLM',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-5.3',
      apiKey: 'sk-test',
    );
    final controller = AssistantController.instance;
    controller.resetForTest();
    await controller.load();

    await tester.pumpWidget(const MaterialApp(home: AssistantPage()));
    await tester.pumpAndSettle();
    expect(find.text('和 GLM 聊一聊'), findsOneWidget);

    await controller.selectSkill(const AssistantSkill(
      id: 'skill-test',
      name: '整理文档',
      description: '整理',
      prompt: '整理',
    ));
    await tester.pumpAndSettle();
    expect(find.text('和 GLM 一起处理「整理文档」'), findsOneWidget);
  });
}
