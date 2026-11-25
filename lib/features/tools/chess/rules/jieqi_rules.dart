import 'dart:math';

import '../ai/ai_runner.dart';
import '../engine/chess_core.dart';
import 'jieqi_state.dart';
import 'rules_engine.dart';

/// 揭棋规则引擎。
///
/// 与正常象棋共用 [RulesEngine] 接口，UI 无需区分；暗子通过
/// [PieceView.revealed] = false 渲染背面。
class JieqiRules implements RulesEngine, JieqiEngineStateProvider {
  JieqiRules([Random? rng]) : _state = JieqiState.initial(rng);

  /// 从揭棋 FEN 恢复局面（暗子身份重新随机分配）。
  factory JieqiRules.fromFen(String fen, [Random? rng]) => JieqiRules._(
        JieqiState.fromFen(fen, rng) ?? JieqiState.initial(rng),
      );

  JieqiRules._(this._state);

  JieqiState _state;
  final List<MoveRecord> _history = <MoveRecord>[];
  final List<JieqiState> _snapshots = <JieqiState>[];
  String? _lastMove;

  JieqiState get state => _state;

  @override
  int get sideToMove => _state.side;

  @override
  String get fen => _state.fen;

  @override
  String? get lastMove => _lastMove;

  @override
  List<MoveRecord> get history => List<MoveRecord>.unmodifiable(_history);

  @override
  bool get inCheck => _state.inCheck;

  @override
  GameResult get result {
    final over = _state.gameOver();
    return switch (over) {
      0 => GameResult.redWin,
      1 => GameResult.blackWin,
      2 => GameResult.draw,
      _ => GameResult.playing,
    };
  }

  @override
  List<PieceView> get pieces {
    final out = <PieceView>[];
    for (var i = 0; i < 90; i++) {
      final code = _state.board.cells[i];
      if (code == 0) continue;
      out.add(PieceView(
        code: CoreBoard.fenChar(code),
        team: teamOfCode(code),
        pos: codeFromIdx(i),
        revealed: _state.revealed[i] == 1,
      ));
    }
    return out;
  }

  List<String> legalMoves(int team) =>
      _state.board.legalMoves(team).map(moveToCode).toList(growable: false);

  @override
  List<String> legalTargets(String fromCode) {
    final from = idxFromCode(fromCode);
    final code = _state.board.cells[from];
    if (code == 0 || teamOfCode(code) != _state.side) return const <String>[];
    final targets = <String>[];
    for (final mv in _state.legalMoves()) {
      if (moveFrom(mv) == from) targets.add(codeFromIdx(moveTo(mv)));
    }
    return targets;
  }

  @override
  bool applyMove(String move) {
    if (result != GameResult.playing) return false;
    if (move.length != 4) return false;
    final mv = moveFromCode(move);
    if (!_state.legalMoves().contains(mv)) return false;
    return _apply(mv);
  }

  bool applyEncodedMove(int mv) {
    if (result != GameResult.playing) return false;
    return _apply(mv);
  }

  bool _apply(int mv) {
    final from = moveFrom(mv);
    final to = moveTo(mv);
    final willReveal = _state.revealed[from] == 0;
    final captured = _state.board.cells[to];
    final capturedHidden = captured != 0 && _state.revealed[to] == 0;
    // 暗子被吃时，格位上只有「格位棋种」，真实身份要另外取
    final capturedTruth = captured == 0
        ? 0
        : (capturedHidden
            ? codeOf(teamOfCode(captured), _state.truth[to])
            : captured);

    _snapshots.add(_state.copy());
    _state.make(mv);

    _history.add(MoveRecord(
      move: moveToCode(mv),
      piece: CoreBoard.fenChar(_state.board.cells[to]),
      // 记录真实身份，是否向玩家展示由 UI 侧策略决定
      captured: captured == 0 ? null : CoreBoard.fenChar(capturedTruth),
      capturedHidden: capturedHidden,
      flipped: willReveal,
    ));
    _lastMove = moveToCode(mv);
    return true;
  }

  @override
  bool undo() {
    if (_snapshots.isEmpty) return false;
    _state = _snapshots.removeLast();
    _history.removeLast();
    _lastMove = _history.isEmpty ? null : _history.last.move;
    return true;
  }

  @override
  String get stateData => _state.serialize();

  @override
  RulesEngine clone() {
    final copy = JieqiRules._(_state.copy());
    copy._history.addAll(_history);
    copy._snapshots.addAll(_snapshots.map((s) => s.copy()));
    copy._lastMove = _lastMove;
    return copy;
  }
}
