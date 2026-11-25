import 'dart:convert';

import '../../../../core/storage/local_store.dart';
import 'skill_markdown.dart';

/// 智能助手技能：一段注入到对话开头的系统提示词。
class AssistantSkill {
  const AssistantSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.prompt,
    this.builtIn = false,
  });

  final String id;
  final String name;
  final String description;
  final String prompt;

  final bool builtIn;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        'prompt': prompt,
      };

  static AssistantSkill fromJson(Map<String, dynamic> json) => AssistantSkill(
        id: json['id'] as String? ?? _newSkillId(),
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
      );
}

String _newSkillId() {
  _skillIdSeq++;
  return 'custom-${DateTime.now().microsecondsSinceEpoch}-$_skillIdSeq';
}

int _skillIdSeq = 0;

/// 通用对话的默认系统提示词。
const String kDefaultSystemPrompt = '你是 XMtools 内置的智能助手。'
    '用简体中文简洁、准确地回答问题；'
    '如果用户给出文件内容，先概括再按要求处理；'
    '不要编造不确定的信息。';

/// 内置「题库转换」技能的 Markdown 源文件，对齐主流 `SKILL.md`：
/// frontmatter 只放 name / description，正文整段就是注入对话的系统提示词。
///
/// 正文与旧版 JSON 技能里的 prompt 逐字一致（仅去掉首尾空白），
/// 因此助手对话与刷题 AI 转换拿到的规则完全不变。
const String kQuizConvertSkillMarkdown = '''
---
name: 题库转换
description: 把 Word / Excel / 文本里的题目转成可导入的题库 JSON
---

你是题库格式转换专家。把用户提供的题目内容转换为下面的 JSON 题库格式。

## 顶层结构
{"version": 1, "bankName": "题库名", "questions": [ ... ]}
- version 固定为 1；bankName 从内容推断或用源文件名；questions 不能为空。
- 只输出一个 JSON 对象，不要输出任何解释文字，不要用 ``` 代码块包裹。
- 紧凑输出：整个 JSON 写在一行，不要缩进、换行和多余空格；没有内容的可选字段
  （id / analysis / tags / difficulty / score）直接省略，不要写 null 或空字符串。
  输出越短越不容易在中途被截断，App 会自动把它存成 .json 文件，不需要你排版。
- 题目很多时（单次 40 道以上）仍按紧凑格式全部输出；若接近长度上限，
  优先保证题干、选项、答案完整，省略可选字段而不是漏题。

## 每道题的字段
- id：可省略；若源内容有题号，写成 "q-001" 形式。
- type（必填，以下之一或别名）：
  * "single" 单选：options 至少 2 个；answer 恰好 1 个选项 key。
  * "multiple" 多选：options 至少 2 个；answer 为 1 个及以上选项 key。
  * "true_false" 判断（别名 trueFalse/boolean）：answer 必须是 ["true"] 或 ["false"]；**不要输出 options 字段**，App 会自动补「正确 / 错误」两个选项。
  * "fill" 填空（别名 fill_blank/blank）：不要 options；answer 为可接受答案数组，把同义写法都列上。
  * "short" 简答（别名 short_answer/essay）：不要 options；answer 为参考答案。
- stem（必填）：题干，保留原文，不要改写。
- options：对象数组 [{"key": "A", "text": "选项内容"}, ...]；key 用 A/B/C/D；answer 只能写 key，不能写选项文本。
- analysis：解析，源内容有就填，没有可省略。
- tags：字符串数组标签，可省略；difficulty：1-5 整数，可省略；score：数字分值，可省略。

## 判分相关的硬性规则（违反会被 App 拒绝导入）
1. answer 里的每个 key 必须能在 options.key 里找到。
2. 单选 answer 只能 1 项；多选要列全所有正确项。
3. 判断题答案只能是 ["true"] 或 ["false"]，正确写 ["true"]，错误写 ["false"]。
4. 填空题把数字、汉字、英文等所有合理写法都放进 answer 数组。
5. 不认识的题型：能推断成五种之一的按最接近的转换，并在 analysis 里注明「由源题型 X 转换」；完全无法判断的丢弃并在 analysis 无从体现时直接省略（宁可少一道，不要编造）。
6. **判断题绝不输出 options**：源文档里的 T / F、√ / ×、对 / 错、A / B、正确 / 错误、「T. 正确」「true正确」等标记都只是判断依据，只用来决定 answer 是 true 还是 false；这些标记禁止出现在 stem、options 或任何选项文本里，也不要把 true / false 写成选项 key。App 只用「正确」「错误」两个选项，多写标识符会重复显示。

## 其他
- 保持源题目顺序；重复题目只保留一次。
- 输出前自查：JSON 合法（无尾逗号、引号转义）、answer key 都存在、单选只有 1 个答案、判断题没有 options 且选项文本不含 T/F。
''';

/// 技能仓库：预置技能 + 用户自定义技能（存 LocalStore）。
///
/// 技能文件统一用 Markdown（YAML frontmatter + 提示词正文）；
/// 旧版 `.json` 导出文件仍可导入，避免历史技能失效。
class SkillStore {
  SkillStore._();

  static const String _storeKey = 'assistant_skills';

  /// 预置「题库转换」技能 id：长文档会自动分段转换。
  static const String quizSkillId = 'builtin-quiz-convert';

  /// 预置技能：由 Markdown 源文件解析，和导入的技能走同一套解析逻辑。
  static final List<AssistantSkill> builtIns = <AssistantSkill>[
    _builtIn(quizSkillId, kQuizConvertSkillMarkdown),
  ];

  static AssistantSkill _builtIn(String id, String markdown) {
    final doc = SkillMarkdown.parse(markdown, fallbackName: '题库转换');
    return AssistantSkill(
      id: id,
      name: doc.name,
      description: doc.description,
      prompt: doc.prompt,
      builtIn: true,
    );
  }

  /// 全部技能：预置在前，自定义在后。
  static Future<List<AssistantSkill>> all() async {
    await migrateLegacyCustoms();
    final customs = await listCustom();
    return <AssistantSkill>[...builtIns, ...customs];
  }

  /// 清理旧版本残留。
  ///
  /// 早期内置技能是 JSON（`{"name": ..., "prompt": ...}`），用户导出后再导入
  /// 会在自定义技能里留下一份**提示词就是整段 JSON** 的副本，看起来像
  /// 「内置技能还是 JSON 格式」。这里把这类副本解包成正常技能，并删掉与内置
  /// 技能重复的条目；其余自定义技能原样保留。
  static Future<void> migrateLegacyCustoms() async {
    final customs = await listCustom();
    if (customs.isEmpty) return;
    var changed = false;
    final out = <AssistantSkill>[];
    for (final original in customs) {
      var skill = original;
      var fromJson = false;
      final head = original.prompt.trimLeft();
      if (head.startsWith('{')) {
        try {
          final decoded = jsonDecode(head);
          if (decoded is Map) {
            final prompt = (decoded['prompt'] ??
                    decoded['systemPrompt'] ??
                    decoded['content'] ??
                    '')
                .toString()
                .trim();
            if (prompt.isNotEmpty) {
              final name = (decoded['name'] ?? decoded['title'] ?? '')
                  .toString()
                  .trim();
              skill = AssistantSkill(
                id: original.id,
                name: name.isEmpty ? original.name : name,
                description: original.description.isNotEmpty
                    ? original.description
                    : (decoded['description'] ?? '').toString(),
                prompt: prompt,
              );
              fromJson = true;
              changed = true;
            }
          }
        } on FormatException {
          // 提示词本身以 { 开头但不是 JSON，属于正常内容，保持原样。
        }
      }
      final clashBuiltIn = builtIns.any(
        (b) =>
            b.name == skill.name &&
            (fromJson || b.prompt.trim() == skill.prompt.trim()),
      );
      if (clashBuiltIn) {
        changed = true;
        continue;
      }
      out.add(skill);
    }
    if (changed) await _write(out);
  }

  /// 导出为可再次导入的 Markdown 文本。
  static String exportMarkdown(AssistantSkill skill) => SkillMarkdown.encode(
        name: skill.name,
        description: skill.description,
        prompt: skill.prompt,
      );

  static Future<List<AssistantSkill>> listCustom() async {
    final map = await LocalStore.readMap(_storeKey);
    final raw = map?['skills'];
    if (raw is! List) return const <AssistantSkill>[];
    return raw
        .whereType<Map>()
        .map((e) => AssistantSkill.fromJson(Map<String, dynamic>.from(e)))
        .where((s) => s.name.isNotEmpty && s.prompt.isNotEmpty)
        .toList(growable: false);
  }

  static Future<void> _write(List<AssistantSkill> skills) async {
    await LocalStore.writeMap(_storeKey, <String, dynamic>{
      'skills': skills.map((s) => s.toJson()).toList(),
    });
  }

  /// 新增自定义技能（重名自动加后缀）。
  static Future<AssistantSkill> add({
    required String name,
    required String description,
    required String prompt,
  }) async {
    final skills = <AssistantSkill>[...await listCustom()];
    var finalName = name.trim();
    final existing = skills.map((s) => s.name).toSet();
    var i = 2;
    while (existing.contains(finalName)) {
      finalName = '${name.trim()} ($i)';
      i++;
    }
    final skill = AssistantSkill(
      id: _newSkillId(),
      name: finalName,
      description: description.trim(),
      prompt: prompt.trim(),
    );
    skills.add(skill);
    await _write(skills);
    return skill;
  }

  static Future<void> remove(String id) async {
    final skills = <AssistantSkill>[...await listCustom()];
    skills.removeWhere((s) => s.id == id);
    await _write(skills);
  }

  /// 修改自定义技能（预置技能不可改，直接忽略）。
  static Future<void> update(
    String id, {
    required String name,
    required String description,
    required String prompt,
  }) async {
    final skills = <AssistantSkill>[...await listCustom()];
    final index = skills.indexWhere((s) => s.id == id);
    if (index < 0) return;
    skills[index] = AssistantSkill(
      id: id,
      name: name.trim(),
      description: description.trim(),
      prompt: prompt.trim(),
    );
    await _write(skills);
  }

  /// 从文件内容导入技能。
  ///
  /// 默认 Markdown：开头 frontmatter 写 name / description，正文全文是提示词；
  /// 也兼容旧版「首个 `#` 为名称、`>` 为描述」和 `.json`（含 name 与 prompt）。
  static Future<AssistantSkill> importFromFile({
    required String fileName,
    required String content,
  }) async {
    final lower = fileName.toLowerCase();
    final head = content.trimLeft().replaceFirst('\uFEFF', '');
    if (lower.endsWith('.json') || head.startsWith('{')) {
      Object? decoded;
      try {
        decoded = jsonDecode(head);
      } on FormatException catch (e) {
        throw FormatException('技能文件不是合法 JSON：$e');
      }
      if (decoded is! Map) throw const FormatException('技能文件根节点应为 JSON 对象');
      final name = (decoded['name'] ?? decoded['title'] ?? '').toString().trim();
      final prompt = (decoded['prompt'] ??
              decoded['systemPrompt'] ??
              decoded['content'] ??
              '')
          .toString()
          .trim();
      if (name.isEmpty || prompt.isEmpty) {
        throw const FormatException('技能 JSON 需要包含 name 与 prompt 字段');
      }
      return add(
        name: name,
        description: (decoded['description'] ?? '').toString(),
        prompt: prompt,
      );
    }

    final doc = SkillMarkdown.parse(content, fallbackName: _nameOf(fileName));
    if (!doc.isValid) {
      throw const FormatException('技能 Markdown 需要名称与正文提示词');
    }
    return add(
      name: doc.name,
      description: doc.description,
      prompt: doc.prompt,
    );
  }

  static String _nameOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }
}
