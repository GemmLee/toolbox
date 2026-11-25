/// 象棋高速棋盘内核：规则层与 AI 搜索共用的底层实现。
///
/// 设计要点：
/// - 90 格一维数组 `cells`，索引 `idx = y * 9 + x`（y=0 为红方底线）；
/// - 棋子编码 `code = team * 8 + kind`，空 = 0；`team = code >> 3`、`kind = code & 7`；
/// - `freeAE[idx] = 1` 表示该子的士/象走法不受九宫与河界限制（揭棋明子规则）；
/// - 走法编码 `from | to << 8`。
library;

/// 棋子种类（1-7）。
const int kKing = 1;
const int kAdvisor = 2;
const int kElephant = 3;
const int kRook = 4;
const int kHorse = 5;
const int kCannon = 6;
const int kPawn = 7;

/// 红方 = 0，黑方 = 1。
const int kRed = 0;
const int kBlack = 1;

int codeOf(int team, int kind) => team * 8 + kind;
int teamOfCode(int code) => code >> 3;
int kindOfCode(int code) => code & 7;

int idxOf(int x, int y) => y * 9 + x;
int xOf(int idx) => idx % 9;
int yOf(int idx) => idx ~/ 9;

int encodeMove(int from, int to) => from | (to << 8);
int moveFrom(int move) => move & 0xFF;
int moveTo(int move) => (move >> 8) & 0xFF;

/// 位置码（'h2'）与索引互换：列 a-i（0-8），行 0-9（红方底线为 0）。
int idxFromCode(String code) =>
    idxOf(code.codeUnitAt(0) - 0x61, int.parse(code[1]));

String codeFromIdx(int idx) =>
    '${String.fromCharCode(0x61 + xOf(idx))}${yOf(idx)}';

String moveToCode(int move) =>
    '${codeFromIdx(moveFrom(move))}${codeFromIdx(moveTo(move))}';

int moveFromCode(String code) =>
    encodeMove(idxFromCode(code.substring(0, 2)), idxFromCode(code.substring(2, 4)));

/// 从棋子摆放字段构造棋盘（供 AI 搜索使用）。
CoreBoard? chessBoardFromFen(String placement, [int side = kRed]) =>
    CoreBoard.fromPlacement(placement, side);

/// 棋盘（可变状态）。
class CoreBoard {
  CoreBoard(this.cells, this.side, [List<int>? freeAE])
      : freeAE = freeAE ?? List<int>.filled(90, 0);

  /// 90 个格子，值为 `codeOf(team, kind)`，0 表示空。
  final List<int> cells;

  /// 每格是否解除士/象的九宫与河界限制（揭棋明士、明象）。
  final List<int> freeAE;

  /// 轮走方。
  int side;

  static const String initialFen =
      'rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR';

  CoreBoard.initial() : this(_fromFenCells(initialFen)!, kRed, List<int>.filled(90, 0));

  CoreBoard copy() =>
      CoreBoard(List<int>.from(cells), side, List<int>.from(freeAE));

  int at(int x, int y) => cells[idxOf(x, y)];

  /// 某方老将索引，-1 表示不存在。
  int kingIndex(int team) {
    final target = codeOf(team, kKing);
    for (var i = 0; i < 90; i++) {
      if (cells[i] == target) return i;
    }
    return -1;
  }

  /// 双方老将是否照面（同列且中间无子）。
  bool kingsFacing() {
    final rk = kingIndex(kRed);
    final bk = kingIndex(kBlack);
    if (rk < 0 || bk < 0) return false;
    if (xOf(rk) != xOf(bk)) return false;
    final from = rk < bk ? rk : bk;
    final to = rk < bk ? bk : rk;
    for (var i = from + 9; i < to; i += 9) {
      if (cells[i] != 0) return false;
    }
    return true;
  }

  /// 生成某方全部伪合法走法（不校验走后是否被将军）。
  List<int> pseudoMoves(int team) {
    final out = <int>[];
    for (var i = 0; i < 90; i++) {
      final code = cells[i];
      if (code == 0 || teamOfCode(code) != team) continue;
      genFrom(i, code, out);
    }
    return out;
  }

  /// 从 [from] 出发生成走法，写入 [out]。
  void genFrom(int from, int code, List<int> out) {
    final kind = kindOfCode(code);
    final team = teamOfCode(code);
    final free = freeAE[from] == 1;
    final x = xOf(from);
    final y = yOf(from);

    switch (kind) {
      case kRook:
        _slide(from, x, y, out, team);
        break;
      case kCannon:
        _cannon(from, x, y, out, team);
        break;
      case kHorse:
        _horse(from, x, y, out, team);
        break;
      case kElephant:
        _elephant(from, x, y, out, team, free);
        break;
      case kAdvisor:
        _advisor(from, x, y, out, team, free);
        break;
      case kKing:
        _king(from, x, y, out, team);
        break;
      case kPawn:
        _pawn(from, x, y, out, team);
        break;
      default:
        break;
    }
  }

  void _tryMove(int from, int to, int team, List<int> out) {
    final target = cells[to];
    if (target != 0 && teamOfCode(target) == team) return;
    out.add(encodeMove(from, to));
  }

  void _slide(int from, int x, int y, List<int> out, int team) {
    const dirs = <int>[1, 0, 0, 1, -1, 0, 0, -1];
    for (var i = 0; i < 8; i += 2) {
      final dx = dirs[i];
      final dy = dirs[i + 1];
      var cx = x + dx;
      var cy = y + dy;
      while (cx >= 0 && cx < 9 && cy >= 0 && cy < 10) {
        final to = idxOf(cx, cy);
        final target = cells[to];
        if (target == 0) {
          out.add(encodeMove(from, to));
        } else {
          if (teamOfCode(target) != team) out.add(encodeMove(from, to));
          break;
        }
        cx += dx;
        cy += dy;
      }
    }
  }

  void _cannon(int from, int x, int y, List<int> out, int team) {
    const dirs = <int>[0, 1, 2, 3];
    for (final d in dirs) {
      final dx = d == 0 ? 1 : (d == 2 ? -1 : 0);
      final dy = d == 1 ? 1 : (d == 3 ? -1 : 0);
      var cx = x + dx;
      var cy = y + dy;
      var screen = false;
      while (cx >= 0 && cx < 9 && cy >= 0 && cy < 10) {
        final to = idxOf(cx, cy);
        final target = cells[to];
        if (!screen) {
          if (target == 0) {
            out.add(encodeMove(from, to));
          } else {
            screen = true;
          }
        } else if (target != 0) {
          if (teamOfCode(target) != team) out.add(encodeMove(from, to));
          break;
        }
        cx += dx;
        cy += dy;
      }
    }
  }

  void _horse(int from, int x, int y, List<int> out, int team) {
    const steps = <int>[
      1, 2, -1, 2, 1, -2, -1, -2, //
      2, 1, 2, -1, -2, 1, -2, -1,
    ];
    for (var i = 0; i < 16; i += 2) {
      final dx = steps[i];
      final dy = steps[i + 1];
      final cx = x + dx;
      final cy = y + dy;
      if (cx < 0 || cx > 8 || cy < 0 || cy > 9) continue;
      final legX = x + (dx.abs() == 2 ? dx ~/ 2 : 0);
      final legY = y + (dy.abs() == 2 ? dy ~/ 2 : 0);
      if (cells[idxOf(legX, legY)] != 0) continue;
      _tryMove(from, idxOf(cx, cy), team, out);
    }
  }

  void _elephant(
      int from, int x, int y, List<int> out, int team, bool free) {
    const steps = <int>[2, 2, -2, 2, 2, -2, -2, -2];
    for (var i = 0; i < 8; i += 2) {
      final cx = x + steps[i];
      final cy = y + steps[i + 1];
      if (cx < 0 || cx > 8 || cy < 0 || cy > 9) continue;
      if (!free) {
        // 象不过河
        if (team == kRed && cy > 4) continue;
        if (team == kBlack && cy < 5) continue;
      }
      final eyeX = x + steps[i] ~/ 2;
      final eyeY = y + steps[i + 1] ~/ 2;
      if (cells[idxOf(eyeX, eyeY)] != 0) continue;
      _tryMove(from, idxOf(cx, cy), team, out);
    }
  }

  void _advisor(
      int from, int x, int y, List<int> out, int team, bool free) {
    const steps = <int>[1, 1, -1, 1, 1, -1, -1, -1];
    for (var i = 0; i < 8; i += 2) {
      final cx = x + steps[i];
      final cy = y + steps[i + 1];
      if (cx < 0 || cx > 8 || cy < 0 || cy > 9) continue;
      if (!free && !_inPalace(cx, cy, team)) continue;
      _tryMove(from, idxOf(cx, cy), team, out);
    }
  }

  void _king(int from, int x, int y, List<int> out, int team) {
    const steps = <int>[1, 0, -1, 0, 0, 1, 0, -1];
    for (var i = 0; i < 8; i += 2) {
      final cx = x + steps[i];
      final cy = y + steps[i + 1];
      if (cx < 0 || cx > 8 || cy < 0 || cy > 9) continue;
      if (!_inPalace(cx, cy, team)) continue;
      _tryMove(from, idxOf(cx, cy), team, out);
    }
  }

  void _pawn(int from, int x, int y, List<int> out, int team) {
    final forward = team == kRed ? 1 : -1;
    final ny = y + forward;
    if (ny >= 0 && ny < 10) {
      _tryMove(from, idxOf(x, ny), team, out);
    }
    final crossed = team == kRed ? y >= 5 : y <= 4;
    if (crossed) {
      for (final dx in <int>[-1, 1]) {
        final nx = x + dx;
        if (nx < 0 || nx > 8) continue;
        _tryMove(from, idxOf(nx, y), team, out);
      }
    }
  }

  static bool _inPalace(int x, int y, int team) {
    if (x < 3 || x > 5) return false;
    return team == kRed ? y <= 2 : y >= 7;
  }

  /// [to] 是否被 [byTeam] 攻击（不考虑老将照面）。
  bool attackedBy(int to, int byTeam) {
    final tx = xOf(to);
    final ty = yOf(to);
    for (var i = 0; i < 90; i++) {
      final code = cells[i];
      if (code == 0 || teamOfCode(code) != byTeam) continue;
      if (_attacksFrom(i, code, tx, ty)) return true;
    }
    return false;
  }

  bool _attacksFrom(int from, int code, int tx, int ty) {
    final kind = kindOfCode(code);
    final team = teamOfCode(code);
    final free = freeAE[from] == 1;
    final x = xOf(from);
    final y = yOf(from);
    final dx = tx - x;
    final dy = ty - y;
    final adx = dx.abs();
    final ady = dy.abs();

    switch (kind) {
      case kRook:
        if (dx != 0 && dy != 0) return false;
        return _clearLine(x, y, tx, ty);
      case kCannon:
        if (dx != 0 && dy != 0) return false;
        return _cannonAttack(x, y, tx, ty);
      case kHorse:
        if (!((adx == 1 && ady == 2) || (adx == 2 && ady == 1))) return false;
        final legX = x + (adx == 2 ? dx ~/ 2 : 0);
        final legY = y + (ady == 2 ? dy ~/ 2 : 0);
        return cells[idxOf(legX, legY)] == 0;
      case kElephant:
        if (adx != 2 || ady != 2) return false;
        if (!free) {
          if (team == kRed && ty > 4) return false;
          if (team == kBlack && ty < 5) return false;
        }
        return cells[idxOf(x + dx ~/ 2, y + dy ~/ 2)] == 0;
      case kAdvisor:
        if (adx != 1 || ady != 1) return false;
        if (!free && !_inPalace(tx, ty, team)) return false;
        return true;
      case kKing:
        if (adx + ady != 1) return false;
        return _inPalace(tx, ty, team);
      case kPawn:
        final forward = team == kRed ? 1 : -1;
        if (dx == 0 && dy == forward) return true;
        final crossed = team == kRed ? y >= 5 : y <= 4;
        return crossed && dy == 0 && adx == 1;
      default:
        return false;
    }
  }

  bool _clearLine(int x, int y, int tx, int ty) {
    final dx = tx.compareTo(x);
    final dy = ty.compareTo(y);
    var cx = x + dx;
    var cy = y + dy;
    while (cx != tx || cy != ty) {
      if (cells[idxOf(cx, cy)] != 0) return false;
      cx += dx;
      cy += dy;
    }
    return true;
  }

  /// 炮攻击：中间恰好一个棋子（炮架）。
  bool _cannonAttack(int x, int y, int tx, int ty) {
    final dx = tx.compareTo(x);
    final dy = ty.compareTo(y);
    var cx = x + dx;
    var cy = y + dy;
    var screens = 0;
    while (cx != tx || cy != ty) {
      if (cells[idxOf(cx, cy)] != 0) {
        screens++;
        if (screens > 1) return false;
      }
      cx += dx;
      cy += dy;
    }
    return screens == 1;
  }

  /// [team] 是否正被将军（含老将照面的非法情形）。
  bool inCheck(int team) {
    final kIdx = kingIndex(team);
    if (kIdx < 0) return true;
    if (attackedBy(kIdx, 1 - team)) return true;
    return kingsFacing();
  }

  /// 生成 [team] 全部合法走法（过滤走后被将军 / 照面）。
  List<int> legalMoves([int? team]) {
    final t = team ?? side;
    final pseudo = pseudoMoves(t);
    final out = <int>[];
    for (final mv in pseudo) {
      // 被吃子可能带士/象自由标志（揭棋明士/明象），
      // 必须先记录，否则试走 unmake 会把标志抹掉。
      final capFree = freeAE[moveTo(mv)] == 1;
      final captured = make(mv);
      if (!inCheck(t)) out.add(mv);
      unmake(mv, captured, capturedFree: capFree);
    }
    return out;
  }

  /// 执行走法，返回被吃棋子编码（0 表示未吃子）。
  int make(int mv) {
    final from = moveFrom(mv);
    final to = moveTo(mv);
    final captured = cells[to];
    cells[to] = cells[from];
    cells[from] = 0;
    final free = freeAE[from];
    freeAE[from] = 0;
    freeAE[to] = free;
    side = 1 - side;
    return captured;
  }

  /// 撤销走法。
  ///
  /// [capturedFree]：被吃子是否带士/象自由标志（揭棋明士/明象）。
  /// 试走回退时必须还原被吃子的标志，否则该子会被永久锁回九宫/河界。
  void unmake(int mv, int captured, {bool capturedFree = false}) {
    final from = moveFrom(mv);
    final to = moveTo(mv);
    final free = freeAE[to];
    cells[from] = cells[to];
    cells[to] = captured;
    freeAE[to] = capturedFree ? 1 : 0;
    freeAE[from] = free;
    side = 1 - side;
  }

  /// 局面字符串（棋子摆放字段，行 9 → 行 0）。
  String placement() {
    final rows = <String>[];
    for (var y = 9; y >= 0; y--) {
      final buf = StringBuffer();
      var empty = 0;
      for (var x = 0; x < 9; x++) {
        final code = cells[idxOf(x, y)];
        if (code == 0) {
          empty++;
        } else {
          if (empty > 0) {
            buf.write(empty);
            empty = 0;
          }
          buf.write(fenChar(code));
        }
      }
      if (empty > 0) buf.write(empty);
      rows.add(buf.toString());
    }
    return rows.join('/');
  }

  static String fenChar(int code) {
    const red = <int, String>{
      kKing: 'K', kAdvisor: 'A', kElephant: 'B',
      kRook: 'R', kHorse: 'N', kCannon: 'C', kPawn: 'P',
    };
    final ch = red[kindOfCode(code)]!;
    return teamOfCode(code) == kRed ? ch : ch.toLowerCase();
  }

  /// FEN 字符 → 棋子编码，非法字符返回 null。
  static int? fenCharToCode(String ch) => _codeFromFenChar(ch);

  static int? _codeFromFenChar(String ch) {
    const map = <String, int>{
      'K': kKing, 'A': kAdvisor, 'B': kElephant,
      'R': kRook, 'N': kHorse, 'C': kCannon, 'P': kPawn,
    };
    final kind = map[ch.toUpperCase()];
    if (kind == null) return null;
    return codeOf(ch == ch.toUpperCase() ? kRed : kBlack, kind);
  }

  /// 从棋子摆放字段解析 90 格数组，失败返回 null。
  static List<int>? _fromFenCells(String placement) {
    final cells = List<int>.filled(90, 0);
    final rows = placement.split('/');
    if (rows.length != 10) return null;
    for (var r = 0; r < 10; r++) {
      final y = 9 - r;
      var x = 0;
      var i = 0;
      while (i < rows[r].length) {
        final ch = rows[r][i];
        final digit = int.tryParse(ch);
        if (digit != null) {
          x += digit;
        } else {
          final code = _codeFromFenChar(ch);
          if (code == null || x > 8) return null;
          cells[idxOf(x, y)] = code;
          x++;
        }
        i++;
      }
      if (x != 9) return null;
    }
    return cells;
  }

  /// 从 FEN 的摆放字段构造棋盘（不含轮走方信息）。
  static CoreBoard? fromPlacement(String placement, [int side = kRed]) {
    final cells = _fromFenCells(placement);
    if (cells == null) return null;
    return CoreBoard(cells, side, List<int>.filled(90, 0));
  }
}
