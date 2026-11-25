import '../engine/chess_core.dart';
import 'evaluation.dart';

/// 一次搜索任务的入参（仅含可跨 Isolate 传递的基础类型）。
class SearchJob {
  const SearchJob({
    required this.mode,
    required this.fen,
    required this.side,
    required this.maxDepth,
    required this.timeBudgetMs,
    required this.seed,
    this.jieqiState,
    this.expansion = 0,
    this.topK = 1,
  });

  /// 'normal' 或 'jieqi'。
  final String mode;

  /// 正常模式：棋子摆放字段；揭棋模式：揭棋 FEN。
  final String fen;

  final int side;
  final int maxDepth;
  final int timeBudgetMs;
  final int seed;
  final String? jieqiState;

  /// 揭棋：暗子概率展开层数。
  final int expansion;

  /// 随机挑选范围（新手档在评分接近的着法中随机）。
  final int topK;

  Map<String, Object?> toMap() => <String, Object?>{
        'mode': mode,
        'fen': fen,
        'side': side,
        'maxDepth': maxDepth,
        'timeBudgetMs': timeBudgetMs,
        'seed': seed,
        'jieqiState': jieqiState,
        'expansion': expansion,
        'topK': topK,
      };

  static SearchJob fromMap(Map<Object?, Object?> map) => SearchJob(
        mode: map['mode'] as String,
        fen: map['fen'] as String,
        side: map['side'] as int,
        maxDepth: map['maxDepth'] as int,
        timeBudgetMs: map['timeBudgetMs'] as int,
        seed: map['seed'] as int,
        jieqiState: map['jieqiState'] as String?,
        expansion: map['expansion'] as int? ?? 0,
        topK: map['topK'] as int? ?? 1,
      );
}

/// 搜索结果：候选着法（坐标码）与评分，按分数降序。
class SearchOutcome {
  const SearchOutcome(this.moves, this.scores, this.depth);

  final List<String> moves;
  final List<int> scores;

  /// 实际完成的搜索深度。
  final int depth;

  bool get isEmpty => moves.isEmpty;

  String get best => moves.isEmpty ? '' : moves.first;

  List<String> toList() => <String>[depth.toString(), moves.join(','), scores.join(',')];

  static SearchOutcome fromList(List<String> data) {
    final depth = int.tryParse(data[0]) ?? 0;
    final moves = data.length > 1 && data[1].isNotEmpty ? data[1].split(',') : <String>[];
    final scores = data.length > 2 && data[2].isNotEmpty
        ? data[2].split(',').map((v) => int.tryParse(v) ?? 0).toList()
        : <int>[];
    return SearchOutcome(moves, scores, depth);
  }
}

const int mateScore = 1000000;

/// 正常象棋搜索：迭代加深 + Alpha-Beta + 吃子静态搜索。
class NormalSearcher {
  NormalSearcher(this.board, this.job)
      : _stopwatch = Stopwatch()..start();

  final CoreBoard board;
  final SearchJob job;
  final Stopwatch _stopwatch;
  int _nodes = 0;
  bool _aborted = false;

  int get nodes => _nodes;

  bool get _timeUp {
    if (_nodes % 256 != 0) return false;
    return _stopwatch.elapsedMilliseconds >= job.timeBudgetMs;
  }

  SearchOutcome run() {
    var depth = 0;
    var last = const SearchOutcome(<String>[], <int>[], 0);
    final root = _ordered(board.legalMoves(board.side));
    if (root.isEmpty) return last;

    for (var d = 1; d <= job.maxDepth; d++) {
      final scored = <ScoredMove>[];
      var alpha = -mateScore * 2;
      for (final mv in root) {
        final captured = board.make(mv);
        final value = -_search(d - 1, -mateScore * 2, -alpha, 1);
        board.unmake(mv, captured);
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
      }
      depth = d;
      if (_aborted || _stopwatch.elapsedMilliseconds >= job.timeBudgetMs) break;
      // 上一轮的最佳着法提到前面，提升剪枝效率
      if (scored.isNotEmpty) {
        root
          ..remove(scored.first.move)
          ..insert(0, scored.first.move);
      }
    }
    return SearchOutcome(last.moves, last.scores, depth);
  }

  int _search(int depth, int alpha, int beta, int ply) {
    _nodes++;
    if (_timeUp) {
      _aborted = true;
      return evaluate(board);
    }
    final moves = board.legalMoves(board.side);
    if (moves.isEmpty) {
      // 被将死或困毙：轮走方负
      return -mateScore + ply;
    }
    if (board.side == kRed && board.kingIndex(kBlack) < 0) {
      return mateScore - ply;
    }
    if (board.side == kBlack && board.kingIndex(kRed) < 0) {
      return mateScore - ply;
    }
    if (depth <= 0) return _quiesce(alpha, beta, 0);

    var best = -mateScore * 2;
    for (final mv in _ordered(moves)) {
      final captured = board.make(mv);
      final value = -_search(depth - 1, -beta, -alpha, ply + 1);
      board.unmake(mv, captured);
      if (_aborted) return best;
      if (value > best) best = value;
      if (value > alpha) alpha = value;
      if (alpha >= beta) break;
    }
    return best;
  }

  /// 静态搜索：只展开吃子，避免地平线效应。
  int _quiesce(int alpha, int beta, int qply) {
    _nodes++;
    if (_timeUp) {
      _aborted = true;
      return evaluate(board);
    }
    final stand = _standPat();
    if (stand >= beta) return stand;
    if (stand > alpha) alpha = stand;
    if (qply >= 4) return stand;

    final captures = board
        .legalMoves(board.side)
        .where((mv) => board.cells[moveTo(mv)] != 0)
        .toList()
      ..sort((a, b) => orderScore(board, b).compareTo(orderScore(board, a)));

    for (final mv in captures) {
      final captured = board.make(mv);
      final value = -_quiesce(-beta, -alpha, qply + 1);
      board.unmake(mv, captured);
      if (_aborted) return alpha;
      if (value >= beta) return value;
      if (value > alpha) alpha = value;
    }
    return alpha;
  }

  int _standPat() {
    final score = evaluate(board);
    return board.side == kRed ? score : -score;
  }

  List<int> _ordered(List<int> moves) {
    final sorted = List<int>.from(moves)
      ..sort((a, b) => orderScore(board, b).compareTo(orderScore(board, a)));
    return sorted;
  }
}

/// 着法及其搜索评分。
class ScoredMove {
  const ScoredMove(this.move, this.score);
  final int move;
  final int score;
}
