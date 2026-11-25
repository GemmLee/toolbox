import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/assistant/data/skill_markdown.dart';

void main() {
  group('SkillMarkdown 解析', () {
    test('frontmatter 给出名称与描述，正文整段是提示词', () {
      const md = '''
---
name: 题库转换
description: 把题目转成题库 JSON
---

你是题库转换专家。

## 规则
1. 只输出 JSON
2. 不要输出 options
''';
      final doc = SkillMarkdown.parse(md);
      expect(doc.name, '题库转换');
      expect(doc.description, '把题目转成题库 JSON');
      expect(doc.prompt, '你是题库转换专家。\n\n## 规则\n1. 只输出 JSON\n2. 不要输出 options');
      expect(doc.isValid, isTrue);
    });

    test('编码后再解析：特殊字符与正文里的 --- 不丢、不歧义', () {
      const prompt = '# 说明\n\n---\n这是一条分割线，不是 frontmatter。\n\n```json\n{"a": 1}\n```';
      final text = SkillMarkdown.encode(
        name: '写作: "助手"',
        description: '第一行\n第二行 "带引号"',
        prompt: prompt,
      );
      final doc = SkillMarkdown.parse(text);
      expect(doc.name, '写作: "助手"');
      expect(doc.description, '第一行\n第二行 "带引号"');
      expect(doc.prompt, prompt);
      // 正文中的 --- 不应被当成第二个 frontmatter 边界。
      expect(doc.prompt, contains('---\n这是一条分割线'));
    });

    test('兼容旧版「首个 # 为名称、> 为描述」', () {
      const md = '# 中英互译\n> 把输入翻译成另一种语言\n你是翻译助手，逐句翻译。';
      final doc = SkillMarkdown.parse(md);
      expect(doc.name, '中英互译');
      expect(doc.description, '把输入翻译成另一种语言');
      expect(doc.prompt, '你是翻译助手，逐句翻译。');
    });

    test('无名称时用文件名，全文当提示词', () {
      final doc = SkillMarkdown.parse(
        '你是一个简洁的助手。\n不要编造信息。',
        fallbackName: '简洁助手',
      );
      expect(doc.name, '简洁助手');
      expect(doc.prompt, '你是一个简洁的助手。\n不要编造信息。');
      expect(doc.description, isEmpty);
    });

    test('BOM 与 CRLF 归一化', () {
      final doc = SkillMarkdown.parse(
        '\uFEFF---\r\nname: 测试\r\ndescription: 描述\r\n---\r\n\r\n正文第一行\r\n正文第二行\r\n',
      );
      expect(doc.name, '测试');
      expect(doc.description, '描述');
      expect(doc.prompt, '正文第一行\n正文第二行');
    });

    test('只有 frontmatter 没有正文视为无效', () {
      final doc = SkillMarkdown.parse(
        '---\nname: 空技能\ndescription: 没有提示词\n---\n',
      );
      expect(doc.name, '空技能');
      expect(doc.prompt, isEmpty);
      expect(doc.isValid, isFalse);
    });
  });
}
