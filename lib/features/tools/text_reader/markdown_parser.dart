/// 轻量 Markdown 解析：只覆盖阅读场景常用语法，避免引入渲染库。
///
/// 支持：#~###### 标题、**粗体** / *斜体* / ~~删除线~~ / `行内代码` /
/// [链接](url)、无序与有序列表（含任务列表与缩进层级）、> 引用、
/// | 表格 |、``` 代码块、--- 分割线。
library;

enum MdBlockKind {
  heading,
  paragraph,
  bulletList,
  orderedList,
  quote,
  code,
  divider,
  table,
}

/// 表格列对齐（来自分隔行 `:---:`）。
enum MdAlign { left, center, right }

class MdBlock {
  const MdBlock({
    required this.kind,
    this.text = '',
    this.level = 0,
    this.items = const <String>[],
    this.indents = const <int>[],
    this.checked = const <bool?>[],
    this.header = const <String>[],
    this.rows = const <List<String>>[],
    this.aligns = const <MdAlign>[],
    this.language = '',
  });

  final MdBlockKind kind;
  final String text;
  final int level;
  final List<String> items;

  /// 列表项缩进层级，与 [items] 一一对应（0 为顶层）。
  final List<int> indents;

  /// 任务列表勾选状态，与 [items] 一一对应；null 表示普通列表项。
  final List<bool?> checked;

  /// 表格表头单元格。
  final List<String> header;

  /// 表格数据行（已按表头列数补齐）。
  final List<List<String>> rows;

  /// 表格每列对齐，与 [header] 一一对应。
  final List<MdAlign> aligns;

  final String language;
}

enum MdInlineKind { text, bold, italic, code, link, strike }

class MdInline {
  const MdInline(this.kind, this.text, {this.href = ''});

  final MdInlineKind kind;
  final String text;
  final String href;
}

class MarkdownParser {
  MarkdownParser._();

  static final RegExp _heading = RegExp(r'^(#{1,6})\s+(.*)$');
  static final RegExp _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
  static final RegExp _ordered = RegExp(r'^(\s*)\d+[.)]\s+(.*)$');
  static final RegExp _quote = RegExp(r'^\s*>\s?(.*)$');
  static final RegExp _divider = RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$');
  static final RegExp _task = RegExp(r'^\[([ xX])\]\s+(.*)$');
  static final RegExp _separatorCell = RegExp(r'^:?-{1,}:?$');
  static final RegExp _inline = RegExp(
    r'(`[^`]+`|!?\[[^\]]*\]\([^)]+\)|\*\*[^*]+\*\*|__[^_]+__|~~[^~]+~~|\*[^*]+\*|_[^_]+_)',
  );

  static List<MdBlock> parse(String source) {
    final lines = source
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final blocks = <MdBlock>[];
    final paragraph = <String>[];
    final quote = <String>[];
    final items = <String>[];
    final indents = <int>[];
    final checked = <bool?>[];
    final code = <String>[];
    var listKind = MdBlockKind.paragraph;
    var inCode = false;
    var codeLanguage = '';

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      blocks.add(MdBlock(kind: MdBlockKind.paragraph, text: paragraph.join('\n')));
      paragraph.clear();
    }

    void flushQuote() {
      if (quote.isEmpty) return;
      blocks.add(MdBlock(kind: MdBlockKind.quote, text: quote.join('\n')));
      quote.clear();
    }

    void flushList() {
      if (items.isEmpty) return;
      blocks.add(MdBlock(
        kind: listKind,
        items: List<String>.of(items),
        indents: List<int>.of(indents),
        checked: List<bool?>.of(checked),
      ));
      items.clear();
      indents.clear();
      checked.clear();
      listKind = MdBlockKind.paragraph;
    }

    void flushAll() {
      flushParagraph();
      flushQuote();
      flushList();
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('```')) {
        if (inCode) {
          blocks.add(MdBlock(
            kind: MdBlockKind.code,
            text: code.join('\n'),
            language: codeLanguage,
          ));
          code.clear();
          codeLanguage = '';
          inCode = false;
        } else {
          flushAll();
          codeLanguage = trimmed.substring(3).trim();
          inCode = true;
        }
        continue;
      }
      if (inCode) {
        code.add(line);
        continue;
      }
      if (line.trim().isEmpty) {
        flushAll();
        continue;
      }
      if (_divider.hasMatch(line)) {
        flushAll();
        blocks.add(const MdBlock(kind: MdBlockKind.divider));
        continue;
      }
      // 表格：当前行是表头、下一行是 |---|:--:| 分隔行时才成立。
      if (_looksLikeRow(line) && i + 1 < lines.length &&
          _isTableSeparator(lines[i + 1])) {
        final header = splitRow(line);
        final aligns = splitRow(lines[i + 1])
            .map(_alignOf)
            .toList(growable: false);
        final rows = <List<String>>[];
        var j = i + 2;
        while (j < lines.length &&
            lines[j].trim().isNotEmpty &&
            _looksLikeRow(lines[j])) {
          final cells = splitRow(lines[j]);
          rows.add(<String>[
            for (var c = 0; c < header.length; c++)
              c < cells.length ? cells[c] : '',
          ]);
          j++;
        }
        flushAll();
        blocks.add(MdBlock(
          kind: MdBlockKind.table,
          header: header,
          rows: rows,
          aligns: aligns.length == header.length
              ? aligns
              : List<MdAlign>.filled(header.length, MdAlign.left),
        ));
        i = j - 1;
        continue;
      }
      final heading = _heading.firstMatch(line);
      if (heading != null) {
        flushAll();
        blocks.add(MdBlock(
          kind: MdBlockKind.heading,
          level: heading.group(1)!.length,
          text: heading.group(2)!.trim(),
        ));
        continue;
      }
      final bullet = _bullet.firstMatch(line);
      final ordered = _ordered.firstMatch(line);
      if (bullet != null || ordered != null) {
        final kind = bullet != null
            ? MdBlockKind.bulletList
            : MdBlockKind.orderedList;
        flushParagraph();
        flushQuote();
        if (items.isNotEmpty && listKind != kind) flushList();
        listKind = kind;
        final match = (bullet ?? ordered)!;
        var text = match.group(2)!.trim();
        bool? done;
        final task = _task.firstMatch(text);
        if (task != null) {
          done = task.group(1)!.toLowerCase() == 'x';
          text = task.group(2)!.trim();
        }
        items.add(text);
        indents.add(_indentLevel(match.group(1)!));
        checked.add(done);
        continue;
      }
      final quoteMatch = _quote.firstMatch(line);
      if (quoteMatch != null) {
        flushParagraph();
        flushList();
        quote.add(quoteMatch.group(1)!.trim());
        continue;
      }
      flushList();
      flushQuote();
      paragraph.add(line.trimRight());
    }
    if (inCode && code.isNotEmpty) {
      blocks.add(MdBlock(
        kind: MdBlockKind.code,
        text: code.join('\n'),
        language: codeLanguage,
      ));
    }
    flushAll();
    return blocks;
  }

  /// 一行是否可能是表格行：含 `|`，且不是代码围栏。
  static bool _looksLikeRow(String line) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('```')) return false;
    return t.contains('|');
  }

  /// 分隔行：`|---|---|`、`|:--|--:|`，可省略首尾竖线。
  static bool _isTableSeparator(String line) {
    final t = line.trim();
    if (t.isEmpty || !t.contains('-')) return false;
    final cells = splitRow(t);
    if (cells.isEmpty) return false;
    return cells.every((c) => _separatorCell.hasMatch(c.trim()));
  }

  static MdAlign _alignOf(String cell) {
    final c = cell.trim();
    final left = c.startsWith(':');
    final right = c.endsWith(':');
    if (left && right) return MdAlign.center;
    if (right) return MdAlign.right;
    return MdAlign.left;
  }

  /// 拆分表格行：去掉首尾竖线，按未转义的 `|` 切分，`\|` 还原成 `|`。
  static List<String> splitRow(String line) {
    var t = line.trim();
    if (t.startsWith('|')) t = t.substring(1);
    if (t.endsWith('|') && !t.endsWith(r'\|')) {
      t = t.substring(0, t.length - 1);
    }
    final cells = <String>[];
    final buffer = StringBuffer();
    for (var i = 0; i < t.length; i++) {
      final ch = t[i];
      if (ch == r'\' && i + 1 < t.length && t[i + 1] == '|') {
        buffer.write('|');
        i++;
      } else if (ch == '|') {
        cells.add(buffer.toString().trim());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    cells.add(buffer.toString().trim());
    return cells;
  }

  /// 前导空格换算列表层级：2 空格 / 1 tab 记一级，最多 3 级。
  static int _indentLevel(String spaces) {
    var width = 0;
    for (final unit in spaces.split('')) {
      width += unit == '\t' ? 4 : 1;
    }
    return (width ~/ 2).clamp(0, 3);
  }

  static List<MdInline> parseInline(String text) {
    final out = <MdInline>[];
    var start = 0;
    for (final match in _inline.allMatches(text)) {
      if (match.start > start) {
        out.add(MdInline(MdInlineKind.text, text.substring(start, match.start)));
      }
      final raw = match.group(0)!;
      if (raw.startsWith('`')) {
        out.add(MdInline(MdInlineKind.code, raw.substring(1, raw.length - 1)));
      } else if (raw.startsWith('~~')) {
        out.add(MdInline(
          MdInlineKind.strike,
          raw.substring(2, raw.length - 2),
        ));
      } else if (raw.startsWith('**') || raw.startsWith('__')) {
        out.add(MdInline(MdInlineKind.bold, raw.substring(2, raw.length - 2)));
      } else if (raw.startsWith('*') || raw.startsWith('_')) {
        out.add(MdInline(MdInlineKind.italic, raw.substring(1, raw.length - 1)));
      } else {
        // 图片 ![alt](src) 在纯文本阅读器里按链接展示，用 alt 作为文字。
        final image = raw.startsWith('!');
        final body = image ? raw.substring(1) : raw;
        final split = body.indexOf('](');
        final label = body.substring(1, split);
        out.add(MdInline(
          MdInlineKind.link,
          label.isEmpty ? (image ? '图片' : '') : label,
          href: body.substring(split + 2, body.length - 1),
        ));
      }
      start = match.end;
    }
    if (start < text.length) {
      out.add(MdInline(MdInlineKind.text, text.substring(start)));
    }
    if (out.isEmpty) out.add(MdInline(MdInlineKind.text, text));
    return out;
  }
}
