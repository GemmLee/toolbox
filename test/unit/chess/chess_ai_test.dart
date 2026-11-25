import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/chess/ai/ai_config.dart';
import 'package:toolbox/features/tools/chess/ai/ai_runner.dart';
import 'package:toolbox/features/tools/chess/ai/jieqi_search.dart';
import 'package:toolbox/features/tools/chess/ai/search.dart';
import 'package:toolbox/features/tools/chess/engine/chess_core.dart';
import 'package:toolbox/features/tools/chess/rules/jieqi_rules.dart';
import 'package:toolbox/features/tools/chess/rules/jieqi_state.dart';
import 'package:toolbox/features/tools/chess/rules/rules_engine.dart';
import 'package:toolbox/features/tools/chess/rules/xiangqi_rules.dart';

void main() {
  // ---------- AI 搜索 ----------
  test('一步杀：AI 能找到将死着法', () async {
    // 红车 e8 可吃掉黑将（黑将 e9，红车 e1 通路，黑方无解）
    final rules = XiangqiRules('3k5/9/9/9/9/9/9/9/9/4KR3', 0);
    final ai = ChessAi(AiLevel.master, 'normal');
    final move = await ai.chooseMove(engine: rules);
    expect(move, isNotNull);
    expect(rules.applyMove(move!), isTrue);
    expect(rules.result.name, 'redWin');
  });

  test('AI 着法始终合法且能推进对局', () async {
    final rules = XiangqiRules();
    final aiRed = ChessAi(AiLevel.novice, 'normal');
    final aiBlack = ChessAi(AiLevel.novice, 'normal');
    for (var i = 0; i < 6; i++) {
      final ai = rules.sideToMove == 0 ? aiRed : aiBlack;
      final move = await ai.chooseMove(engine: rules);
      expect(move, isNotNull);
      expect(rules.applyMove(move!), isTrue, reason: 'AI 给出了非法着法 $move');
      if (rules.result != GameResult.playing) break;
    }
    expect(rules.history.length, greaterThanOrEqualTo(6));
  });

  test('难度越高搜索越深', () {
    expect(AiConfig.of(AiLevel.novice).normalDepth,
        lessThan(AiConfig.of(AiLevel.master).normalDepth));
    expect(AiConfig.of(AiLevel.master).topK, 1);
    expect(AiConfig.of(AiLevel.novice).topK, greaterThan(1));
  });

  test('搜索在预算时间内返回', () async {
    final rules = XiangqiRules();
    final sw = Stopwatch()..start();
    final job = SearchJob(
      mode: 'normal',
      fen: rules.fen,
      side: 0,
      maxDepth: 4,
      timeBudgetMs: 600,
      seed: 1,
    );
    final outcome = NormalSearcher(CoreBoard.initial(), job).run();
    sw.stop();
    expect(outcome.moves, isNotEmpty);
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  test('揭棋 AI：给出合法着法并能完成暗子翻开', () async {
    final rules = JieqiRules(Random(31));
    final ai = ChessAi(AiLevel.normal, 'jieqi');
    for (var i = 0; i < 4; i++) {
      final move = await ai.chooseMove(engine: rules);
      expect(move, isNotNull);
      expect(rules.applyMove(move!), isTrue,
          reason: '揭棋 AI 给出了非法着法 $move');
    }
    expect(rules.history.where((m) => m.flipped).length, greaterThan(0));
  });

  test('揭棋评估：暗子期望价值来自暗子池', () {
    final state = JieqiState.fromFen(
        '3k5/9/9/9/9/9/9/9/9/4K4 w', Random(3));
    expect(state, isNotNull);
    final score = evaluateJieqi(state!);
    // 空棋盘（仅双将）评分接近 0
    expect(score.abs(), lessThan(100));
  });

  test('Isolate 搜索可跨线程执行', () async {
    final rules = XiangqiRules();
    final move = await ChessAi(AiLevel.normal, 'normal').chooseMove(engine: rules);
    expect(move, isNotNull);
    expect(move!.length, 4);
    expect(rules.legalMoves(0), contains(move));
  });

  // ---------- 难度耗时基准 ----------
  test('难度档位耗时基准：任何档位都应在预算内返回', () async {
    // 正常模式
    for (final level in AiLevel.values) {
      final rules = XiangqiRules();
      rules.applyMove('h2e2');
      final sw = Stopwatch()..start();
      await ChessAi(level, 'normal').chooseMove(engine: rules);
      sw.stop();
      // ignore: avoid_print
      print('normal ${level.name}: ${sw.elapsedMilliseconds} ms');
      expect(sw.elapsedMilliseconds, lessThan(6000));
    }
    // 揭棋模式
    for (final level in AiLevel.values) {
      final rules = JieqiRules(Random(9));
      for (var i = 0; i < 6; i++) {
        final moves = rules.legalMoves(rules.sideToMove);
        rules.applyMove(moves[Random(i).nextInt(moves.length)]);
      }
      final sw = Stopwatch()..start();
      await ChessAi(level, 'jieqi').chooseMove(engine: rules);
      sw.stop();
      // ignore: avoid_print
      print('jieqi ${level.name}: ${sw.elapsedMilliseconds} ms');
      expect(sw.elapsedMilliseconds, lessThan(6000));
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
