/// 象棋规则引擎抽象层。
///
/// 正常象棋（XiangqiRules）与揭棋（JieqiRules，后续里程碑）都实现该接口，
/// UI / GameController 只面向接口编程，两种玩法可无缝切换。
library;

/// 棋盘上用于渲染的一枚棋子。
class PieceView {
  const PieceView({
    required this.code,
    required this.team,
    required this.pos,
    this.revealed = true,
  });

  /// FEN 单字符棋子码：大写红方（K/A/B/R/N/C/P），小写黑方。
  final String code;

  /// 0 = 红方，1 = 黑方。
  final int team;

  /// 位置码，如 'h2'（列 a-i，行 0-9，红方底线为 0）。
  final String pos;

  /// 是否已翻开（正常象棋恒为 true；揭棋暗子为 false）。
  final bool revealed;

  String get kind => code.toLowerCase();
}

/// 对局结果。
enum GameResult { playing, redWin, blackWin, draw }

/// 一步棋的记录（用于悔棋之外的展示，如对局记录）。
class MoveRecord {
  const MoveRecord({
    required this.move,
    required this.piece,
    this.captured,
    this.capturedHidden = false,
    this.flipped = false,
  });

  /// 坐标着法码，如 'h2e2'。
  final String move;

  /// 走动的棋子码（走动前）。
  final String piece;

  /// 被吃棋子的**真实**棋子码（含被吃的暗子）。
  ///
  /// 真实身份是否可以对玩家展示，由 [capturedHidden] 与对局模式共同决定，
  /// 见 `ChessGameController.capturesBy`。
  final String? captured;

  /// 被吃时该子尚未翻开（仅揭棋可能出现）。
  final bool capturedHidden;

  /// 本步是否触发了暗子翻开（揭棋）。
  final bool flipped;
}

/// 规则引擎接口。
abstract class RulesEngine {
  /// 当前轮走方：0 = 红，1 = 黑。
  int get sideToMove;

  /// 当前局面 FEN（正常模式为标准 FEN；揭棋为含暗子的扩展 FEN）。
  String get fen;

  /// 当前轮走方是否正被将军。
  bool get inCheck;

  /// 对局结果。
  GameResult get result;

  /// 最后一步坐标着法（用于高亮），无则 null。
  String? get lastMove;

  /// 全部已走过的着法记录。
  List<MoveRecord> get history;

  /// 当前盘面上所有可见棋子（含暗子背面）。
  List<PieceView> get pieces;

  /// 指定位置棋子的全部合法落点（位置码列表）。
  List<String> legalTargets(String fromCode);

  /// 执行坐标着法（如 'h2e2'）。非法着返回 false。
  bool applyMove(String move);

  /// 悔一步棋。无可悔返回 false。
  bool undo();

  /// 深拷贝当前状态。
  RulesEngine clone();
}
