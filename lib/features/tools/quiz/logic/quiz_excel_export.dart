import 'package:archive/archive.dart';

import '../../../../core/settings/tool_texts.dart';
import '../data/quiz_models.dart';

/// 把单个题库导出成 Excel（xlsx）工作簿。
///
/// 列：序号、题型、题干、选项、答案、解析。
/// 选项列在同一单元格内列出全部选项，每个选项用英文双引号包住、
/// 逗号分隔（如 `"A. 北京","B. 上海"`）；判断题按 App 约定没有选项列内容。
/// xlsx 由 [archive] 手工组装（zip + 内联字符串），零新增依赖。
class QuizExcelExporter {
  QuizExcelExporter._();

  /// 生成 xlsx 字节流。
  static List<int> build(Bank bank, List<Question> questions) {
    final archive = Archive();
    for (final entry in <String, String>{
      '[Content_Types].xml': _contentTypes,
      '_rels/.rels': _rootRels,
      'xl/workbook.xml': _workbook(sheetNameOf(bank)),
      'xl/_rels/workbook.xml.rels': _workbookRels,
      'xl/styles.xml': _styles,
      'xl/worksheets/sheet1.xml': _sheet(questions),
    }.entries) {
      archive.addFile(ArchiveFile.string(entry.key, entry.value));
    }
    return ZipEncoder().encode(archive);
  }

  /// 导出文件名：与 JSON 导出同规则，扩展名 xlsx。
  static String fileNameOf(Bank bank, DateTime now) {
    final safe = bank.name
        .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')
        .trim()
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    return '题库-${safe.isEmpty ? '未命名' : safe}-$stamp.xlsx';
  }

  /// Excel 工作表名：≤31 字符，不含 ： \ / ? * [ ]。
  static String sheetNameOf(Bank bank) {
    final safe = bank.name.replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ').trim();
    if (safe.isEmpty) return tr('题库');
    return safe.length > 31 ? safe.substring(0, 31) : safe;
  }

  /// 题型列文本（与刷题界面筛选一致）。
  static String typeLabelOf(QuestionType type) => switch (type) {
        QuestionType.single => tr('单选'),
        QuestionType.multiple => tr('多选'),
        QuestionType.trueFalse => tr('判断'),
        QuestionType.fill => tr('填空'),
        QuestionType.short => tr('简答'),
      };

  /// 选项列文本：每个选项带标号并用双引号包住，逗号分隔；判断题为空。
  static String optionsCell(Question q) {
    if (q.type == QuestionType.trueFalse || q.options.isEmpty) return '';
    return q.options
        .map((o) => optionLabelOf(q, o))
        .map((s) => '"$s"')
        .join(',');
  }

  // ---------- 工作簿骨架 ----------

  static String _esc(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _numCell(String col, int row, int value) =>
      '<c r="$col$row"><v>$value</v></c>';

  static String _strCell(String col, int row, String text) =>
      '<c r="$col$row" t="inlineStr"><is><t xml:space="preserve">'
      '${_esc(text)}</t></is></c>';

  static String _sheet(List<Question> questions) {
    final headers = <String>[
      tr('序号'),
      tr('题型'),
      tr('题干'),
      tr('选项'),
      tr('答案'),
      tr('解析'),
    ];
    final cols = <String>['A', 'B', 'C', 'D', 'E', 'F'];
    final buf = StringBuffer();
    buf.write('<row r="1">');
    for (var i = 0; i < headers.length; i++) {
      buf.write(_strCell(cols[i], 1, headers[i]));
    }
    buf.write('</row>');
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      final row = i + 2;
      final cells = <String>[
        _numCell(cols[0], row, i + 1),
        _strCell(cols[1], row, typeLabelOf(q.type)),
        _strCell(cols[2], row, q.stem),
        _strCell(cols[3], row, optionsCell(q)),
        _strCell(cols[4], row, answerLabelOf(q)),
        _strCell(cols[5], row, q.analysis ?? ''),
      ];
      buf
        ..write('<row r="$row">')
        ..writeAll(cells)
        ..write('</row>');
    }
    return '<worksheet xmlns="http://schemas.openxmlformats.org/'
        'spreadsheetml/2006/main"><sheetData>$buf</sheetData></worksheet>';
  }

  static const String _contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-'
      'package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.'
      'openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/'
      'vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.'
      'openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '</Types>';

  static const String _rootRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/'
      'relationships"><Relationship Id="rId1" Type="http://schemas.'
      'openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
      'Target="xl/workbook.xml"/></Relationships>';

  static String _workbook(String sheetName) =>
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/'
      'main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/'
      'relationships"><sheets><sheet name="${_esc(sheetName)}" sheetId="1" '
      'r:id="rId1"/></sheets></workbook>';

  static const String _workbookRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/'
      'relationships"><Relationship Id="rId1" Type="http://schemas.'
      'openxmlformats.org/officeDocument/2006/relationships/worksheet" '
      'Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://'
      'schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
      'Target="styles.xml"/></Relationships>';

  static const String _styles =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/'
      'main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font>'
      '</fonts><fills count="2"><fill><patternFill patternType="none"/></fill>'
      '<fill><patternFill patternType="gray125"/></fill></fills>'
      '<borders count="1"><border/></borders><cellStyleXfs count="1">'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" '
      'xfId="0"/></cellXfs></styleSheet>';
}
