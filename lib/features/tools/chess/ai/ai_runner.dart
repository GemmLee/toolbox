import 'dart:isolate';
import 'dart:math';

import '../rules/rules_engine.dart';
import 'ai_config.dart';
import 'search.dart';

/// 象棋 AI：在后台 Isolate 中搜索，避免阻塞 UI。
///
/// 用法：
/// ```dart
/// final move = await ChessAi(AiLevel.normal, ChessMode.normal)
///     .chooseMove(engine: rules);
/// ```
class ChessAi {
  ChessAi(this.level, this.mode);

  final AiLevel level;

  /// 'normal' 或 'jieqi'。
  final String mode;

  AiConfig get config => AiConfig.of(level);
  final Random _rng = Random();

  /// 返回坐标着法（如 'h2e2'），无着可走返回 null。
  Future<String?> chooseMove({required RulesEngine engine}) async {
    final job = SearchJob(
      mode: mode,
      fen: engine.fen,
      side: engine.sideToMove,
      maxDepth: mode == 'jieqi' ? config.jieqiDepth : config.normalDepth,
      timeBudgetMs: mode == 'jieqi' ? config.timeMs : config.normalTimeMs,
      seed: _rng.nextInt(1 << 30),
      jieqiState: mode == 'jieqi' && engine is JieqiEngineStateProvider
          ? (engine as JieqiEngineStateProvider).stateData
          : null,
      expansion: config.jieqiExpansion,
      topK: config.topK,
    );

    final result = await Isolate.run(() => runSearchJob(job.toMap()));
    final outcome = SearchOutcome.fromList(result);
    if (outcome.isEmpty) return null;
    return _pick(outcome);
  }

  /// 按难度做随机扰动：新手从评分接近的着法中随机选，大师只取最优。
  String _pick(SearchOutcome outcome) {
    final k = config.topK.clamp(1, outcome.moves.length);
    if (k == 1) return outcome.moves.first;
    // 评分越靠前权重越高，但保留一定随机性
    final weights = <int>[];
    for (var i = 0; i < k; i++) {
      weights.add(k - i);
    }
    final total = weights.fold<int>(0, (a, b) => a + b);
    var pick = _rng.nextInt(total);
    for (var i = 0; i < weights.length; i++) {
      pick -= weights[i];
      if (pick < 0) return outcome.moves[i];
    }
    return outcome.moves.first;
  }
}

/// 揭棋引擎需要向 AI 提供完整内部状态（含暗子池）。
abstract class JieqiEngineStateProvider {
  String get stateData;
}
