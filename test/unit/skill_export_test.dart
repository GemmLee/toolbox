import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/core/storage/app_files.dart';
import 'package:toolbox/features/tools/assistant/data/skill_markdown.dart';
import 'package:toolbox/features/tools/assistant/data/skills.dart';
import 'package:toolbox/features/tools/assistant/ui/skill_manage_page.dart';

/// 技能导出：Markdown 可再次导入 + 写入存储空间 assistant 分类。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('导出 Markdown 含 frontmatter 与原样提示词', () {
    final skill = SkillStore.builtIns.first;
    final text = SkillStore.exportMarkdown(skill);
    expect(text.startsWith('---\n'), isTrue);
    final doc = SkillMarkdown.parse(text);
    expect(doc.name, skill.name);
    expect(doc.description, skill.description);
    expect(doc.prompt, skill.prompt);
  });

  test('内置技能来自 md 源文件，提示词正文不含 frontmatter', () {
    final skill = SkillStore.builtIns.first;
    expect(skill.prompt.startsWith('---'), isFalse);
    expect(skill.prompt, contains('你是题库格式转换专家'));
    expect(SkillMarkdown.parse(kQuizConvertSkillMarkdown).prompt, skill.prompt);
  });

  test('技能导出到存储空间 assistant 分类，文件为 .md', () async {
    final root = await Directory.systemTemp.createTemp('skill_export_test');
    AppStore.useRootForTest(root);
    addTearDown(() async {
      AppStore.useRootForTest(null);
      if (root.existsSync()) await root.delete(recursive: true);
    });

    final skill = SkillStore.builtIns.first;
    final file = await AppStore.saveText(
      category: AppStoreCategory.assistant,
      name: '${skill.name}.md',
      content: SkillStore.exportMarkdown(skill),
    );
    expect(file.category, AppStoreCategory.assistant);
    expect(file.name, '${skill.name}.md');

    final listed = await AppStore.listOf(AppStoreCategory.assistant);
    expect(listed.single.name, '${skill.name}.md');
    final content = await listed.single.file.readAsString();
    expect(SkillMarkdown.parse(content).name, skill.name);
    expect(SkillMarkdown.parse(content).prompt, skill.prompt);
  });

  testWidgets('技能管理每个技能（含预置）都有导出按钮', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const MaterialApp(home: SkillManagePage()));
    await tester.pumpAndSettle();

    // 预置技能也必须可导出。
    expect(
      find.byKey(const ValueKey('skill-export-builtin-quiz-convert')),
      findsOneWidget,
    );
  });
}
