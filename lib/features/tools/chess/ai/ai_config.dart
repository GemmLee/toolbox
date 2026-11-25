import '../engine/chess_core.dart';
import '../rules/jieqi_state.dart';
import 'jieqi_search.dart';
import 'search.dart';

/// 难度档位。
enum AiLevel { novice, normal, master }

/// 难度参数：正常模式用搜索深度/时间 + 随机扰动；
/// 揭棋模式用搜索深度 + 概率展开层数 + 随机扰动。
class AiConfig {
  const AiConfig({
    required this.normalDepth,
    required this.normalTimeMs,
    required this.jieqiDepth,
    required this.jieqiExpansion,
    required this.timeMs,
    required this.topK,
  });

  /// 正常模式最大搜索深度。
  final int normalDepth;

  /// 正常模式时间预算（毫秒）。
  final int normalTimeMs;

  /// 揭棋模式最大搜索深度。
  final int jieqiDepth;

  /// 揭棋暗子概率展开层数。
  final int jieqiExpansion;

  /// 揭棋时间预算（毫秒）。
  final int timeMs;

  /// 从评分最高的前 N 个着法中随机挑选（1 = 不随机）。
  final int topK;

  static const AiConfig novice = AiConfig(
    normalDepth: 2,
    normalTimeMs: 400,
    jieqiDepth: 2,
    jieqiExpansion: 1,
    timeMs: 500,
    topK: 5,
  );

  static const AiConfig normal = AiConfig(
    normalDepth: 4,
    normalTimeMs: 900,
    jieqiDepth: 3,
    jieqiExpansion: 2,
    timeMs: 1200,
    topK: 2,
  );

  static const AiConfig master = AiConfig(
    normalDepth: 6,
    normalTimeMs: 2500,
    jieqiDepth: 4,
    jieqiExpansion: 3,
    timeMs: 2500,
    topK: 1,
  );

  static AiConfig of(AiLevel level) => switch (level) {
        AiLevel.novice => novice,
        AiLevel.normal => normal,
        AiLevel.master => master,
      };
}

/// 搜索任务入口（可在 Isolate 中执行）：入参/出参均为基础类型。
List<String> runSearchJob(Map<Object?, Object?> args) {
  final job = SearchJob.fromMap(args);
  if (job.mode == 'jieqi') {
    final state = job.jieqiState != null
        ? JieqiState.deserialize(job.jieqiState!)
        : JieqiState.fromFen(job.fen);
    if (state == null) return const <String>['0', '', ''];
    state.board.side = job.side;
    final outcome = JieqiSearcher(state, job).run();
    return outcome.toList();
  }
  final board = chessBoardFromFen(job.fen, job.side);
  if (board == null) return const <String>['0', '', ''];
  final outcome = NormalSearcher(board, job).run();
  return outcome.toList();
}
