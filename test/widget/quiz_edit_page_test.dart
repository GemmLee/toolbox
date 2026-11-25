import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_question_edit_page.dart';
import '../support/test_env.dart';

/// 题目编辑器：表单交互、题型口径与持久化注入。
///
/// 用 saver 注入避免 widget 测试跑真实 sqflite；编辑器放在有下层路由的
/// Navigator 里，保存后能正常 pop 并拿到返回值。
void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  tearDown(restoreSystemLanguage);

  const Question single = Question(
    id: 's1',
    bankId: 'b1',
    type: QuestionType.single,
    stem: '1 + 1 等于多少？',
    options: <OptionItem>[
      OptionItem(key: 'A', text: '1'),
      OptionItem(key: 'B', text: '2'),
    ],
    answer: <String>['B'],
    analysis: '基础加法',
    contentHash: 'old',
  );

  const Question judge = Question(
    id: 'j1',
    bankId: 'b1',
    type: QuestionType.trueFalse,
    stem: '地球是圆的。',
    answer: <String>['true'],
    contentHash: 'old',
  );

  const Question essay = Question(
    id: 'e1',
    bankId: 'b1',
    type: QuestionType.short,
    stem: '简述牛顿第一定律。',
    answer: <String>['惯性定律'],
    contentHash: 'old',
  );

  testWidgets('单选题可修改题干 / 选项 / 正确答案 / 解析', (tester) async {
    Question? saved;
    final box = await pumpEditor(tester, single, saver: (q) async {
      saved = q;
    });
    await tester.enterText(
        find.byKey(const ValueKey('question-edit-stem')), '新题干');
    await tester.enterText(
        find.byKey(const ValueKey('question-edit-option-A')), '新选项 A');
    await tester.tap(find.byKey(const ValueKey('question-edit-answer-A')));
    await tester.enterText(
        find.byKey(const ValueKey('question-edit-analysis')), '新解析');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('question-edit-save')));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(box.value, isNotNull);
    expect(saved!.stem, '新题干');
    expect(saved!.options.first.text, '新选项 A');
    expect(saved!.answer, <String>['A']);
    expect(saved!.analysis, '新解析');
    expect(saved!.contentHash, isNot(single.contentHash));
  });

  testWidgets('题干为空时拒绝保存', (tester) async {
    var calls = 0;
    final box = await pumpEditor(tester, single, saver: (q) async {
      calls++;
    });
    await tester.enterText(
        find.byKey(const ValueKey('question-edit-stem')), '   ');
    await tester.tap(find.byKey(const ValueKey('question-edit-save')));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(box.value, isNull);
  });

  testWidgets('判断题只改答案，但固定选项要写回库里', (tester) async {
    Question? saved;
    await pumpEditor(tester, judge, saver: (q) async {
      saved = q;
    });
    expect(
        find.byKey(const ValueKey('question-edit-option-true')), findsNothing);
    expect(find.text('正确'), findsWidgets);
    expect(find.text('错误'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('question-edit-answer-false')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('question-edit-save')));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    // 答题页的选项直接来自 options，清空会让判断题没有「正确 / 错误」可选。
    expect(
        saved!.options.map((o) => o.key).toList(), <String>['true', 'false']);
    expect(saved!.answer, <String>['false']);
  });

  testWidgets('简答题按行拆分多个可接受答案', (tester) async {
    Question? saved;
    await pumpEditor(tester, essay, saver: (q) async {
      saved = q;
    });
    await tester.enterText(
        find.byKey(const ValueKey('question-edit-answer-text')),
        '惯性定律\n不受外力时保持匀速直线运动');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('question-edit-save')));
    await tester.pumpAndSettle();

    expect(saved!.answer, <String>['惯性定律', '不受外力时保持匀速直线运动']);
  });

  testWidgets('可添加与删除选项，答案跟着失效选项一起清理', (tester) async {
    Question? saved;
    await pumpEditor(tester, single, saver: (q) async {
      saved = q;
    });
    await tester.tap(find.byKey(const ValueKey('question-edit-add-option')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('question-edit-option-C')), '3');
    await tester.tap(find.byKey(const ValueKey('question-edit-answer-A')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('question-edit-remove-B')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('question-edit-save')));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.options.map((o) => o.key).toList(), <String>['A', 'C']);
    expect(saved!.answer, <String>['A']);
  });
}

class EditorResult {
  Question? value;
}

Future<EditorResult> pumpEditor(
  WidgetTester tester,
  Question question, {
  Future<void> Function(Question)? saver,
}) async {
  final box = EditorResult();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            key: const ValueKey('open-editor'),
            onPressed: () async {
              box.value = await Navigator.of(context).push<Question>(
                MaterialPageRoute<Question>(
                  builder: (_) => QuestionEditPage(
                    question: question,
                    saver: saver,
                  ),
                ),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const ValueKey('open-editor')));
  await tester.pumpAndSettle();
  return box;
}
