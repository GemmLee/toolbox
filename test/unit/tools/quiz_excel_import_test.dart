import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_excel_import.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';
import '../../support/test_env.dart';

/// 在内存里构造一个最小 xlsx（只有 sheet1，单元格用 inlineStr），
/// 不依赖 dart:io，也不依赖 openpyxl 之类的外部库。
List<int> _xlsx(List<List<String>> rows) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
  final sheet = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/'
        'spreadsheetml/2006/main"><sheetData>');
  for (var r = 0; r < rows.length; r++) {
    sheet.write('<row r="${r + 1}">');
    for (var c = 0; c < rows[r].length; c++) {
      final value = rows[r][c];
      if (value.isEmpty) continue;
      final ref = '${String.fromCharCode(65 + c)}${r + 1}';
      sheet.write('<c r="$ref" t="inlineStr"><is><t xml:space="preserve">'
          '${esc(value)}</t></is></c>');
    }
    sheet.write('</row>');
  }
  sheet.write('</sheetData></worksheet>');
  final archive = Archive()
    ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', sheet.toString()));
  return ZipEncoder().encode(archive);
}

Map<String, dynamic> _parse(List<int> bytes, {String name = '测试题库.xlsx'}) {
  final result = QuizExcelImporter.parse(bytes, fileName: name);
  return jsonDecode(result.json) as Map<String, dynamic>;
}

List<dynamic> _questions(List<int> bytes) =>
    _parse(bytes)['questions'] as List<dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  group('Excel 题库导入解析', () {
    test('有表头 + 有题型列：按位置取题干/选项/答案/解析，空列分隔', () {
      final bank = _parse(_xlsx(<List<String>>[
        <String>['题型', '题干', '选项A', '选项B', '选项C', '', '答案', '解析'],
        <String>['单选题', '1 + 1 = ?', 'A. 1', 'B. 2', 'C. 3', '', 'B', '基础加法'],
        <String>[
          '多选题',
          '哪些是偶数？',
          'A. 1',
          'B. 2',
          'C. 4',
          '',
          'B,C',
          '偶数是 2 和 4'
        ],
        <String>['判断题', '地球是圆的。', '', '', '', '', '正确', '常识'],
        <String>['填空题', '中国的首都是____。', '', '', '', '', '北京', ''],
      ]));

      expect(bank['version'], 1);
      expect(bank['bankName'], '测试题库');
      final questions = bank['questions'] as List<dynamic>;
      expect(questions, hasLength(4));

      final single = questions[0] as Map<String, dynamic>;
      expect(single['type'], 'single');
      expect(single['stem'], '1 + 1 = ?');
      expect(single['answer'], <String>['B']);
      expect(single['analysis'], '基础加法');
      final singleOpts = single['options'] as List<dynamic>;
      expect(singleOpts.first['key'], 'A');
      expect(singleOpts.first['text'], '1', reason: '选项前缀 A. 被清洗');

      final multiple = questions[1] as Map<String, dynamic>;
      expect(multiple['type'], 'multiple');
      expect(multiple['answer'], <String>['B', 'C']);

      final judge = questions[2] as Map<String, dynamic>;
      expect(judge['type'], 'true_false');
      expect(judge['answer'], <String>['true']);
      expect(judge.containsKey('options'), isFalse, reason: '判断题不输出选项');

      final fill = questions[3] as Map<String, dynamic>;
      expect(fill['type'], 'fill');
      expect(fill['answer'], <String>['北京']);
    });

    test('无表头 + 无题型列：自动推断五种题型', () {
      final questions = _parse(_xlsx(<List<String>>[
        <String>['1 + 1 = ?', 'A. 1', 'B. 2', '', 'A'],
        <String>['哪些是偶数？', '2', '3', '4', '', 'A,C'],
        <String>['地球是圆的。', '正确', '错误', '', '正确'],
        <String>['月球是方的。', '', '', '', '×'],
        <String>['中国的首都是____。', '', '', '', '北京'],
        <String>['详细说明牛顿第三定律的内容与适用场景。', '', '', '', '作用力与反作用力大小相等方向相反'],
      ]))['questions'] as List<dynamic>;

      expect(questions, hasLength(6));
      expect((questions[0] as Map)['type'], 'single');
      expect((questions[1] as Map)['type'], 'multiple');
      expect((questions[2] as Map)['type'], 'true_false');
      expect((questions[3] as Map)['type'], 'true_false');
      expect((questions[3] as Map)['answer'], <String>['false']);
      expect((questions[4] as Map)['type'], 'fill');
      expect((questions[5] as Map)['type'], 'short');
    });

    test('答案写成选项文本时按文本反查 key', () {
      final questions = _questions(_xlsx(<List<String>>[
        <String>['中国的首都是哪座城市？', 'A. 上海', 'B. 北京', '', '北京'],
      ]));
      expect((questions.first as Map)['answer'], <String>['B']);
    });

    test('重复题去重，保留第一道并统计数量', () {
      final result = QuizExcelImporter.parse(
          _xlsx(<List<String>>[
            <String>['1 + 1 = ?', 'A. 1', 'B. 2', '', 'B'],
            <String>['1 + 1 = ?', 'A. 1', 'B. 2', '', 'B'],
            <String>['2 + 2 = ?', 'A. 3', 'B. 4', '', 'B'],
          ]),
          fileName: '去重题库.xlsx');
      expect(result.imported, 2);
      expect(result.duplicates, 1);
      expect(result.skipped, 0);
    });

    test('题干为空、缺少答案（没留空列）的行被跳过并记录原因', () {
      final result = QuizExcelImporter.parse(
          _xlsx(<List<String>>[
            <String>['', 'A. 1', 'B. 2', '', 'A'],
            <String>['缺少答案的题', 'A. 1', 'B. 2', 'A'],
            <String>['正常题目', 'A. 1', 'B. 2', '', 'A'],
          ]),
          fileName: '跳过题库.xlsx');
      expect(result.imported, 1);
      expect(result.skipped, 2);
      expect(result.issues, isNotEmpty);
      expect(result.issues.first, contains('第 1 行'));
    });

    test('有表头时表头行不计入总行数', () {
      final result = QuizExcelImporter.parse(
          _xlsx(<List<String>>[
            <String>['题型', '题干', '选项', '答案'],
            <String>['单选题', '1 + 1 = ?', 'A. 1|B. 2', 'A'],
          ]),
          fileName: '带表头.xlsx');
      expect(result.headerDetected, isTrue);
      expect(result.totalRows, 1);
    });

    test('输出结果可直接交给 QuizImporter.parse 预览', () {
      final result = QuizExcelImporter.parse(
          _xlsx(<List<String>>[
            <String>['单选题', '1 + 1 = ?', 'A. 1', 'B. 2', '', 'B', '解析'],
          ]),
          fileName: '端到端.xlsx');
      final preview = QuizImporter.parse(result.json);
      expect(preview.hasErrors, isFalse);
      expect(preview.questions, hasLength(1));
      expect(preview.questions.first.stem, '1 + 1 = ?');
      expect(preview.questions.first.type, QuestionType.single);
    });

    test('非法字节与空表抛出明确异常', () {
      expect(
          () => QuizExcelImporter.parse(<int>[1, 2, 3], fileName: 'bad.xlsx'),
          throwsA(isA<ExcelImportException>()));
      final empty = ZipEncoder().encode(Archive()
        ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml',
            '<worksheet><sheetData></sheetData></worksheet>')));
      expect(() => QuizExcelImporter.parse(empty, fileName: 'empty.xlsx'),
          throwsA(isA<ExcelImportException>()));
    });
  });
}
