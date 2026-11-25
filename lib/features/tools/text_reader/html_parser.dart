/// 轻量 HTML → Markdown 转换：把网页正文转成 [MarkdownParser] 能识别的源文本，
/// 直接复用阅读器现有的 md 渲染（标题 / 粗斜体 / 列表 / 表格 / 链接 / 代码块）。
///
/// 刻意不引入 WebView 或第三方 HTML 渲染库：阅读器只需要「读正文」，
/// 脚本、样式、媒体等一律忽略，未识别的标签当作透明容器递归处理。
/// 这样离线、无网络、无插件依赖，且长文本依旧走现有的分块懒加载。
library;

const Set<String> _kVoidTags = <String>{
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

const Set<String> _kBlockTags = <String>{
  // html / body 必须当块级容器，否则整页会被当成行内文本递归、丢失块级语义。
  'html',
  'body',
  'address',
  'article',
  'aside',
  'blockquote',
  'div',
  'dl',
  'dt',
  'dd',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hr',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'table',
  'ul',
};

/// 实体解码：常见命名实体 + 十进制 / 十六进制数字实体。
final Map<String, String> _kEntities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'ensp': ' ',
  'emsp': ' ',
  'thinsp': ' ',
  'mdash': '—',
  'ndash': '–',
  'hellip': '…',
  'middot': '·',
  'copy': '©',
  'reg': '®',
  'trade': '™',
};

final RegExp _kEntityPattern = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

String decodeHtmlEntities(String text) => text.replaceAllMapped(
      _kEntityPattern,
      (match) {
        final token = match.group(1)!;
        if (token.startsWith('#')) {
          final hex = token.startsWith('#x');
          final digits = hex ? token.substring(2) : token.substring(1);
          final code = int.tryParse(digits, radix: hex ? 16 : 10);
          if (code == null || code < 0 || code > 0x10FFFF) {
            return match.group(0)!;
          }
          // 过滤代理区，避免 String.fromCharCode 抛异常。
          if (code >= 0xD800 && code <= 0xDFFF) return '';
          return String.fromCharCode(code);
        }
        return _kEntities[token.toLowerCase()] ?? match.group(0)!;
      },
    );

/// 一个极简 HTML 节点：文本节点的 [tag] 为空串，内容在 [text]；
/// 元素节点的内容在 [children]，属性只保留 href/src/alt。
class _HtmlNode {
  _HtmlNode.text(String value)
      : tag = '',
        text = value,
        attributes = const <String, String>{};

  _HtmlNode.element(this.tag, {Map<String, String>? attributes})
      : attributes = attributes ?? const <String, String>{};

  final String tag;
  String text = '';
  final Map<String, String> attributes;
  final List<_HtmlNode> children = <_HtmlNode>[];

  bool get isText => tag.isEmpty;
  bool get isBlock => _kBlockTags.contains(tag);
}

/// HTML 正文转换器。无状态，所有方法静态，方便单测直接调用。
class HtmlParser {
  HtmlParser._();

  /// 把 html 转成 Markdown 源文本；空 / 无正文时返回空串。
  static String toMarkdown(String html) {
    final nodes = _parse(html);
    final buffer = StringBuffer();
    for (final node in nodes) {
      _renderBlock(node, buffer);
    }
    // 收敛多余空行，避免正文里出现大段空白。
    return buffer.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// 扫描成节点树：跳过注释、声明、script / style / head 整段内容。
  static List<_HtmlNode> _parse(String html) {
    final roots = <_HtmlNode>[];
    final stack = <_HtmlNode>[];

    void add(_HtmlNode node) {
      if (stack.isEmpty) {
        roots.add(node);
      } else {
        stack.last.children.add(node);
      }
    }

    var i = 0;
    while (i < html.length) {
      if (html[i] != '<') {
        final next = html.indexOf('<', i);
        final end = next < 0 ? html.length : next;
        final text = html.substring(i, end);
        if (text.isNotEmpty) add(_HtmlNode.text(text));
        i = end;
        continue;
      }
      if (html.startsWith('<!--', i)) {
        final end = html.indexOf('-->', i + 4);
        i = end < 0 ? html.length : end + 3;
        continue;
      }
      final gt = html.indexOf('>', i);
      if (gt < 0) {
        add(_HtmlNode.text(html.substring(i)));
        break;
      }
      final raw = html.substring(i + 1, gt).trim();
      i = gt + 1;
      if (raw.isEmpty || raw.startsWith('!') || raw.startsWith('?')) continue;

      if (raw.startsWith('/')) {
        final name = _tagName(raw.substring(1));
        for (var k = stack.length - 1; k >= 0; k--) {
          if (stack[k].tag == name) {
            stack.removeRange(k, stack.length);
            break;
          }
        }
        continue;
      }

      final name = _tagName(raw);
      if (name.isEmpty) continue;
      final space = raw.indexOf(RegExp(r'\s'));
      final attrText = space < 0 ? '' : raw.substring(space);
      // script / style / head 的正文不是给用户读的，连同标签整段丢弃。
      if (name == 'script' || name == 'style' || name == 'head') {
        final close = RegExp('</$name\\s*>', caseSensitive: false)
            .firstMatch(html.substring(i));
        if (close != null) i += close.end;
        continue;
      }
      final node = _HtmlNode.element(name, attributes: _parseAttrs(attrText));
      add(node);
      if (_kVoidTags.contains(name) || raw.endsWith('/')) continue;
      stack.add(node);
    }
    return roots;
  }

  static String _tagName(String raw) {
    final match = RegExp(r'^[a-zA-Z][a-zA-Z0-9]*').firstMatch(raw.trimLeft());
    return match?.group(0)?.toLowerCase() ?? '';
  }

  static Map<String, String> _parseAttrs(String raw) {
    final attrs = <String, String>{};
    for (final key in const <String>['href', 'src', 'alt', 'class']) {
      final match = RegExp(
        '$key\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
        caseSensitive: false,
      ).firstMatch(raw);
      if (match != null) {
        attrs[key] = match.group(2) ?? match.group(3) ?? match.group(4) ?? '';
      }
    }
    return attrs;
  }

  /// 块级渲染：常见标签映射成 md 块语法，未知标签按容器递归。
  static void _renderBlock(_HtmlNode node, StringBuffer out) {
    if (node.isText) {
      final text = _inlineText(node);
      if (text.trim().isNotEmpty) out.writeln(text.trim());
      return;
    }
    final tag = node.tag;
    final children = _renderChildren(node);
    switch (tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        out.writeln();
        out.writeln(
            '${'#' * int.parse(tag.substring(1))} ${_inlineChildren(node)}');
        out.writeln();
        break;
      case 'p':
        out.writeln();
        out.writeln(_inlineChildren(node));
        out.writeln();
        break;
      case 'blockquote':
        final quoted = _inlineChildren(node)
            .split('\n')
            .map((line) => '> $line')
            .join('\n');
        out.writeln();
        out.writeln(quoted);
        out.writeln();
        break;
      case 'pre':
        out.writeln();
        out.writeln('```');
        out.writeln(_rawText(node));
        out.writeln('```');
        out.writeln();
        break;
      case 'hr':
        out.writeln();
        out.writeln('---');
        out.writeln();
        break;
      case 'ul':
      case 'ol':
        out.writeln();
        _renderList(node, ordered: tag == 'ol', out: out);
        out.writeln();
        break;
      case 'table':
        out.writeln();
        out.writeln(_renderTable(node));
        out.writeln();
        break;
      case 'br':
        out.writeln();
        break;
      default:
        // div / section / 未知容器：块级孩子按块渲染，行内孩子聚成段落。
        out.write(children);
    }
  }

  static String _renderChildren(_HtmlNode node) {
    final buffer = StringBuffer();
    for (final child in node.children) {
      if (child.isBlock) {
        _renderBlock(child, buffer);
      } else {
        final text = _renderInline(child);
        if (text.trim().isNotEmpty) buffer.writeln(text.trim());
      }
    }
    return buffer.toString();
  }

  static void _renderList(
    _HtmlNode node, {
    required bool ordered,
    required StringBuffer out,
    int depth = 0,
  }) {
    var index = 0;
    for (final child in node.children) {
      if (child.tag != 'li') {
        _renderBlock(child, out);
        continue;
      }
      index++;
      final prefix = '  ' * depth + (ordered ? '$index. ' : '- ');
      final nested = StringBuffer();
      final inline = StringBuffer();
      for (final sub in child.children) {
        if (sub.tag == 'ul' || sub.tag == 'ol') {
          _renderList(sub,
              ordered: sub.tag == 'ol', out: nested, depth: depth + 1);
        } else if (sub.isBlock) {
          final block = StringBuffer();
          _renderBlock(sub, block);
          inline.write(block.toString().trim());
        } else {
          inline.write(_renderInline(sub));
        }
      }
      out.writeln('$prefix${inline.toString().trim()}');
      if (nested.isNotEmpty) out.write(nested.toString());
    }
  }

  static String _renderTable(_HtmlNode node) {
    final rows = <List<String>>[];
    for (final tr in node.children.where((n) => n.tag == 'tr')) {
      final cells = <String>[];
      for (final cell
          in tr.children.where((n) => n.tag == 'th' || n.tag == 'td')) {
        cells.add(_renderInline(cell)
            .replaceAll('\n', ' ')
            .replaceAll('|', r'\|')
            .trim());
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
    if (rows.isEmpty) return '';
    final columns = rows.first.length;
    final line = StringBuffer('|');
    for (final cell in rows.first) {
      line.write(' $cell |');
    }
    final separator = StringBuffer('|');
    for (var i = 0; i < columns; i++) {
      separator.write(' --- |');
    }
    final buffer = StringBuffer()
      ..writeln(line.toString())
      ..writeln(separator.toString());
    for (final row in rows.skip(1)) {
      final cells = StringBuffer('|');
      for (var i = 0; i < columns; i++) {
        cells.write(' ${i < row.length ? row[i] : ''} |');
      }
      buffer.writeln(cells.toString());
    }
    return buffer.toString().trimRight();
  }

  /// 行内渲染：粗 / 斜 / 删除线 / 代码 / 链接 / 图片，其余透明递归。
  static String _renderInline(_HtmlNode node) {
    if (node.isText) return _inlineText(node);
    final inner = _inlineChildren(node);
    switch (node.tag) {
      case 'b':
      case 'strong':
        return inner.trim().isEmpty ? '' : '**${inner.trim()}**';
      case 'i':
      case 'em':
      case 'cite':
        return inner.trim().isEmpty ? '' : '*${inner.trim()}*';
      case 's':
      case 'del':
      case 'strike':
        return inner.trim().isEmpty ? '' : '~~${inner.trim()}~~';
      case 'code':
      case 'kbd':
      case 'samp':
        return inner.trim().isEmpty ? '' : '`${inner.trim()}`';
      case 'u':
        return inner;
      case 'br':
        return '  \n';
      case 'img':
        final src = node.attributes['src'] ?? '';
        if (src.isEmpty) return '';
        final alt = decodeHtmlEntities(node.attributes['alt'] ?? '');
        return '![$alt]($src)';
      case 'a':
        final href = node.attributes['href'] ?? '';
        final label = inner.trim();
        if (label.isEmpty) return '';
        return href.isEmpty ? label : '[$label]($href)';
      default:
        return inner;
    }
  }

  static String _inlineChildren(_HtmlNode node) =>
      node.children.map(_renderInline).join();

  /// 文本节点：解码实体、折叠空白，并转义会干扰 md 解析的字符。
  static String _inlineText(_HtmlNode node) {
    final decoded = decodeHtmlEntities(node.text);
    final hasLead = RegExp(r'^\s').hasMatch(decoded);
    final hasTrail = RegExp(r'\s$').hasMatch(decoded);
    final core = decoded.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (core.isEmpty) return ' ';
    final escaped = core
        .replaceAll(r'\', r'\\')
        .replaceAll('`', r'\`')
        .replaceAll('*', r'\*')
        .replaceAll('_', r'\_')
        .replaceAll('[', r'\[')
        .replaceAll(']', r'\]');
    return '${hasLead ? ' ' : ''}$escaped${hasTrail ? ' ' : ''}';
  }

  /// pre / code 块内保留原始空白与符号，仅做实体解码。
  static String _rawText(_HtmlNode node) {
    if (node.isText) return decodeHtmlEntities(node.text);
    return node.children.map(_rawText).join();
  }
}
