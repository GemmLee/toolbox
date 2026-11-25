import 'dart:convert';

/// 技能文件的 Markdown 表示，对齐主流 `SKILL.md` 约定：
///
/// ```markdown
/// ---
/// name: "技能名称"
/// description: "一句话描述"
/// ---
///
/// 这里是注入到对话开头的系统提示词（正文全文）。
/// ```
///
/// 头信息只放元数据，**正文整段就是提示词**；正文里出现 `---`、代码块、
/// `#` 标题等都原样保留，不会被当成头信息，避免语义歧义。
class SkillMarkdown {
  const SkillMarkdown._();

  static const String delimiter = '---';

  /// 生成可再次导入的 Markdown 技能文件。
  static String encode({
    required String name,
    required String description,
    required String prompt,
  }) {
    final buffer = StringBuffer()
      ..writeln(delimiter)
      ..writeln('name: ${_quote(name.trim())}')
      ..writeln('description: ${_quote(description.trim())}')
      ..writeln(delimiter)
      ..writeln()
      ..write(prompt.trim());
    buffer.writeln();
    return buffer.toString();
  }

  /// 解析 Markdown 技能文件。
  ///
  /// 优先读取开头的 YAML frontmatter；没有 frontmatter 时兼容旧版
  /// 「首个 `# 标题` 为名称、首个 `> 引用` 为描述」的写法。
  /// [fallbackName] 用于既无 frontmatter 也无标题行时（通常取文件名）。
  static SkillMarkdownDoc parse(String content, {String fallbackName = ''}) {
    final normalized = content
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final lines = const LineSplitter().convert(normalized);

    var cursor = 0;
    while (cursor < lines.length && lines[cursor].trim().isEmpty) {
      cursor++;
    }

    var name = '';
    var description = '';
    var bodyStart = cursor;

    // 只有位于文件最开头的 ```---``` 块才被视作 frontmatter；正文里的
    // 分割线始终留在提示词中。
    if (cursor < lines.length && lines[cursor].trim() == delimiter) {
      var end = -1;
      for (var i = cursor + 1; i < lines.length; i++) {
        if (lines[i].trim() == delimiter) {
          end = i;
          break;
        }
      }
      if (end > cursor) {
        for (final line in lines.sublist(cursor + 1, end)) {
          final entry = _entryOf(line);
          if (entry == null) continue;
          switch (entry.key) {
            case 'name' || 'title':
              name = entry.value;
            case 'description' || 'desc':
              description = entry.value;
          }
        }
        bodyStart = end + 1;
        while (bodyStart < lines.length && lines[bodyStart].trim().isEmpty) {
          bodyStart++;
        }
      }
    }

    var prompt = lines.skip(bodyStart).join('\n').trim();

    // 旧版纯 Markdown：把开头的标题 / 引用行抽出来，其余仍是提示词。
    if (name.isEmpty) {
      final bodyLines = const LineSplitter().convert(prompt);
      var i = 0;
      for (; i < bodyLines.length; i++) {
        final line = bodyLines[i].trim();
        if (line.isEmpty) continue;
        if (line.startsWith('# ')) {
          name = line.substring(2).trim();
          continue;
        }
        if (line.startsWith('> ') && name.isNotEmpty) {
          description = line.substring(2).trim();
          continue;
        }
        break;
      }
      prompt = bodyLines.skip(i).join('\n').trim();
    }

    if (name.isEmpty) name = fallbackName.trim();
    return SkillMarkdownDoc(
      name: name.trim(),
      description: description.trim(),
      prompt: prompt,
    );
  }

  /// frontmatter 里的 `key: value` 行；忽略注释与空行。
  static ({String key, String value})? _entryOf(String line) {
    final text = line.trim();
    if (text.isEmpty || text.startsWith('#') || text.startsWith('//')) {
      return null;
    }
    final colon = text.indexOf(':');
    if (colon <= 0) return null;
    return (
      key: text.substring(0, colon).trim().toLowerCase(),
      value: _unquote(text.substring(colon + 1).trim()),
    );
  }

  /// 双引号标量：转义反斜杠 / 引号 / 换行，避免名称描述里的特殊字符产生歧义。
  static String _quote(String value) {
    final escaped = value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
    return '"$escaped"';
  }

  static String _unquote(String raw) {
    if (raw.length < 2) return raw;
    if (raw.startsWith('"') && raw.endsWith('"')) {
      final inner = raw.substring(1, raw.length - 1);
      final out = StringBuffer();
      for (var i = 0; i < inner.length; i++) {
        if (inner[i] == '\\' && i + 1 < inner.length) {
          final next = inner[i + 1];
          out.write(switch (next) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '"' => '"',
            '\\' => '\\',
            _ => next,
          });
          i++;
        } else {
          out.write(inner[i]);
        }
      }
      return out.toString();
    }
    if (raw.startsWith("'") && raw.endsWith("'")) {
      return raw.substring(1, raw.length - 1).replaceAll("''", "'");
    }
    return raw;
  }
}

/// [SkillMarkdown.parse] 的结果：名称、描述与整段系统提示词。
class SkillMarkdownDoc {
  const SkillMarkdownDoc({
    required this.name,
    required this.description,
    required this.prompt,
  });

  final String name;
  final String description;
  final String prompt;

  bool get isValid => name.trim().isNotEmpty && prompt.trim().isNotEmpty;
}
