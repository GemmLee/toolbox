import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import 'html_parser.dart';
import 'markdown_parser.dart';

/// 单文件读取上限：再大的文件一次性读进内存会 OOM，超出部分直接截断。
const int kMaxDocumentBytes = 8 * 1024 * 1024;

/// JSON 美化的体积阈值：超过后只按原文显示，避免主线程长时间卡顿。
const int kJsonFormatLimit = 600 * 1024;

/// 源码视图按块加载，每块最多这么多字符（一次布局过多字会明显掉帧）。
const int kSourceChunkChars = 6000;

bool isValidJson(String source) {
  try {
    jsonDecode(source);
    return true;
  } catch (_) {
    return false;
  }
}

/// 美化 JSON；非法内容原样返回，由 UI 给出提示。
String formatJson(String source) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(source));
  } catch (_) {
    return source;
  }
}

final RegExp _jsonToken = RegExp(
  r'"(?:\\.|[^"\\])*"\s*:|"(?:\\.|[^"\\])*"|\btrue\b|\bfalse\b|\bnull\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?',
);

/// JSON 语法着色：键 / 字符串 / 数字 / 字面量分色，其余为普通文本。
List<InlineSpan> jsonSpans(String text, TextStyle base, ColorScheme scheme) {
  final isDark = scheme.brightness == Brightness.dark;
  final keyColor = scheme.primary;
  final stringColor = isDark ? Colors.green.shade300 : Colors.green.shade800;
  final numberColor = isDark ? Colors.orange.shade300 : Colors.orange.shade900;
  final literalColor = isDark ? Colors.purple.shade200 : Colors.purple.shade700;
  final spans = <InlineSpan>[];
  var start = 0;
  for (final match in _jsonToken.allMatches(text)) {
    if (match.start > start) {
      spans
          .add(TextSpan(text: text.substring(start, match.start), style: base));
    }
    final token = match.group(0)!;
    Color color;
    if (token.startsWith('"') && token.trimRight().endsWith(':')) {
      color = keyColor;
    } else if (token.startsWith('"')) {
      color = stringColor;
    } else if (token == 'true' || token == 'false' || token == 'null') {
      color = literalColor;
    } else {
      color = numberColor;
    }
    spans.add(TextSpan(
      text: token,
      style: base.copyWith(color: color, fontWeight: FontWeight.w500),
    ));
    start = match.end;
  }
  if (start < text.length) {
    spans.add(TextSpan(text: text.substring(start), style: base));
  }
  if (spans.isEmpty) spans.add(TextSpan(text: text, style: base));
  return spans;
}

/// Markdown 行内样式 → TextSpan。
List<InlineSpan> mdInlineSpans(
  String text,
  TextStyle base,
  ColorScheme scheme,
) {
  return <InlineSpan>[
    for (final part in MarkdownParser.parseInline(text))
      switch (part.kind) {
        MdInlineKind.text => TextSpan(text: part.text, style: base),
        MdInlineKind.bold => TextSpan(
            text: part.text,
            style: base.copyWith(fontWeight: FontWeight.w700),
          ),
        MdInlineKind.italic => TextSpan(
            text: part.text,
            style: base.copyWith(fontStyle: FontStyle.italic),
          ),
        MdInlineKind.strike => TextSpan(
            text: part.text,
            style: base.copyWith(decoration: TextDecoration.lineThrough),
          ),
        MdInlineKind.code => TextSpan(
            text: part.text,
            style: base.copyWith(
              fontFamily: 'monospace',
              color: scheme.primary,
              backgroundColor: scheme.primary.withOpacity(0.08),
            ),
          ),
        MdInlineKind.link => TextSpan(
            text: part.text,
            style: base.copyWith(
              color: scheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
      },
  ];
}

/// 把源码按行切成若干块，供 `ListView.builder` 懒加载。
///
/// 单行过长（压缩成一行的大 JSON / 无换行的日志）时按字符再切，避免
/// 一个 Text 承载几十万字符导致布局卡死。
List<String> chunkSource(
  String text, {
  int maxChars = kSourceChunkChars,
}) {
  if (text.isEmpty) return const <String>[''];
  final chunks = <String>[];
  final buffer = StringBuffer();
  var length = 0;

  void flush() {
    if (length == 0) return;
    chunks.add(buffer.toString());
    buffer.clear();
    length = 0;
  }

  for (final line in text.split('\n')) {
    if (line.length > maxChars) {
      flush();
      for (var i = 0; i < line.length; i += maxChars) {
        final end = i + maxChars > line.length ? line.length : i + maxChars;
        chunks.add(line.substring(i, end));
      }
      continue;
    }
    if (length + line.length + 1 > maxChars) flush();
    buffer.write(line);
    buffer.write('\n');
    length += line.length + 1;
  }
  flush();
  return chunks.isEmpty ? const <String>[''] : chunks;
}

/// 文档正文：按扩展名选择渲染方式，[showSource] 时统一显示原始文本。
///
/// 自身就是可滚动区域（长文档按块 / 按行懒加载），不要再套
/// `SingleChildScrollView`。
class DocumentBody extends StatelessWidget {
  const DocumentBody({
    super.key,
    required this.content,
    required this.extension,
    this.showSource = false,
  });

  final String content;
  final String extension;
  final bool showSource;

  @override
  Widget build(BuildContext context) {
    final ext = extension.toLowerCase();
    final base =
        Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.55) ??
            const TextStyle(fontSize: 14, height: 1.55);
    if (ext == 'md' || ext == 'markdown') {
      return showSource
          ? _SourceView(text: content)
          : MarkdownBody(source: content);
    }
    if (ext == 'html' || ext == 'htm') {
      // HTML 先转成 md 源文本再复用 md 渲染，源码视图仍显示原始 HTML。
      return showSource
          ? _SourceView(text: content)
          : MarkdownBody(source: HtmlParser.toMarkdown(content));
    }
    if (ext == 'json') {
      return _JsonBody(source: content, base: base, showSource: showSource);
    }
    return _SourceView(text: content);
  }
}

/// 源码 / 纯文本视图：按块懒加载，超长文件也不会一次性布局。
class _SourceView extends StatelessWidget {
  const _SourceView({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final base =
        Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45) ??
            const TextStyle(fontSize: 14, height: 1.45);
    final style = base.copyWith(fontFamily: 'monospace');
    final chunks = chunkSource(text);
    if (chunks.length == 1) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        child: SelectableText(chunks.first, style: style),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
      itemCount: chunks.length,
      itemBuilder: (context, index) => SelectableText(
        chunks[index],
        style: style,
      ),
    );
  }
}

class MarkdownBody extends StatefulWidget {
  const MarkdownBody({super.key, required this.source});

  final String source;

  @override
  State<MarkdownBody> createState() => _MarkdownBodyState();
}

class _MarkdownBodyState extends State<MarkdownBody> {
  late List<MdBlock> _blocks;

  @override
  void initState() {
    super.initState();
    _blocks = MarkdownParser.parse(widget.source);
  }

  @override
  void didUpdateWidget(MarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 解析是纯 CPU 的 O(n) 活，只在源码变化时重算，滚动/主题切换不重解析。
    if (oldWidget.source != widget.source) {
      _blocks = MarkdownParser.parse(widget.source);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium?.copyWith(height: 1.55) ??
        const TextStyle(fontSize: 14, height: 1.55);
    if (_blocks.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: <Widget>[SelectableText(tr('空文件'), style: base)],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
      itemCount: _blocks.length,
      itemBuilder: (context, index) =>
          _blockWidget(_blocks[index], theme, base),
    );
  }

  Widget _blockWidget(MdBlock block, ThemeData theme, TextStyle base) {
    final scheme = theme.colorScheme;
    switch (block.kind) {
      case MdBlockKind.heading:
        final style = switch (block.level) {
          1 => theme.textTheme.headlineSmall,
          2 => theme.textTheme.titleLarge,
          3 => theme.textTheme.titleMedium,
          _ => theme.textTheme.titleSmall,
        };
        return Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: SelectableText.rich(
            TextSpan(
              children: mdInlineSpans(
                block.text,
                (style ?? base).copyWith(fontWeight: FontWeight.w700),
                scheme,
              ),
            ),
          ),
        );
      case MdBlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SelectableText.rich(
            TextSpan(children: mdInlineSpans(block.text, base, scheme)),
          ),
        );
      case MdBlockKind.bulletList:
      case MdBlockKind.orderedList:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (var i = 0; i < block.items.length; i++)
                Padding(
                  padding: EdgeInsets.only(
                    left: 12.0 *
                        (i < block.indents.length ? block.indents[i] : 0),
                    top: 2,
                    bottom: 2,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: 24,
                        child: _listMarker(block, i, base),
                      ),
                      Expanded(
                        child: SelectableText.rich(
                          TextSpan(
                            children:
                                mdInlineSpans(block.items[i], base, scheme),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      case MdBlockKind.quote:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: scheme.primary, width: 3),
              ),
            ),
            child: SelectableText.rich(
              TextSpan(children: mdInlineSpans(block.text, base, scheme)),
            ),
          ),
        );
      case MdBlockKind.code:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withOpacity(0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              block.text,
              style: base.copyWith(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        );
      case MdBlockKind.divider:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Divider(height: 1),
        );
      case MdBlockKind.table:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12, top: 4),
          child: _tableView(block, theme, base),
        );
    }
  }

  Widget _listMarker(MdBlock block, int index, TextStyle base) {
    final checked = index < block.checked.length ? block.checked[index] : null;
    if (checked != null) {
      return Text(checked ? '☑' : '☐', style: base);
    }
    return Text(
      block.kind == MdBlockKind.bulletList ? '•' : '${index + 1}.',
      style: base,
    );
  }

  /// 表格：固定列宽 + 横向滚动，长内容自动换行，不会撑破页面。
  Widget _tableView(MdBlock block, ThemeData theme, TextStyle base) {
    final scheme = theme.colorScheme;
    final columns = block.header.length;
    if (columns == 0) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final cellWidth = columns <= 3
          ? (width / columns).clamp(72.0, 260.0)
          : (width / 3).clamp(96.0, 180.0);
      Widget cell(String text, MdAlign align, {required bool header}) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          color:
              header ? scheme.surfaceContainerHighest.withOpacity(0.7) : null,
          child: SelectableText.rich(
            TextSpan(
              children: mdInlineSpans(
                text,
                header
                    ? base.copyWith(fontWeight: FontWeight.w700, height: 1.4)
                    : base.copyWith(height: 1.4),
                scheme,
              ),
            ),
            textAlign: switch (align) {
              MdAlign.center => TextAlign.center,
              MdAlign.right => TextAlign.right,
              MdAlign.left => TextAlign.left,
            },
          ),
        );
      }

      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          columnWidths: <int, TableColumnWidth>{
            for (var i = 0; i < columns; i++) i: FixedColumnWidth(cellWidth),
          },
          border: TableBorder.all(color: scheme.outlineVariant, width: 0.7),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: <TableRow>[
            TableRow(
              children: <Widget>[
                for (var i = 0; i < columns; i++)
                  cell(block.header[i], block.aligns[i], header: true),
              ],
            ),
            for (final row in block.rows)
              TableRow(
                children: <Widget>[
                  for (var i = 0; i < columns; i++)
                    cell(row[i], block.aligns[i], header: false),
                ],
              ),
          ],
        ),
      );
    });
  }
}

class _JsonBody extends StatefulWidget {
  const _JsonBody({
    required this.source,
    required this.base,
    required this.showSource,
  });

  final String source;
  final TextStyle base;
  final bool showSource;

  @override
  State<_JsonBody> createState() => _JsonBodyState();
}

class _JsonBodyState extends State<_JsonBody> {
  /// 美化后的文本；null 表示按原文显示。
  String? _formatted;
  bool _invalid = false;
  bool _tooBig = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(_JsonBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _prepare();
  }

  /// 只在内容变化时解析一次：build 里反复 jsonDecode + encode 会卡死大文件。
  void _prepare() {
    _formatted = null;
    _invalid = false;
    _tooBig = false;
    final text = widget.source.trim();
    if (text.isEmpty) return;
    if (text.length > kJsonFormatLimit) {
      _tooBig = true;
      return;
    }
    try {
      _formatted = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } catch (_) {
      _invalid = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showSource) {
      return _SourceView(text: widget.source);
    }
    final scheme = Theme.of(context).colorScheme;
    final base = widget.base.copyWith(fontFamily: 'monospace', height: 1.45);
    final body = _formatted ?? widget.source;
    final chunks = chunkSource(body);
    final hasHint = _invalid || _tooBig;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
      itemCount: chunks.length + (hasHint ? 1 : 0),
      itemBuilder: (context, index) {
        if (hasHint && index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SmallHint(
              text: _invalid ? tr('JSON 格式有误，已按原文显示') : tr('内容较大，已按原文显示'),
            ),
          );
        }
        final chunk = chunks[hasHint ? index - 1 : index];
        return SelectableText.rich(
          TextSpan(children: jsonSpans(chunk, base, scheme)),
          style: base,
        );
      },
    );
  }
}
