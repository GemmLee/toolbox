import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:toolbox/core/storage/app_files.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_export.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';

/// 题库导出：序列化结果必须能被导入器原样读回（可分享 / 可迁移）。
void main() {
  const bank = Bank(id: 'b1', name: '演示题库', description: '单元测试用');

  const questions = <Question>[
    Question(
      id: 'q1',
      bankId: 'b1',
      importId: 'single-1',
      type: QuestionType.single,
      stem: '下列哪个是质数？',
      options: <OptionItem>[
        OptionItem(key: 'A', text: '4'),
        OptionItem(key: 'B', text: '7'),
      ],
      answer: <String>['B'],
      analysis: '7 只有 1 和它本身两个因数。',
      tags: <String>['数学'],
      difficulty: 3,
    ),
    Question(
      id: 'q2',
      bankId: 'b1',
      type: QuestionType.trueFalse,
      stem: '水的沸点在标准大气压下是 100℃。',
      options: <OptionItem>[
        OptionItem(key: 'true', text: '正确'),
        OptionItem(key: 'false', text: '错误'),
      ],
      answer: <String>['true'],
    ),
    Question(
      id: 'q3',
      bankId: 'b1',
      type: QuestionType.fill,
      stem: '中国的首都是____。',
      answer: <String>['北京'],
    ),
  ];

  test('导出的 JSON 能被导入器原样解析', () {
    final text = QuizExporter.encode(bank, questions);
    final preview = QuizImporter.parse(text);

    expect(preview.hasErrors, isFalse);
    expect(preview.bankName, '演示题库');
    expect(preview.total, 3);
    expect(preview.typeCounts[QuestionType.single], 1);
    expect(preview.typeCounts[QuestionType.trueFalse], 1);
    expect(preview.typeCounts[QuestionType.fill], 1);

    final single = preview.questions.first;
    expect(single.stem, '下列哪个是质数？');
    expect(single.answer, <String>['B']);
    expect(single.analysis, '7 只有 1 和它本身两个因数。');
    expect(single.tags, <String>['数学']);
    expect(single.difficulty, 3);

    final judge = preview.questions[1];
    expect(judge.answer, <String>['true']);

    expect(preview.questions.last.answer, <String>['北京']);
  });

  test('判断题不导出 options，选项由 App 固定补齐', () {
    final map = QuizExporter.bankToMap(bank, questions);
    final items = (map['questions'] as List).cast<Map<String, dynamic>>();
    final judge = items.firstWhere((e) => e['type'] == 'true_false');
    expect(judge.containsKey('options'), isFalse);

    final single = items.firstWhere((e) => e['type'] == 'single');
    expect((single['options'] as List), hasLength(2));
  });

  test('导出丢弃本地存储细节，id 缺失时按序号补齐', () {
    final map = QuizExporter.bankToMap(bank, questions);
    final items = (map['questions'] as List).cast<Map<String, dynamic>>();

    // 有 importId 的沿用 importId，没有的用 q1/q2… 保证同文件内唯一。
    expect(items[0]['id'], 'single-1');
    expect(items[1]['id'], 'q2');
    // bankId / contentHash / orderNo 属于本地存储细节，不导出。
    expect(items[0].containsKey('bankId'), isFalse);
    expect(items[0].containsKey('contentHash'), isFalse);
    expect(items[0].containsKey('orderNo'), isFalse);
  });

  test('文件名带题库名与时间戳，并去掉非法字符', () {
    const odd = Bank(id: 'b2', name: ' 数据结构/算法: 期末 ');
    final name = QuizExporter.fileNameOf(odd, DateTime(2026, 11, 13, 8, 5));
    expect(name, '题库-数据结构_算法_期末-20261113-0805.json');
    expect(name.contains('/'), isFalse);
    expect(name.contains(':'), isFalse);

    const blank = Bank(id: 'b3', name: '///');
    expect(
      QuizExporter.fileNameOf(blank, DateTime(2026, 1, 2, 3, 4)),
      '题库-未命名-20260102-0304.json',
    );
  });

  test('导出文件落到存储空间的题库分类，可被再次导入', () async {
    final dir = await Directory.systemTemp.createTemp('quiz_export_store');
    AppStore.useRootForTest(dir);
    addTearDown(() {
      AppStore.useRootForTest(null);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final file = await AppStore.saveText(
      category: AppStoreCategory.quiz,
      name: QuizExporter.fileNameOf(bank, DateTime(2026, 11, 13, 8, 5)),
      content: QuizExporter.encode(bank, questions),
    );

    expect(p.basename(file.path), '题库-演示题库-20261113-0805.json');
    expect(p.basename(file.path).startsWith('题库-'), isTrue);
    final listed = await AppStore.list(AppStoreCategory.quiz);
    expect(listed.map((f) => f.name), contains(p.basename(file.path)));
    expect(QuizImporter.parse(file.file.readAsStringSync()).total, 3);
  });
}
