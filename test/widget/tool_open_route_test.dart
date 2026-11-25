import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/widgets/tool_open_route.dart';

void main() {
  test('进场 300ms / 退出 220ms，短到不拖慢连续翻看工具', () {
    final route = ToolOpenRoute<void>(builder: (_) => const SizedBox());
    expect(route.transitionDuration, const Duration(milliseconds: 300));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 220));
  });

  testWidgets('过渡是淡入 + 位移 + 缩放三层，动画关闭时直接给子组件', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox();
          },
        ),
      ),
    );
    final route = ToolOpenRoute<void>(builder: (_) => const SizedBox());
    const child = Text('工具页');
    const half = AlwaysStoppedAnimation<double>(0.5);

    final animated = route.buildTransitions(context, half, half, child);
    expect(animated, isA<FadeTransition>());
    expect(
      (animated as FadeTransition).child,
      isA<SlideTransition>(),
    );

    // 系统「移除动画」：直接返回页面本身，不再包过渡。
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox();
          },
        ),
      ),
    );
    final still = route.buildTransitions(context, half, half, child);
    expect(still, same(child));
  });

  testWidgets('用这条路由能真实打开页面并落定', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                ToolOpenRoute<void>(
                  builder: (_) => const Scaffold(
                    body: Center(child: Text('工具页')),
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(find.text('工具页'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('工具页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
