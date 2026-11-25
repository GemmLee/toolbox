import '../engine/chess_core.dart';
import '../rules/jieqi_state.dart';
import 'evaluation.dart';
import 'search.dart';

/// 揭棋搜索：在 Alpha-Beta 中插入「暗子身份概率展开层」。
///
/// 暗子走动后必然翻开，其真实身份由剩余暗子池的概率分布决定；
/// 展开层按概率加权求和得到该分支的期望值，再参与剪枝。
class JieqiSearcher {
  JieqiSearcher(this.state, this.job)
      : _stopwatch = Stopwatch()..start();

  final JieqiState state;
  final SearchJob job;
  final Stopwatch _stopwatch;
  int _nodes = 0;
  bool _aborted = false;

  int get nodes => _nodes;

  bool get _timeUp {
    if (_nodes % 128 != 0) return false;
    return _stopwatch.elapsedMilliseconds >= job.timeBudgetMs;
  }

  SearchOutcome run() {
    var depth = 0;
    var last = const SearchOutcome(<String>[], <int>[], 0);
    var root = state.legalMoves();
    if (root.isEmpty) return last;

    for (var d = 1; d <= job.maxDepth; d++) {
      final scored = <ScoredMove>[];
      var alpha = -mateScore * 2;
      for (final mv in root) {
        final value = _moveValue(mv, d, alpha, mateScore * 2, 1, job.expansion);
        if (_aborted) break;
        scored.add(ScoredMove(mv, value));
        if (value > alpha) alpha = value;
      }
      if (_aborted && scored.isEmpty) break;
      if (scored.isNotEmpty) {
        scored.sort((a, b) => b.score.compareTo(a.score));
        last = SearchOutcome(
          scored.map((s) => moveToCode(s.move)).toList(),
          scored.map((s) => s.score).toList(),
          d,
        );
        root = scored.map((s) => s.move).toList();
      }
      depth = d;
      if (_aborted || _stopwatch.elapsedMilliseconds >= job.timeBudgetMs) break;
    }
    return SearchOutcome(last.moves, last.scores, depth);
  }

  /// 单个着法的价值：若走动方是暗子则做概率展开，否则直接递归。
  int _moveValue(int mv, int depth, int alpha, int beta, int ply, int expansion) {
    final from = moveFrom(mv);
    final team = teamOfCode(state.board.cells[from]);
    if (state.revealed[from] == 0 && expansion > 0) {
      final candidates = _candidateKinds(team);
      if (candidates.isEmpty) {
        return _applyAndSearch(mv, depth, alpha, beta, ply, expansion);
      }
      double total = 0;
      for (final kind in candidates) {
        final p = state.probability(team, kind);
        final value = _applyAndSearch(mv, depth, alpha, beta, ply, expansion - 1,
            forceKind: kind);
        if (_aborted) return value;
        total += p * value;
      }
      return total.round();
    }
    return _applyAndSearch(mv, depth, alpha, beta, ply, expansion);
  }

  int _applyAndSearch(
    int mv,
    int depth,
    int alpha,
    int beta,
    int ply,
    int expansion, {
    int? forceKind,
  }) {
    final from = moveFrom(mv);
    final team = teamOfCode(state.board.cells[from]);
    final undo = state.make(mv);

    int? overrideKind;
    if (forceKind != null) {
      // 把展开出的身份写进局面（搜索期临时假设），并同步暗子池
      final realKind = undo.revealedKind;
      if (realKind != 0) {
        state.pool[team][realKind] += 1;
        state.pool[team][forceKind] =
            (state.pool[team][forceKind] - 1).clamp(0, 15);
        state.board.cells[moveTo(mv)] = codeOf(team, forceKind);
        state.board.freeAE[moveTo(mv)] =
            (forceKind == kAdvisor || forceKind == kElephant) ? 1 : 0;
        state.truth[moveTo(mv)] = forceKind;
        overrideKind = realKind;
      }
    }

    final value = -_search(depth - 1, -beta, -alpha, ply + 1, expansion);

    if (overrideKind != null) {
      // 还原池与身份后再撤销走法
      state.pool[team][forceKind!] += 1;
      state.pool[team][overrideKind] -= 1;
    }
    state.unmake(undo);
    return value;
  }

  int _search(int depth, int alpha, int beta, int ply, int expansion) {
    _nodes++;
    if (_timeUp) {
      _aborted = true;
      return _standPat();
    }
    final moves = state.legalMoves();
    if (moves.isEmpty) return -mateScore + ply;
    if (depth <= 0) return _standPat();

    var best = -mateScore * 2;
    final ordered = List<int>.from(moves)
      ..sort((a, b) => orderScore(state.board, b).compareTo(orderScore(state.board, a)));
    for (final mv in ordered) {
      final value = _moveValue(mv, depth, alpha, beta, ply, expansion);
      if (_aborted) return best;
      if (value > best) best = value;
      if (value > alpha) alpha = value;
      if (alpha >= beta) break;
    }
    return best;
  }

  int _standPat() {
    final score = evaluateJieqi(state);
    return state.side == kRed ? score : -score;
  }

  /// 按概率取前若干个可能的身份（限制分支数，保证手机端可实时返回）。
  List<int> _candidateKinds(int team) {
    final entries = <MapEntry<int, double>>[];
    for (var k = 1; k < 8; k++) {
      final p = state.probability(team, k);
      if (p > 0.02) entries.add(MapEntry<int, double>(k, p));
    }
    entries.sort((a, b) => b.value.compareTo(a.value));
    final limit = job.expansion >= 3 ? 4 : (job.expansion == 2 ? 3 : 2);
    return entries.take(limit).map((e) => e.key).toList();
  }
}

/// 揭棋局面评估（红方视角，正数红优）。
///
/// 只使用公开信息：明子按真实棋种计值，暗子按暗子池的期望价值计值；
/// 叠加揭棋启发式（空头炮、沉底炮、暗子灵活性）。
int evaluateJieqi(JieqiState state) {
  final board = state.board;
  var score = 0;
  var darkRed = 0;
  var darkBlack = 0;

  for (var i = 0; i < 90; i++) {
    final code = board.cells[i];
    if (code == 0) continue;
    final team = teamOfCode(code);
    final revealed = state.revealed[i] == 1;
    if (!revealed) {
      if (team == kRed) {
        darkRed++;
      } else {
        darkBlack++;
      }
    }
    final kind = kindOfCode(code); // 暗子为格位棋种，用于位置价值
    final x = xOf(i);
    final y = yOf(i);
    final advance = team == kRed ? y : 9 - y;

    double value;
    if (revealed) {
      value = pieceValue[kind].toDouble();
    } else {
      // 暗子期望价值：暗子池按概率加权
      var expected = 0.0;
      for (var k = 1; k < 8; k++) {
        expected += state.probability(team, k) * pieceValue[k];
      }
      value = expected;
    }

    switch (kind) {
      case kPawn:
        value += pawnAdvance[advance];
        if (x == 4) value += 6;
        break;
      case kHorse:
        value += advance >= 5 ? 20 : 0;
        break;
      case kRook:
        value += advance >= 5 ? 25 : 0;
        break;
      case kCannon:
        if (x == 4) value += 25;
        if (y == (team == kRed ? 9 : 0)) value += 30; // 沉底炮
        if (_emptyFileCannon(board, i, team)) value += 60; // 空头炮
        break;
      default:
        break;
    }

    score += team == kRed ? value.round() : -value.round();
  }

  // 暗子灵活性：自己的暗子越多选择越多，对手暗子越多威胁越不确定
  score += (darkRed - darkBlack) * 10;
  return score;
}

bool _emptyFileCannon(CoreBoard board, int idx, int team) {
  if (xOf(idx) != 4) return false;
  final y = yOf(idx);
  final targetY = team == kRed ? 9 : 0;
  final from = y < targetY ? y : targetY;
  final to = y < targetY ? targetY : y;
  for (var cy = from + 1; cy < to; cy++) {
    if (board.cells[idxOf(4, cy)] != 0) return false;
  }
  return true;
}
