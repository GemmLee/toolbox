import '../engine/chess_core.dart';

/// 子力价值（单位：分）。
const List<int> pieceValue = <int>[
  0, // 0 空
  10000, // 1 将
  200, // 2 士
  200, // 3 象
  900, // 4 车
  400, // 5 马
  450, // 6 炮
  100, // 7 兵
];

/// 兵（卒）过河后的位置价值增量：按推进行数（红方 y，黑方 9-y）。
const List<int> pawnAdvance = <int>[0, 0, 0, 0, 20, 40, 70, 110, 160, 220];

/// 局面评估（返回红方视角分值，正数红优）。
int evaluate(CoreBoard board) {
  var score = 0;
  for (var i = 0; i < 90; i++) {
    final code = board.cells[i];
    if (code == 0) continue;
    final team = teamOfCode(code);
    final kind = kindOfCode(code);
    final x = xOf(i);
    final y = yOf(i);
    final advance = team == kRed ? y : 9 - y;

    var value = pieceValue[kind];
    switch (kind) {
      case kPawn:
        value += pawnAdvance[advance];
        if (x == 4) value += 6; // 中兵
        break;
      case kHorse:
        value += advance >= 5 ? 20 : 0;
        if (x == 0 || x == 8) value -= 10; // 边马
        break;
      case kRook:
        value += advance >= 5 ? 25 : 0;
        if (y == (team == kRed ? 9 : 0)) value += 15; // 沉底车
        break;
      case kCannon:
        if (x == 4) value += 25; // 中炮
        if (y == (team == kRed ? 9 : 0)) value += 30; // 沉底炮
        if (_emptyFileCannon(board, i, team)) value += 60; // 空头炮
        break;
      case kElephant:
      case kAdvisor:
        // 士象在己方九宫内更稳
        if (team == kRed ? y <= 2 : y >= 7) value += 8;
        break;
      case kKing:
        break;
      default:
        break;
    }
    score += team == kRed ? value : -value;
  }
  return score;
}

/// 空头炮：中路炮与对方底线之间无子（威胁老将）。
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

/// 走法排序分值：吃子优先（MVV-LVA），其次推进奖励。
int orderScore(CoreBoard board, int mv) {
  final from = moveFrom(mv);
  final to = moveTo(mv);
  final victim = board.cells[to];
  var score = 0;
  if (victim != 0) {
    score += 1000 + pieceValue[kindOfCode(victim)] -
        pieceValue[kindOfCode(board.cells[from])] ~/ 10;
  }
  final advance = teamOfCode(board.cells[from]) == kRed ? yOf(to) : 9 - yOf(to);
  score += advance;
  return score;
}
