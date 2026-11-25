import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/chess/game_controller.dart';

import '../../support/test_env.dart';

/// 落子事件必须真实反映「吃子 / 将军」，配音才会在正确时机响起。
void main() {
  installCleanEnv();

  ChessGameController withEvents(List<ChessMoveFeedback> events) {
    final controller = ChessGameController();
    controller.onMovePlayed = events.add;
    return controller;
  }

  test('普通走子：无吃子、无将军', () async {
    final events = <ChessMoveFeedback>[];
    final controller = withEvents(events);
    await controller.tap('h2');
    await controller.tap('e2');
    expect(events.length, 1);
    expect(events.single.captured, isFalse);
    expect(events.single.check, isFalse);
    controller.dispose();
  });

  test('吃子：反馈 captured 为 true', () async {
    final events = <ChessMoveFeedback>[];
    final controller = withEvents(events);
    // 黑将 d9、黑卒 a3、红车 a0、红帅 e0：红车 a0a3 吃掉黑卒。
    expect(
      controller.loadFen('3k5/9/9/9/9/9/p8/9/9/R3K4 w'),
      isTrue,
    );
    await controller.tap('a0');
    await controller.tap('a3');
    expect(events.length, 1);
    expect(events.single.captured, isTrue);
    expect(controller.history.last.captured, isNotNull);
    controller.dispose();
  });

  test('走子后将军：反馈 check 为 true', () async {
    final events = <ChessMoveFeedback>[];
    final controller = withEvents(events);
    // 黑将 d9、红车 a0、红帅 e0：红车 a0d0 沿 d 列直将。
    expect(
      controller.loadFen('3k5/9/9/9/9/9/9/9/9/R3K4 w'),
      isTrue,
    );
    await controller.tap('a0');
    await controller.tap('d0');
    expect(events.length, 1);
    expect(events.single.captured, isFalse);
    expect(events.single.check, isTrue);
    expect(controller.inCheck, isTrue);
    controller.dispose();
  });
}
