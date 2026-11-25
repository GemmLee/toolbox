import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/app_theme.dart';
import 'package:toolbox/core/tool_registry.dart';
import 'package:toolbox/features/tools/builtin_tools.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_common.dart';

/// 刷题工具专用字号作用域：放大各类文字、只放大一次、弹层与子页面同步。
void main() {
  final ThemeData raw = AppTheme.light();

  double grown(double size) => size * kQuizFontScale + kQuizFontDelta;

  TextStyle? resolve(WidgetStateProperty<TextStyle?>? property) =>
      property?.resolve(<WidgetState>{});

  testWidgets('刷题助手工具入口已套上 QuizScope', (tester) async {
    registerBuiltinTools();
    final quiz = ToolRegistry.tools.firstWhere((t) => t.id == 'quiz');
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      theme: raw,
      home: Builder(builder: (c) {
        context = c;
        return const SizedBox.shrink();
      }),
    ));
    // 只构造 widget，不插入树中，避免触发题库数据库的 FutureBuilder。
    expect(quiz.builder(context), isA<QuizScope>());
  });

  testWidgets('QuizScope 把正文与各类控件文字统一放大一档', (tester) async {
    late ThemeData baseline;
    late ThemeData scoped;
    await tester.pumpWidget(MaterialApp(
      theme: raw,
      home: Builder(builder: (context) {
        baseline = Theme.of(context);
        return QuizScope(
          child: Builder(builder: (inner) {
            scoped = Theme.of(inner);
            return const SizedBox.shrink();
          }),
        );
      }),
    ));

    // 题干 / 选项 / 解析 / 统计数字等正文角色全部变大，层级关系仍保留。
    final roles = <TextStyle? Function(TextTheme)>[
      (t) => t.bodySmall,
      (t) => t.bodyMedium,
      (t) => t.bodyLarge,
      (t) => t.titleSmall,
      (t) => t.titleMedium,
      (t) => t.titleLarge,
      (t) => t.labelLarge,
      (t) => t.displaySmall,
    ];
    for (final role in roles) {
      final before = role(baseline.textTheme)?.fontSize;
      final after = role(scoped.textTheme)?.fontSize;
      if (before == null || after == null) continue;
      expect(after, closeTo(grown(before), 0.001));
    }
    expect(scoped.textTheme.bodyMedium!.fontSize,
        greaterThan(scoped.textTheme.bodySmall!.fontSize!));
    expect(scoped.textTheme.bodyMedium!.fontSize,
        greaterThan(baseline.textTheme.bodyMedium!.fontSize!));

    // 按钮 / 标签 / 列表 / 输入 / 弹窗等自带硬编码字号的组件主题同步放大。
    expect(scoped.appBarTheme.titleTextStyle!.fontSize,
        closeTo(grown(baseline.appBarTheme.titleTextStyle!.fontSize!), 0.001));
    expect(
        resolve(scoped.filledButtonTheme.style!.textStyle)!.fontSize,
        closeTo(
            grown(
                resolve(baseline.filledButtonTheme.style!.textStyle)!.fontSize!),
            0.001));
    expect(
        resolve(scoped.textButtonTheme.style!.textStyle)!.fontSize,
        closeTo(
            grown(
                resolve(baseline.textButtonTheme.style!.textStyle)!.fontSize!),
            0.001));
    expect(scoped.chipTheme.labelStyle!.fontSize,
        closeTo(grown(baseline.chipTheme.labelStyle!.fontSize!), 0.001));
    expect(scoped.listTileTheme.titleTextStyle!.fontSize,
        closeTo(grown(baseline.listTileTheme.titleTextStyle!.fontSize!), 0.001));
    expect(scoped.listTileTheme.subtitleTextStyle!.fontSize,
        closeTo(grown(baseline.listTileTheme.subtitleTextStyle!.fontSize!), 0.001));
    expect(scoped.inputDecorationTheme.hintStyle!.fontSize,
        closeTo(grown(baseline.inputDecorationTheme.hintStyle!.fontSize!), 0.001));
    expect(scoped.dialogTheme.titleTextStyle!.fontSize,
        closeTo(grown(baseline.dialogTheme.titleTextStyle!.fontSize!), 0.001));
    expect(scoped.popupMenuTheme.textStyle!.fontSize,
        closeTo(grown(baseline.popupMenuTheme.textStyle!.fontSize!), 0.001));
    expect(scoped.snackBarTheme.contentTextStyle!.fontSize,
        closeTo(grown(baseline.snackBarTheme.contentTextStyle!.fontSize!), 0.001));
  });

  testWidgets('QuizScope 嵌套时只放大一次', (tester) async {
    late double fontSize;
    await tester.pumpWidget(MaterialApp(
      theme: raw,
      home: QuizScope(
        child: QuizScope(
          child: Builder(builder: (context) {
            fontSize = Theme.of(context).textTheme.bodyMedium!.fontSize!;
            return const SizedBox.shrink();
          }),
        ),
      ),
    ));
    expect(fontSize,
        closeTo(grown(raw.textTheme.bodyMedium!.fontSize!), 0.001));
  });

  testWidgets('刷题页内弹出的对话框继承放大后的字号', (tester) async {
    late BuildContext pageContext;
    await tester.pumpWidget(MaterialApp(
      theme: raw,
      home: QuizScope(
        child: Builder(builder: (context) {
          pageContext = context;
          return const Scaffold();
        }),
      ),
    ));

    late double dialogFont;
    showDialog<void>(
      context: pageContext,
      builder: (context) {
        dialogFont = Theme.of(context).textTheme.bodyMedium!.fontSize!;
        return const AlertDialog(title: Text('标题'));
      },
    );
    await tester.pumpAndSettle();
    expect(dialogFont,
        closeTo(grown(raw.textTheme.bodyMedium!.fontSize!), 0.001));
  });

  testWidgets('quizRoute 推进的子页面字号与其它刷题页一致，不叠加', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    late double pushedFont;
    await tester.pumpWidget(MaterialApp(
      theme: raw,
      navigatorKey: navigator,
      home: QuizScope(child: Builder(builder: (context) => const Scaffold())),
    ));

    navigator.currentState!.push(quizRoute<void>(
      builder: (context) {
        pushedFont = Theme.of(context).textTheme.bodyMedium!.fontSize!;
        return const Scaffold(body: Text('子页面'));
      },
    ));
    await tester.pumpAndSettle();

    expect(pushedFont,
        closeTo(grown(raw.textTheme.bodyMedium!.fontSize!), 0.001));
  });
}
