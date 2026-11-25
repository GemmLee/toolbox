import '../engine/chess_core.dart';
import 'rules_engine.dart';

/// 正常中国象棋规则引擎（基于 [CoreBoard]）。
///
/// 与早期实现（cchess 包）的差异：走法生成自持，供 AI 搜索复用；
/// 正确性由 `test/chess_differential_test.dart` 与 cchess 做差分校验。
class XiangqiRules implements RulesEngine {
  XiangqiRules([String? placement, int side = kRed])
      : _board = placement == null
            ? CoreBoard.initial()
            : (CoreBoard.fromPlacement(placement, side) ?? CoreBoard.initial());

  XiangqiRules._(this._board);

  CoreBoard _board;
  final List<MoveRecord> _history = <MoveRecord>[];
  final List<CoreBoard> _snapshots = <CoreBoard>[];
  String? _lastMove;

  /// 连续无吃子步数（用于简单和棋判定）。
  int _quietPlies = 0;

  CoreBoard get board => _board;

  @override
  int get sideToMove => _board.side;

  @override
  String get fen => _board.placement();

  @override
  String? get lastMove => _lastMove;

  @override
  List<MoveRecord> get history => List<MoveRecord>.unmodifiable(_history);

  @override
  List<PieceView> get pieces {
    final out = <PieceView>[];
    for (var i = 0; i < 90; i++) {
      final code = _board.cells[i];
      if (code == 0) continue;
      out.add(PieceView(
        code: CoreBoard.fenChar(code),
        team: teamOfCode(code),
        pos: codeFromIdx(i),
      ));
    }
    return out;
  }

  /// 某方全部合法着法（坐标码，如 'h2e2'）。
  List<String> legalMoves(int team) =>
      _board.legalMoves(team).map(moveToCode).toList(growable: false);

  @override
  List<String> legalTargets(String fromCode) {
    final from = idxFromCode(fromCode);
    final code = _board.cells[from];
    if (code == 0 || teamOfCode(code) != _board.side) return const <String>[];
    final targets = <String>[];
    for (final mv in _board.legalMoves(_board.side)) {
      if (moveFrom(mv) == from) targets.add(codeFromIdx(moveTo(mv)));
    }
    return targets;
  }

  @override
  bool applyMove(String move) {
    if (result != GameResult.playing) return false;
    final mv = _parseMove(move);
    if (mv < 0 || !_board.legalMoves(_board.side).contains(mv)) return false;
    return _apply(mv);
  }

  /// 直接执行内部编码走法（AI 使用）。
  bool applyEncodedMove(int mv) {
    if (result != GameResult.playing) return false;
    return _apply(mv);
  }

  bool _apply(int mv) {
    final moved = _board.cells[moveFrom(mv)];
    final captured = _board.cells[moveTo(mv)];
    _snapshots.add(_board.copy());
    _board.make(mv);
    _history.add(MoveRecord(
      move: moveToCode(mv),
      piece: CoreBoard.fenChar(moved),
      captured: captured == 0 ? null : CoreBoard.fenChar(captured),
    ));
    _lastMove = moveToCode(mv);
    _quietPlies = captured == 0 ? _quietPlies + 1 : 0;
    return true;
  }

  int _parseMove(String move) {
    if (move.length != 4) return -1;
    return moveFromCode(move);
  }

  @override
  bool undo() {
    if (_snapshots.isEmpty) return false;
    _board = _snapshots.removeLast();
    _history.removeLast();
    _lastMove = _history.isEmpty ? null : _history.last.move;
    _quietPlies = 0;
    return true;
  }

  @override
  bool get inCheck => _board.inCheck(_board.side);

  @override
  GameResult get result {
    if (_board.kingIndex(kRed) < 0) return GameResult.blackWin;
    if (_board.kingIndex(kBlack) < 0) return GameResult.redWin;
    if (_board.legalMoves(_board.side).isEmpty) {
      return _board.side == kRed ? GameResult.blackWin : GameResult.redWin;
    }
    if (_quietPlies >= 80) return GameResult.draw;
    return GameResult.playing;
  }

  @override
  RulesEngine clone() {
    final copy = XiangqiRules._(_board.copy());
    copy._history.addAll(_history);
    copy._snapshots.addAll(_snapshots.map((b) => b.copy()));
    copy._lastMove = _lastMove;
    copy._quietPlies = _quietPlies;
    return copy;
  }
}
