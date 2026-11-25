import 'dart:math';

import '../engine/chess_core.dart';

/// 揭棋局面状态（公开信息 + 内部真相）。
///
/// 规则要点（据通行揭棋规则）：
/// - 将/帅开局即明置；其余 15 子暗置，按象棋原始位置随机摆放；
/// - 暗子按所在格位对应棋种的走法走子、吃子，走动后必须翻开为明子；
/// - 明士、明象不受九宫/河界限制（可过河）；
/// - 暗子被吃时身份不公开（对双方都不可见），只按期望从暗子池中扣减。
class JieqiState {
  JieqiState._(this.board, this.revealed, this.truth, this.pool, this.quietPlies);

  final CoreBoard board;

  /// 每格是否已翻开（1 = 明子）。
  final List<int> revealed;

  /// 每格真实棋种（暗子也记录，仅引擎内部使用，UI 与 AI 不得直接读取）。
  final List<int> truth;

  /// 双方未公开身份的剩余暗子池期望数量，pool[team][kind]。
  final List<List<double>> pool;

  /// 连续无吃子步数。
  int quietPlies;

  /// 15 个非将棋子在各队初始位置的格位（列, 行）。
  static const List<List<int>> redHome = <List<int>>[
    <int>[0, 0], <int>[8, 0], // 车
    <int>[1, 0], <int>[7, 0], // 马
    <int>[2, 0], <int>[6, 0], // 相
    <int>[3, 0], <int>[5, 0], // 仕
    <int>[1, 2], <int>[7, 2], // 炮
    <int>[0, 3], <int>[2, 3], <int>[4, 3], <int>[6, 3], <int>[8, 3], // 兵
  ];

  static const List<int> kinds15 = <int>[
    kRook, kRook, kHorse, kHorse, kElephant, kElephant, kAdvisor, kAdvisor,
    kCannon, kCannon, kPawn, kPawn, kPawn, kPawn, kPawn,
  ];

  /// 某格位对应的棋种（用于暗子走法）；非初始位置返回 0。
  static int homeKindAt(int x, int y, int team) {
    final ry = team == kRed ? y : 9 - y;
    for (var i = 0; i < redHome.length; i++) {
      if (redHome[i][0] == x && redHome[i][1] == ry) return kinds15[i];
    }
    return 0;
  }

  /// 新开局：将帅明置，其余 15 子随机暗置。
  factory JieqiState.initial([Random? rng]) {
    final random = rng ?? Random();
    final board = CoreBoard(List<int>.filled(90, 0), kRed, List<int>.filled(90, 0));
    final revealed = List<int>.filled(90, 0);
    final truth = List<int>.filled(90, 0);

    for (final team in <int>[kRed, kBlack]) {
      final identities = List<int>.from(kinds15)..shuffle(random);
      for (var i = 0; i < redHome.length; i++) {
        final x = redHome[i][0];
        final y = team == kRed ? redHome[i][1] : 9 - redHome[i][1];
        final idx = idxOf(x, y);
        board.cells[idx] = codeOf(team, kinds15[i]); // 有效走法 = 格位棋种
        truth[idx] = identities[i]; // 真实身份
        revealed[idx] = 0;
      }
      const kx = 4;
      final ky = team == kRed ? 0 : 9;
      final kIdx = idxOf(kx, ky);
      board.cells[kIdx] = codeOf(team, kKing);
      truth[kIdx] = kKing;
      revealed[kIdx] = 1;
    }

    return JieqiState._(
      board,
      revealed,
      truth,
      <List<double>>[
        _initialPool(),
        _initialPool(),
      ],
      0,
    );
  }

  static List<double> _initialPool() {
    final pool = List<double>.filled(8, 0);
    for (final k in kinds15) {
      pool[k] = pool[k] + 1;
    }
    return pool;
  }

  JieqiState copy() => JieqiState._(
        board.copy(),
        List<int>.from(revealed),
        List<int>.from(truth),
        <List<double>>[List<double>.from(pool[0]), List<double>.from(pool[1])],
        quietPlies,
      );

  int get side => board.side;

  List<int> legalMoves() => board.legalMoves(board.side);

  bool get inCheck => board.inCheck(board.side);

  /// 某队暗子池总数。
  double poolTotal(int team) =>
      pool[team].fold<double>(0, (sum, v) => sum + v);

  /// 暗子为某棋种的概率。
  double probability(int team, int kind) {
    final total = poolTotal(team);
    if (total <= 0) return 0;
    return pool[team][kind] / total;
  }

  /// 执行一次走法，返回撤销所需信息。
  JieqiUndo make(int mv) {
    final from = moveFrom(mv);
    final to = moveTo(mv);
    final moverTeam = teamOfCode(board.cells[from]);
    final moverCode = board.cells[from];
    final moverFree = board.freeAE[from];
    final moverTruth = truth[from];
    final moverWasRevealed = revealed[from] == 1;
    final captured = board.cells[to];
    final capturedTeam = captured == 0 ? -1 : teamOfCode(captured);
    final capturedRevealed = captured != 0 && revealed[to] == 1;
    final capturedTruth = captured == 0 ? 0 : truth[to];
    final prevQuiet = quietPlies;

    board.make(mv);

    // 被吃子：暗子身份不公开，按期望从池中扣减
    if (captured != 0) {
      if (capturedRevealed) {
        pool[capturedTeam][kindOfCode(captured)] -= 1;
      } else {
        final total = poolTotal(capturedTeam);
        if (total > 1) {
          final scale = (total - 1) / total;
          for (var k = 1; k < 8; k++) {
            pool[capturedTeam][k] = pool[capturedTeam][k] * scale;
          }
        }
      }
      quietPlies = 0;
    } else {
      quietPlies++;
    }

    // 落点：先清掉被吃子的痕迹，再写入走动方
    revealed[from] = 0;
    truth[from] = 0;
    board.cells[from] = 0;
    board.freeAE[from] = 0;
    truth[to] = moverTruth;

    var revealedKind = 0;
    if (!moverWasRevealed) {
      // 暗子走完必须翻开：此后按真实棋种走子
      revealedKind = moverTruth;
      board.cells[to] = codeOf(moverTeam, moverTruth);
      board.freeAE[to] =
          (moverTruth == kAdvisor || moverTruth == kElephant) ? 1 : 0;
      pool[moverTeam][moverTruth] =
          (pool[moverTeam][moverTruth] - 1).clamp(0, 15);
      quietPlies = 0;
    }
    revealed[to] = 1;

    return JieqiUndo(
      mv: mv,
      captured: captured,
      capturedTeam: capturedTeam,
      capturedRevealed: capturedRevealed,
      capturedTruth: capturedTruth,
      moverCode: moverCode,
      moverFree: moverFree,
      moverTruth: moverTruth,
      moverWasRevealed: moverWasRevealed,
      revealedKind: revealedKind,
      prevQuiet: prevQuiet,
    );
  }

  void unmake(JieqiUndo undo) {
    final from = moveFrom(undo.mv);
    final to = moveTo(undo.mv);

    board.side = 1 - board.side;

    if (undo.revealedKind != 0) {
      final team = teamOfCode(undo.moverCode);
      pool[team][undo.revealedKind] += 1;
    }

    // 还原起点
    board.cells[from] = undo.moverCode;
    board.freeAE[from] = undo.moverFree;
    truth[from] = undo.moverTruth;
    revealed[from] = undo.moverWasRevealed ? 1 : 0;

    // 还原落点
    if (undo.captured != 0) {
      board.cells[to] = undo.captured;
      final kind = kindOfCode(undo.captured);
      board.freeAE[to] =
          (undo.capturedRevealed && (kind == kAdvisor || kind == kElephant))
              ? 1
              : 0;
      truth[to] = undo.capturedTruth;
      revealed[to] = undo.capturedRevealed ? 1 : 0;
      if (undo.capturedRevealed) {
        pool[undo.capturedTeam][kind] += 1;
      } else {
        // 逆操作：make 时乘了 (T-1)/T，此处总数为 T-1，故乘 T/(T-1) = (total+1)/total
        final total = poolTotal(undo.capturedTeam);
        if (total > 0) {
          final scale = (total + 1) / total;
          for (var k = 1; k < 8; k++) {
            pool[undo.capturedTeam][k] = pool[undo.capturedTeam][k] * scale;
          }
        }
      }
    } else {
      board.cells[to] = 0;
      board.freeAE[to] = 0;
      truth[to] = 0;
      revealed[to] = 0;
    }

    quietPlies = undo.prevQuiet;
  }

  /// 终局：返回 -1 未结束，0 红胜，1 黑胜，2 和棋。
  int gameOver() {
    if (board.kingIndex(kRed) < 0) return 1;
    if (board.kingIndex(kBlack) < 0) return 0;
    if (legalMoves().isEmpty) return board.side == kRed ? 1 : 0;
    if (quietPlies >= 80) return 2;
    return -1;
  }

  /// 揭棋 FEN：明子用标准字符，暗子用 x/X，后接轮走方。
  String get fen {
    final rows = <String>[];
    for (var y = 9; y >= 0; y--) {
      final buf = StringBuffer();
      var empty = 0;
      for (var x = 0; x < 9; x++) {
        final idx = idxOf(x, y);
        final code = board.cells[idx];
        if (code == 0) {
          empty++;
        } else {
          if (empty > 0) {
            buf.write(empty);
            empty = 0;
          }
          buf.write(revealed[idx] == 1
              ? CoreBoard.fenChar(code)
              : (teamOfCode(code) == kRed ? 'X' : 'x'));
        }
      }
      if (empty > 0) buf.write(empty);
      rows.add(buf.toString());
    }
    return '${rows.join('/')} ${board.side == kRed ? 'w' : 'b'}';
  }

  /// 从揭棋 FEN 恢复：明子身份确定，暗子从剩余池中随机补齐。
  static JieqiState? fromFen(String fen, [Random? rng]) {
    final parts = fen.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return null;
    final placement = parts[0];
    final side = (parts.length > 1 && parts[1] == 'b') ? kBlack : kRed;
    final rows = placement.split('/');
    if (rows.length != 10) return null;

    final random = rng ?? Random();
    final board = CoreBoard(List<int>.filled(90, 0), side, List<int>.filled(90, 0));
    final revealed = List<int>.filled(90, 0);
    final truth = List<int>.filled(90, 0);
    final pool = <List<double>>[_initialPool(), _initialPool()];
    final darkIdx = <int>[];

    for (var r = 0; r < 10; r++) {
      final y = 9 - r;
      var x = 0;
      for (var i = 0; i < rows[r].length; i++) {
        final ch = rows[r][i];
        final digit = int.tryParse(ch);
        if (digit != null) {
          x += digit;
          continue;
        }
        if (x > 8) return null;
        final idx = idxOf(x, y);
        if (ch == 'x' || ch == 'X') {
          final team = ch == 'X' ? kRed : kBlack;
          final kind = homeKindAt(x, y, team);
          if (kind == 0) return null;
          board.cells[idx] = codeOf(team, kind);
          revealed[idx] = 0;
          darkIdx.add(idx);
        } else {
          final code = CoreBoard.fenCharToCode(ch);
          if (code == null) return null;
          board.cells[idx] = code;
          revealed[idx] = 1;
          truth[idx] = kindOfCode(code);
          if (kindOfCode(code) != kKing) {
            pool[teamOfCode(code)][kindOfCode(code)] =
                (pool[teamOfCode(code)][kindOfCode(code)] - 1).clamp(0, 15);
            if (teamOfCode(code) == kRed &&
                (kindOfCode(code) == kAdvisor || kindOfCode(code) == kElephant)) {
              board.freeAE[idx] = 1;
            }
            if (teamOfCode(code) == kBlack &&
                (kindOfCode(code) == kAdvisor || kindOfCode(code) == kElephant)) {
              board.freeAE[idx] = 1;
            }
          }
        }
        x++;
      }
      if (x != 9) return null;
    }

    // 暗子身份：从剩余池中按期望随机分配
    for (final team in <int>[kRed, kBlack]) {
      final identities = <int>[];
      for (var k = 1; k < 8; k++) {
        final n = pool[team][k].round();
        for (var j = 0; j < n; j++) {
          identities.add(k);
        }
      }
      final teamDark = darkIdx
          .where((i) => teamOfCode(board.cells[i]) == team)
          .toList()
        ..shuffle(random);
      if (teamDark.length > identities.length) {
        // FEN 不完整：多出的暗子按兵处理
        while (identities.length < teamDark.length) {
          identities.add(kPawn);
        }
      }
      for (var i = 0; i < teamDark.length; i++) {
        truth[teamDark[i]] = identities[i];
      }
    }

    return JieqiState._(board, revealed, truth, pool, 0);
  }

  /// 序列化（供 Isolate 传递）：FEN + 真相串。
  String serialize() {
    final truthStr = truth.map((k) => k.toString()).join();
    return '$fen|$truthStr|${pool[0].join(',')}|${pool[1].join(',')}|$quietPlies';
  }

  static JieqiState? deserialize(String data) {
    final parts = data.split('|');
    if (parts.length < 4) return null;
    final state = fromFen(parts[0]);
    if (state == null) return null;
    final truthStr = parts[1];
    if (truthStr.length == 90) {
      for (var i = 0; i < 90; i++) {
        state.truth[i] = int.tryParse(truthStr[i]) ?? 0;
      }
    }
    for (final t in <int>[0, 1]) {
      final idx = 2 + t;
      if (parts.length > idx && parts[idx].isNotEmpty) {
        final values = parts[idx].split(',').map((v) => double.tryParse(v) ?? 0).toList();
        if (values.length == 8) state.pool[t] = values;
      }
    }
    if (parts.length > 4) state.quietPlies = int.tryParse(parts[4]) ?? 0;
    return state;
  }
}

/// 揭棋走法的撤销信息。
class JieqiUndo {
  const JieqiUndo({
    required this.mv,
    required this.captured,
    required this.capturedTeam,
    required this.capturedRevealed,
    required this.capturedTruth,
    required this.moverCode,
    required this.moverFree,
    required this.moverTruth,
    required this.moverWasRevealed,
    required this.revealedKind,
    required this.prevQuiet,
  });

  final int mv;
  final int captured;
  final int capturedTeam;
  final bool capturedRevealed;
  final int capturedTruth;
  final int moverCode;
  final int moverFree;
  final int moverTruth;
  final bool moverWasRevealed;
  final int revealedKind;
  final int prevQuiet;
}
