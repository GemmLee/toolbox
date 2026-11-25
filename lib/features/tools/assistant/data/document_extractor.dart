import 'dart:convert';

import 'package:archive/archive.dart';

/// 解析出的文档内容。
class ExtractedDocument {
  const ExtractedDocument({required this.name, required this.text});

  final String name;
  final String text;
}

/// 把文件内容提取成纯文本，供技能 / 对话使用。
///
/// 支持：txt / md / csv / json 等文本文件，docx（Word），xlsx（Excel）。
class DocumentExtractor {
  DocumentExtractor._();

  /// 提取文本的最大长度（超出截断，避免撑爆上下文）。
  static const int maxChars = 120000;

  static const Set<String> textExts = <String>{
    'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'log', 'xml', 'yaml', 'yml',
  };

  /// 智能助手附件允许的扩展名。
  static const List<String> supportedExtensions = <String>[
    'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'log', 'docx', 'xlsx',
  ];

  static ExtractedDocument extract({
    required String fileName,
    required List<int> bytes,
  }) {
    final ext = _extOf(fileName);
    final String text;
    switch (ext) {
      case 'docx':
        text = _extractDocx(bytes);
      case 'xlsx':
        text = _extractXlsx(bytes);
      case '':
        text = utf8.decode(bytes, allowMalformed: true);
      case _ when textExts.contains(ext):
        text = _decodeText(bytes);
      default:
        throw FormatException(
            '暂不支持 .$ext 文件；请改用 docx / xlsx / txt / md / csv / json');
    }
    final truncated = text.length > maxChars
        ? '${text.substring(0, maxChars)}\n\n…（内容过长，已截断到 $maxChars 字符）'
        : text;
    return ExtractedDocument(name: fileName, text: truncated);
  }

  static String _extOf(String fileName) {
    final idx = fileName.lastIndexOf('.');
    if (idx < 0) return '';
    return fileName.substring(idx + 1).toLowerCase();
  }

  static String _decodeText(List<int> bytes) {
    var data = bytes;
    if (data.length >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF) {
      data = data.sublist(3);
    }
    return utf8.decode(data, allowMalformed: true);
  }

  // —— docx ——

  static String _extractDocx(List<int> bytes) {
    final Archive? archive = _safeDecode(bytes);
    if (archive == null) {
      throw const FormatException('不是有效的 docx 文件（应为 Office OpenXML 压缩包）');
    }
    final entry = _findEntry(archive, 'word/document.xml');
    if (entry == null) {
      throw const FormatException('docx 中缺少 word/document.xml');
    }
    final xml = utf8.decode(entry.content as List<int>, allowMalformed: true);

    final bodyStart = xml.indexOf('<w:body');
    final bodyEnd = xml.lastIndexOf('</w:body>');
    final body = (bodyStart >= 0 && bodyEnd > bodyStart)
        ? xml.substring(bodyStart, bodyEnd)
        : xml;

    final out = StringBuffer();
    var cursor = 0;
    for (final match
        in RegExp(r'<w:tbl>.*?</w:tbl>', dotAll: true).allMatches(body)) {
      out.write(_paragraphsText(body.substring(cursor, match.start)));
      out.write(_tableText(match.group(0)!));
      cursor = match.end;
    }
    out.write(_paragraphsText(body.substring(cursor)));
    final result = out.toString().trim();
    if (result.isEmpty) throw const FormatException('docx 中没有提取到文本');
    return result;
  }

  /// 表格：每行一行文本，单元格以 Tab 分隔。
  static String _tableText(String tableXml) {
    final rows = StringBuffer();
    for (final row
        in RegExp(r'<w:tr[ >].*?</w:tr>', dotAll: true).allMatches(tableXml)) {
      final cells = <String>[];
      for (final cell
          in RegExp(r'<w:tc[ >].*?</w:tc>', dotAll: true).allMatches(row.group(0)!)) {
        cells.add(_paragraphsText(cell.group(0)!).replaceAll('\n', ' ').trim());
      }
      if (cells.any((c) => c.isNotEmpty)) {
        rows.writeln(cells.join('\t'));
      }
    }
    return rows.toString();
  }

  /// 非表格区域的段落文本。
  static String _paragraphsText(String xml) {
    final out = StringBuffer();
    for (final p in RegExp(r'<w:p[ >/].*?</w:p>', dotAll: true).allMatches(xml)) {
      var text = _runsText(p.group(0)!);
      text = text.trim();
      if (text.isNotEmpty) out.writeln(text);
    }
    return out.toString();
  }

  static String _runsText(String xml) {
    var text = xml
        .replaceAll('<w:tab/>', '\t')
        .replaceAll('<w:br/>', '\n')
        .replaceAll('<w:cr/>', '\n');
    final buffer = StringBuffer();
    for (final run
        in RegExp(r'<w:t(?:\s[^>]*)?>(.*?)</w:t>', dotAll: true).allMatches(text)) {
      buffer.write(run.group(1) ?? '');
    }
    return _xmlUnescape(buffer.toString());
  }

  // —— xlsx ——

  static String _extractXlsx(List<int> bytes) {
    final Archive? archive = _safeDecode(bytes);
    if (archive == null) {
      throw const FormatException('不是有效的 xlsx 文件（应为 Office OpenXML 压缩包）');
    }

    // 共享字符串表：<si> 可含多个 <r><t> 文本片段。
    final shared = <String>[];
    final sharedEntry = _findEntry(archive, 'xl/sharedStrings.xml');
    if (sharedEntry != null) {
      final xml = utf8.decode(sharedEntry.content as List<int>, allowMalformed: true);
      for (final si
          in RegExp(r'<si(?:\s[^>]*)?>(.*?)</si>', dotAll: true).allMatches(xml)) {
        final buffer = StringBuffer();
        for (final t in RegExp(r'<t(?:\s[^>]*)?>(.*?)</t>', dotAll: true)
            .allMatches(si.group(1)!)) {
          buffer.write(t.group(1) ?? '');
        }
        shared.add(_xmlUnescape(buffer.toString()));
      }
    }

    final sheets = archive.files
        .where((f) =>
            f.isFile &&
            RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name))
        .toList()
      ..sort(_sheetOrder);

    if (sheets.isEmpty) throw const FormatException('xlsx 中没有工作表');

    final out = StringBuffer();
    for (final sheet in sheets) {
      final xml = utf8.decode(sheet.content as List<int>, allowMalformed: true);
      out.writeln('【${_sheetLabel(sheet.name)}】');
      for (final row in RegExp(r'<row[ >].*?</row>|<row/>', dotAll: true)
          .allMatches(xml)) {
        final cells = <String>[];
        for (final cell in RegExp(r'<c(?:\s[^>]*)?>.*?</c>|<c(?:\s[^>]*)?/>',
                dotAll: true)
            .allMatches(row.group(0)!)) {
          cells.add(_cellValue(cell.group(0)!, shared));
        }
        if (cells.any((c) => c.trim().isNotEmpty)) {
          out.writeln(cells.join('\t'));
        }
      }
      out.writeln();
    }
    final result = out.toString().trim();
    if (result.isEmpty) throw const FormatException('xlsx 中没有提取到数据');
    return result;
  }

  static int _sheetOrder(ArchiveFile a, ArchiveFile b) {
    final na = int.tryParse(
            RegExp(r'sheet(\d+)\.xml').firstMatch(a.name)?.group(1) ?? '') ??
        0;
    final nb = int.tryParse(
            RegExp(r'sheet(\d+)\.xml').firstMatch(b.name)?.group(1) ?? '') ??
        0;
    return na.compareTo(nb);
  }

  static String _sheetLabel(String entryName) {
    final n = int.tryParse(
            RegExp(r'sheet(\d+)\.xml').firstMatch(entryName)?.group(1) ?? '') ??
        0;
    return 'Sheet$n';
  }

  /// 单元格取值：t="s" 共享字符串 / t="inlineStr" 内联 / 其他为数值或公式结果。
  static String _cellValue(String cellXml, List<String> shared) {
    final type = RegExp(r't="([A-Za-z]+)"').firstMatch(cellXml)?.group(1);
    if (type == 'inlineStr') {
      final buffer = StringBuffer();
      for (final t in RegExp(r'<t(?:\s[^>]*)?>(.*?)</t>', dotAll: true)
          .allMatches(cellXml)) {
        buffer.write(t.group(1) ?? '');
      }
      return _xmlUnescape(buffer.toString()).trim();
    }
    final v = RegExp(r'<v(?:\s[^>]*)?>(.*?)</v>', dotAll: true)
        .firstMatch(cellXml)
        ?.group(1);
    if (v == null) return '';
    final text = _xmlUnescape(v).trim();
    if (type == 's') {
      final idx = int.tryParse(text);
      if (idx != null && idx >= 0 && idx < shared.length) return shared[idx];
      return '';
    }
    return text;
  }

  // —— 公共 ——

  static Archive? _safeDecode(List<int> bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  static ArchiveFile? _findEntry(Archive archive, String name) {
    for (final file in archive.files) {
      if (file.isFile && file.name == name) return file;
    }
    return null;
  }

  static String _xmlUnescape(String text) => text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
}
