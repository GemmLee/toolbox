import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/storage/app_files.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_common.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_page.dart';
import '../support/test_env.dart';
import 'quiz_bank_cards_test.dart' show openRepo;

const String _bankA = '''
{
  "version": 1,
  "bankName": "甲题库",
  "questions": [
    {"id": "a1", "type": "single", "stem": "A1题",
     "options": [{"key":"A","text":"1"},{"key":"B","text":"2"}], "answer": ["B"]},
    {"id": "a2", "type": "trueFalse", "stem": "A2题", "answer": ["true"]}
  ]
}
''';

const String _bankB = '''
{
  "version": 1,
  "bankName": "乙题库",
  "questions": [
    {"id": "b1", "type": "single", "stem": "B1题",
     "options": [{"key":"A","text":"1"},{"key":"B","text":"2"}], "answer": ["A"]},
    {"id": "a2", "type": "trueFalse", "stem": "A2题", "answer": ["true"]}
  ]
}
''';

void main() {
  late QuizRepository repo;
  late Directory storeRoot;

  setUp(() async {
    mockPrefs();
    await useChineseUi();
    storeRoot = await Directory.systemTemp.createTemp('quiz_multi_store');
    AppStore.useRootForTest(storeRoot);
    repo = await openRepo();
    QuizServices.testRepo = repo;
  });

  tearDown(() async {
    QuizServices.reset();
    AppStore.useRootForTest(null);
    if (storeRoot.existsSync()) await storeRoot.delete(recursive: true);
    await restoreSystemLanguage();
  });

  testWidgets('长按题库进入多选，合并后只剩目标题库且题目去重', (tester) async {
    await QuizImporter.commit(repo, QuizImporter.parse(_bankA));
    await QuizImporter.commit(repo, QuizImporter.parse(_bankB));
    final banks = await repo.listBanks();
    expect(banks.length, 2);

    await tester.pumpWidget(const MaterialApp(home: QuizPage()));
    await tester.pumpAndSettle();

    await tester
        .longPress(find.byKey(ValueKey('quiz-bank-card-${banks.first.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quiz-selection-merge')), findsOneWidget);
    expect(find.byKey(const ValueKey('quiz-selection-export')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('quiz-bank-card-${banks.last.id}')));
    await tester.pumpAndSettle();
    expect(find.text('已选 2'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('quiz-selection-merge')));
    await tester.pumpAndSettle();
    expect(find.text('选择保留的题库'), findsOneWidget);
    final target = find.byKey(ValueKey('quiz-merge-target-${banks.first.id}'));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();

    // ignore: avoid_print
    final rest = await repo.listBanks();
    // ignore: avoid_print
    expect(rest.length, 1);
    expect(rest.single.id, banks.first.id);
    // 乙题库 2 题中 A2 与甲题库重复，只迁 1 题。
    expect((await repo.questionsOfBank(banks.first.id, limit: 1000)).length, 3);
    expect(find.byKey(const ValueKey('quiz-selection-merge')), findsNothing);
  });

  testWidgets('退出选中模式后恢复普通题库卡片操作', (tester) async {
    await QuizImporter.commit(repo, QuizImporter.parse(_bankA));
    await tester.pumpWidget(const MaterialApp(home: QuizPage()));
    await tester.pumpAndSettle();

    final bank = (await repo.listBanks()).first;
    await tester.longPress(find.byKey(ValueKey('quiz-bank-card-${bank.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quiz-selection-exit')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('quiz-selection-exit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quiz-selection-exit')), findsNothing);
    // 排序入口已删除，退出多选后只剩新建文件夹与导入。
    expect(find.byKey(const ValueKey('quiz-bank-order')), findsNothing);
    expect(find.byKey(const ValueKey('quiz-folder-create')), findsOneWidget);
  });
}
