import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_excel_export.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_export.dart';

Future<QuizRepository> openRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

/// 生成 60 道单选题的题库 JSON，用于验证导出不被 limit=50 截断。
String bankJsonOf(int count) {
  final questions = <Map<String, Object?>>[
    for (var i = 1; i <= count; i++)
      <String, Object?>{
        'id': 'q$i',
        'type': 'single',
        'stem': '第 $i 题题干',
        'options': <Map<String, Object?>>[
          {'key': 'A', 'text': '选项 A'},
          {'key': 'B', 'text': '选项 B'},
        ],
        'answer': <String>['A'],
      },
  ];
  return jsonEncode(<String, Object?>{
    'version': 1,
    'bankName': '大量题库',
    'questions': questions,
  });
}

const String kMixed = '''
{
  "version": 1,
  "bankName": "混合题型",
  "questions": [
    {"id": "q1", "type": "single", "stem": "1 + 1 < 3 且 1 & 1 = 1？",
     "options": [{"key": "A", "text": "对"}, {"key": "B", "text": "错"}],
     "answer": ["A"], "analysis": "解析 < 文本"},
    {"id": "q2", "type": "trueFalse", "stem": "地球是圆的。",
     "answer": ["true"]},
    {"id": "q3", "type": "multiple", "stem": "哪些是偶数？",
     "options": [{"key": "A", "text": "2"}, {"key": "B", "text": "3"},
                 {"key": "C", "text": "4"}],
     "answer": ["A", "C"]}
  ]
}
''';

/// 从 xlsx 字节流里读出指定文件内容。
String partOf(List<int> xlsx, String name) {
  final archive = ZipDecoder().decodeBytes(xlsx);
  return utf8.decode(archive.findFile(name)!.content);
}

void main() {
  // 单测默认 locale 是 en，强制简中让 tr() 返回中文源文案。
  setUpAll(() {
    SettingsController.instance.language = AppLanguage.simplifiedChinese;
  });

  test('导出 JSON 全量：60 题不被 questionsOfBank 默认 limit=50 截断', () async {
    final repo = await openRepo();
    final result =
        await QuizImporter.commit(repo, QuizImporter.parse(bankJsonOf(60)));

    // 默认 limit=50 是详情页分页口径，导出走 limit:100000 全量。
    expect((await repo.questionsOfBank(result.bankId)).length, 50);
    final all = await repo.questionsOfBank(result.bankId, limit: 100000);
    expect(all.length, 60);

    final bank = (await repo.listBanks()).first;
    final exported = QuizExporter.encode(bank, all);
    final decoded = jsonDecode(exported) as Map<String, dynamic>;
    expect((decoded['questions'] as List).length, 60);
    expect((decoded['questions'] as List).last['stem'], '第 60 题题干');
  });

  test('xlsx：结构与列头齐全，行列数 = 题目数 + 1', () async {
    final repo = await openRepo();
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kMixed));
    final bank = (await repo.listBanks()).first;
    final questions = await repo.questionsOfBank(result.bankId, limit: 100000);
    expect(questions.length, 3);

    final xlsx = QuizExcelExporter.build(bank, questions);

    // zip 骨架六件套齐全。
    final names =
        ZipDecoder().decodeBytes(xlsx).files.map((f) => f.name).toList();
    for (final part in <String>[
      '[Content_Types].xml',
      '_rels/.rels',
      'xl/workbook.xml',
      'xl/_rels/workbook.xml.rels',
      'xl/styles.xml',
      'xl/worksheets/sheet1.xml',
    ]) {
      expect(names, contains(part));
    }

    final sheet = partOf(xlsx, 'xl/worksheets/sheet1.xml');
    for (final header in <String>['序号', '题型', '题干', '选项', '答案', '解析']) {
      expect(sheet, contains('<t xml:space="preserve">$header</t>'));
    }
    expect('<row r="1">'.allMatches(sheet).length, 1);
    expect(RegExp(r'<row r="\d+">').allMatches(sheet).length, 4,
        reason: '表头 + 3 道题');
  });

  test('xlsx：题型 / 选项 / 答案 / 解析与 XML 转义', () async {
    final repo = await openRepo();
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kMixed));
    final bank = (await repo.listBanks()).first;
    final questions = await repo.questionsOfBank(result.bankId, limit: 100000);

    final sheet = partOf(
        QuizExcelExporter.build(bank, questions), 'xl/worksheets/sheet1.xml');

    // 单选：选项逐个带引号、逗号分隔；题干 < & 已转义。
    expect(sheet, contains('<t xml:space="preserve">单选</t>'));
    expect(sheet, contains('"A. 对","B. 错"'));
    expect(sheet, contains('1 + 1 &lt; 3 且 1 &amp; 1 = 1？'));
    expect(sheet, contains('<t xml:space="preserve">解析 &lt; 文本</t>'));

    // 判断题没有选项列内容，答案翻译成「正确」。
    expect(sheet, contains('<t xml:space="preserve">判断</t>'));
    expect(sheet, contains('<t xml:space="preserve">正确</t>'));
    expect(
        RegExp(r'<t xml:space="preserve">"A\. [^<]*"</t>')
            .allMatches(sheet)
            .length,
        2,
        reason: '只有单选和多选带选项列');

    // 多选答案用顿号连接。
    expect(sheet, contains('<t xml:space="preserve">A、C</t>'));
  });

  test('文件名 / 工作表名清洗', () {
    const bank = Bank(id: 'b', name: '期中/复习:题库*', createdAt: 1);
    final name =
        QuizExcelExporter.fileNameOf(bank, DateTime(2026, 11, 14, 9, 5));
    expect(name, '题库-期中_复习_题库-20261114-0905.xlsx');
    expect(name.endsWith('.xlsx'), isTrue);

    expect(QuizExcelExporter.sheetNameOf(bank), '期中 复习 题库');
    final long = Bank(id: 'b', name: '字' * 40, createdAt: 1);
    expect(QuizExcelExporter.sheetNameOf(long).length, 31);
    expect(
      QuizExcelExporter.sheetNameOf(const Bank(id: 'b', name: '??', createdAt: 1)),
      '题库',
    );
  });
}
