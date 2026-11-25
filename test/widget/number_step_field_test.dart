import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/widgets/app_widgets.dart';
import '../support/test_env.dart';

/// 数字输入框带 ± 微调：夹紧到 [min, max]，减到 0 时清空并显示占位。
void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  tearDown(restoreSystemLanguage);

  Widget host(
    TextEditingController controller, {
    double min = 0,
    double max = 9,
    double step = 1,
    bool allowDecimal = false,
    ValueChanged<String>? onChanged,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: NumberStepField(
              controller: controller,
              fieldKey: const ValueKey('step-field'),
              stepKeyPrefix: 'step',
              min: min,
              max: max,
              step: step,
              allowDecimal: allowDecimal,
              onChanged: onChanged,
            ),
          ),
        ),
      );

  testWidgets('加减号微调并夹紧上下限', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final changes = <String>[];
    await tester.pumpWidget(host(controller, onChanged: changes.add));
    await tester.pumpAndSettle();

    TextField field() => tester.widget<TextField>(
        find.byKey(const ValueKey('step-field')));

    expect(field().controller!.text, isEmpty);

    await tester.tap(find.byKey(const ValueKey('step-plus')));
    await tester.pumpAndSettle();
    expect(controller.text, '1');

    await tester.tap(find.byKey(const ValueKey('step-minus')));
    await tester.pumpAndSettle();
    // min 为 0 时不写 "0"，回到空态让占位符显示。
    expect(controller.text, isEmpty);
    expect(changes, containsAllInOrder(<String>['1', '']));

    // 上限：连点 12 次不会超过 9。
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.byKey(const ValueKey('step-plus')));
      await tester.pump();
    }
    expect(controller.text, '9');
  });

  testWidgets('带小数时保留一位，整数不带小数点', (tester) async {
    final controller = TextEditingController(text: '1');
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller,
        min: 1, max: 10, step: 0.5, allowDecimal: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('step-plus')));
    await tester.pumpAndSettle();
    expect(controller.text, '1.5');
  });
}
