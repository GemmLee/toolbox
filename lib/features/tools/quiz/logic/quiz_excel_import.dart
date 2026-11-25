import 'dart:convert';

import 'package:archive/archive.dart';

import '../../../../core/settings/tool_texts.dart';
import '../data/quiz_models.dart';

/// Excel 导入结果：一段可直接交给 [QuizImporter.parse] 的题库 JSON，
/// 加上展示给用户的结果摘要。
class ExcelImportResult {
  const ExcelImportResult({
    required this.bankName,
    required this.json,
    required this.totalRows,
    required this.imported,
    required this.duplicates,
    required this.skipped,
    required this.typeCounts,
    required this.headerDetected,
    required this.typeColumnDetected,
    required this.issues,
  });

  final String bankName;
  final String json;
  final int totalRows;
  final int imported;
  final int duplicates;
  final int skipped;
  final Map<QuestionType, int> typeCounts;
  final bool headerDetected;
  final bool typeColumnDetected;

  /// 前若干条跳过原因（带行号），供结果卡展示。
  final List<String> issues;
}

class ExcelImportException implements Exception {
  const ExcelImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 把按「每行一题」排布的 xlsx 转成题库 JSON。
///
/// 列布局（表头可选）：
/// `题型(可选) | 题干 | 选项A | 选项B | … | 空列 | 答案 | 解析…`
///
/// - 第一列若不是可识别的题型，则视为无题型列，第一列即题干；此时按选项与
///   答案自动推断题型。
/// - 有表头时自动跳过首行；只识别「题干 / 答案」等关键词。
/// - 重复题（题干 + 答案相同）只保留第一道。
/// - 零新增依赖：xlsx 由 [archive] 解 zip + 读 OpenXML，写出标准 JSON 文本。
class QuizExcelImporter {
  QuizExcelImporter._();

  static const int _maxIssues = 5;
  static const int _shortAnswerLimit = 15;

  static ExcelImportResult parse(List<int> bytes, {required String fileName}) {
    final rows = _readRows(bytes);
    final headerDetected = _isHeader(rows.first);
    final data = headerDetected ? rows.skip(1).toList() : rows;

    final typeColumnDetected =
        data.isNotEmpty && _typeOf(_at(data.first, 0)) != null;
    final stemIndex = typeColumnDetected ? 1 : 0;
    final optionStart = stemIndex + 1;

    final questions = <Map<String, dynamic>>[];
    final seen = <String>{};
    final issues = <String>[];
    final typeCounts = <QuestionType, int>{};
    var skipped = 0;
    var duplicates = 0;

    for (var r = 0; r < data.length; r++) {
      final row = data[r];
      final lineNo = r + 1 + (headerDetected ? 1 : 0);
      final stem = _at(row, stemIndex).trim();
      if (stem.isEmpty) {
        skipped++;
        _addIssue(issues, '${trf('第 {n} 行', {'n': lineNo})}${tr('题干为空，已跳过')}');
        continue;
      }

      // 选项：从题干后一列开始连续取非空单元格，遇到空列即认为选项区结束。
      final rawOptions = <String>[];
      var cursor = optionStart;
      while (cursor < row.length && _at(row, cursor).trim().isNotEmpty) {
        rawOptions.add(_at(row, cursor).trim());
        cursor++;
      }
      // 跳过空列（可空一列或更多），其后第一格为答案。
      while (cursor < row.length && _at(row, cursor).trim().isEmpty) {
        cursor++;
      }
      final answerRaw = _at(row, cursor).trim();
      if (answerRaw.isEmpty) {
        skipped++;
        _addIssue(issues,
            '${trf('第 {n} 行', {'n': lineNo})}${tr('缺少答案，选项与答案之间需留一个空列')}');
        continue;
      }
      final analysis = row
          .skip(cursor + 1)
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .join('\n');

      final explicit = typeColumnDetected ? _typeOf(_at(row, 0)) : null;
      final options = _parseOptions(rawOptions);
      final type = explicit ?? _inferType(options, answerRaw);

      final answer = switch (type) {
        QuestionType.trueFalse => _judgeAnswer(answerRaw),
        QuestionType.single ||
        QuestionType.multiple =>
          _choiceAnswer(answerRaw, options),
        _ => <String>[answerRaw],
      };
      if (answer == null || answer.isEmpty) {
        skipped++;
        _addIssue(
            issues, '${trf('第 {n} 行', {'n': lineNo})}${tr('答案无法识别，已跳过')}');
        continue;
      }
      if (type == QuestionType.single && answer.length > 1) {
        skipped++;
        _addIssue(
            issues, '${trf('第 {n} 行', {'n': lineNo})}${tr('单选题有多个答案，已跳过')}');
        continue;
      }
      if (type.hasOptions &&
          type != QuestionType.trueFalse &&
          options.isEmpty) {
        skipped++;
        _addIssue(issues, '${trf('第 {n} 行', {'n': lineNo})}${tr('缺少选项，已跳过')}');
        continue;
      }

      final hash = contentHashOf('$stem|${answer.join(',')}');
      if (!seen.add(hash)) {
        duplicates++;
        continue;
      }

      final q = <String, dynamic>{
        'id': 'q-${(questions.length + 1).toString().padLeft(3, '0')}',
        'type': type.key,
        'stem': stem,
        'answer': answer,
      };
      // 判断题不输出 options，导入器会补「正确 / 错误」两个固定选项。
      if (type != QuestionType.trueFalse && options.isNotEmpty) {
        q['options'] = options
            .map((o) => <String, String>{'key': o.key, 'text': o.text})
            .toList();
      }
      if (analysis.isNotEmpty) q['analysis'] = analysis;
      questions.add(q);
      typeCounts[type] = (typeCounts[type] ?? 0) + 1;
    }

    final bankName = _bankNameOf(fileName);
    final bank = <String, dynamic>{
      'version': 1,
      'bankName': bankName,
      'questions': questions,
    };
    final jsonText = const JsonEncoder.withIndent('  ').convert(bank);
    return ExcelImportResult(
      bankName: bankName,
      json: jsonText,
      totalRows: data.length,
      imported: questions.length,
      duplicates: duplicates,
      skipped: skipped,
      typeCounts: typeCounts,
      headerDetected: headerDetected,
      typeColumnDetected: typeColumnDetected,
      issues: List<String>.unmodifiable(issues),
    );
  }

  static void _addIssue(List<String> issues, String text) {
    if (issues.length < _maxIssues) issues.add(text);
  }

  static String _at(List<String> row, int index) =>
      index >= 0 && index < row.length ? row[index] : '';

  // ---------- 类型推断 ----------

  static QuestionType? _typeOf(String raw) {
    final v = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return switch (v) {
      '单选题' || '单项选择' || '单项选择题' || '单选' || 'single' => QuestionType.single,
      '多选题' || '多项选择' || '多项选择题' || '多选' || 'multiple' => QuestionType.multiple,
      '判断题' ||
      '是非题' ||
      '判断' ||
      'true_false' ||
      'truefalse' ||
      'boolean' =>
        QuestionType.trueFalse,
      '填空题' || '填空' || 'fill' || 'fill_blank' || 'blank' => QuestionType.fill,
      '简答题' ||
      '简答' ||
      '问答' ||
      'short' ||
      'short_answer' ||
      'essay' =>
        QuestionType.short,
      _ => null,
    };
  }

  static final RegExp _optionPrefix = RegExp(r'^\s*([A-Za-z])\s*[、．.，,：:]\s*');

  static List<_Option> _parseOptions(List<String> raws) {
    final out = <_Option>[];
    for (var i = 0; i < raws.length; i++) {
      final raw = raws[i];
      final match = _optionPrefix.firstMatch(raw);
      final key = match != null
          ? match.group(1)!.toUpperCase()
          : String.fromCharCode(65 + i);
      final text = (match != null ? raw.substring(match.end) : raw).trim();
      if (text.isNotEmpty) out.add(_Option(key, text));
    }
    return out;
  }

  static bool _isJudge(List<_Option> options, String answerRaw) {
    if (options.length == 2) {
      final texts = options
          .map((o) => o.text.replaceAll(RegExp(r'\s+'), '').toLowerCase())
          .toSet();
      if (texts.contains('正确') && texts.contains('错误')) return true;
      if (texts.contains('对') && texts.contains('错')) return true;
      if (texts.contains('是') && texts.contains('否')) return true;
      if (texts.contains('true') && texts.contains('false')) return true;
    }
    const judgeTokens = <String>{
      '√',
      '✓',
      '×',
      '✗',
      '对',
      '错',
      '正确',
      '错误',
      'true',
      'false',
      't',
      'f',
      '是',
      '否',
    };
    return judgeTokens.contains(answerRaw.trim().toLowerCase());
  }

  static QuestionType _inferType(List<_Option> options, String answerRaw) {
    if (_isJudge(options, answerRaw)) return QuestionType.trueFalse;
    if (options.isEmpty) {
      return answerRaw.trim().length > _shortAnswerLimit
          ? QuestionType.short
          : QuestionType.fill;
    }
    final keys = _choiceAnswer(answerRaw, options) ?? const <String>[];
    return keys.length > 1 ? QuestionType.multiple : QuestionType.single;
  }

  static List<String>? _judgeAnswer(String raw) {
    final judged = normalizeJudgeAnswer(raw);
    if (judged == null) return null;
    return <String>[judged];
  }

  static final RegExp _answerPrefix = RegExp(r'^(答案|正确答案|答案选项)\s*[:：是为]?\s*');
  static final RegExp _answerLetters =
      RegExp(r'^[A-Fa-f]([\s,，、/;；]*[A-Fa-f])*$');

  static List<String>? _choiceAnswer(String raw, List<_Option> options) {
    var value = raw.trim().replaceFirst(_answerPrefix, '').trim();
    if (_answerLetters.hasMatch(value)) {
      final keys = <String>[];
      for (final match in RegExp(r'[A-Fa-f]').allMatches(value)) {
        final key = match.group(0)!.toUpperCase();
        if (options.any((o) => o.key == key) && !keys.contains(key)) {
          keys.add(key);
        }
      }
      if (keys.isNotEmpty) return keys;
    }
    // 答案写成选项文本（如「北京」）时按文本反查 key。
    final keys = <String>[];
    for (final option in options) {
      if (option.text.isNotEmpty && value.contains(option.text)) {
        keys.add(option.key);
      }
    }
    return keys.isEmpty ? null : keys;
  }

  // ---------- 表头 / 文件名 ----------

  static const List<String> _headerWords = <String>[
    '题型',
    '题干',
    '选项',
    '答案',
    '解析',
    '序号',
    '备注',
    'type',
    'stem',
    'option',
    'answer',
    'analysis',
    'no',
  ];

  static bool _isHeader(List<String> row) {
    var hits = 0;
    for (final cell in row) {
      final value = cell.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
      if (value.isEmpty) continue;
      if (_headerWords.any((word) => value == word || value.startsWith(word))) {
        hits++;
      }
    }
    return hits >= 2;
  }

  static String _bankNameOf(String fileName) {
    final name = fileName
        .replaceFirst(RegExp(r'\.[^.]+$'), '')
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return name.isEmpty ? tr('导入题库') : name;
  }

  // ---------- xlsx 读取 ----------

  static List<List<String>> _readRows(List<int> bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw ExcelImportException(tr('不是有效的 xlsx 文件（应为 Office OpenXML 压缩包）'));
    }

    final shared = <String>[];
    final sharedEntry = _entry(archive, 'xl/sharedStrings.xml');
    if (sharedEntry != null) {
      final xml =
          utf8.decode(sharedEntry.content as List<int>, allowMalformed: true);
      for (final si in RegExp(r'<si(?:\s[^>]*)?>(.*?)</si>', dotAll: true)
          .allMatches(xml)) {
        final buffer = StringBuffer();
        for (final t in RegExp(r'<t(?:\s[^>]*)?>(.*?)</t>', dotAll: true)
            .allMatches(si.group(1)!)) {
          buffer.write(t.group(1) ?? '');
        }
        shared.add(_unescape(buffer.toString()));
      }
    }

    final sheets = archive.files
        .where((file) =>
            file.isFile &&
            RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(file.name))
        .toList()
      ..sort((a, b) => _sheetNumber(a.name).compareTo(_sheetNumber(b.name)));
    if (sheets.isEmpty) {
      throw ExcelImportException(tr('Excel 中没有工作表'));
    }
    final xml =
        utf8.decode(sheets.first.content as List<int>, allowMalformed: true);

    final rows = <List<String>>[];
    for (final rowMatch in RegExp(
            r'<row(?:\s[^>]*)?/>|<row(?:\s[^>]*)?>.*?</row>',
            dotAll: true)
        .allMatches(xml)) {
      final cells = <String>[];
      for (final cellMatch
          in RegExp(r'<c(?:\s[^>]*)?/>|<c(?:\s[^>]*)?>.*?</c>', dotAll: true)
              .allMatches(rowMatch.group(0)!)) {
        final cellXml = cellMatch.group(0)!;
        final ref = RegExp(r'\br="([A-Z]+)\d+"').firstMatch(cellXml)?.group(1);
        final index = ref == null ? cells.length : _columnIndexOf(ref);
        while (cells.length <= index) {
          cells.add('');
        }
        cells[index] = _cellValue(cellXml, shared);
      }
      while (cells.isNotEmpty && cells.last.isEmpty) {
        cells.removeLast();
      }
      if (cells.any((value) => value.trim().isNotEmpty)) rows.add(cells);
    }
    if (rows.isEmpty) throw ExcelImportException(tr('Excel 中没有数据'));
    return rows;
  }

  static ArchiveFile? _entry(Archive archive, String name) {
    for (final file in archive.files) {
      if (file.isFile && file.name == name) return file;
    }
    return null;
  }

  static int _sheetNumber(String name) =>
      int.tryParse(
          RegExp(r'sheet(\d+)\.xml').firstMatch(name)?.group(1) ?? '') ??
      0;

  static int _columnIndexOf(String letters) {
    var index = 0;
    for (final code in letters.toUpperCase().codeUnits) {
      index = index * 26 + (code - 64);
    }
    return index - 1;
  }

  static String _cellValue(String cellXml, List<String> shared) {
    final type = RegExp(r'\bt="([A-Za-z]+)"').firstMatch(cellXml)?.group(1);
    if (type == 'inlineStr' || cellXml.contains('<is>')) {
      final buffer = StringBuffer();
      for (final t in RegExp(r'<t(?:\s[^>]*)?>(.*?)</t>', dotAll: true)
          .allMatches(cellXml)) {
        buffer.write(t.group(1) ?? '');
      }
      return _unescape(buffer.toString()).trim();
    }
    final v = RegExp(r'<v(?:\s[^>]*)?>(.*?)</v>', dotAll: true)
        .firstMatch(cellXml)
        ?.group(1);
    if (v == null) return '';
    final text = _unescape(v).trim();
    if (type == 's') {
      final index = int.tryParse(text);
      return index != null && index >= 0 && index < shared.length
          ? shared[index]
          : '';
    }
    if (type == 'b') return text == '1' ? 'true' : 'false';
    return text;
  }

  static String _unescape(String text) => text
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
      .replaceAllMapped(RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)))
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
}

class _Option {
  const _Option(this.key, this.text);

  final String key;
  final String text;
}
