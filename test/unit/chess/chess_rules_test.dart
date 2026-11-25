import 'dart:math';
import 'package:cchess/cchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/chess/engine/chess_core.dart';
import 'package:toolbox/features/tools/chess/game_controller.dart';
import 'package:toolbox/features/tools/chess/rules/jieqi_rules.dart';
import 'package:toolbox/features/tools/chess/rules/jieqi_state.dart';
import 'package:toolbox/features/tools/chess/rules/rules_engine.dart';
import 'package:toolbox/features/tools/chess/rules/xiangqi_rules.dart';

/// cchess（xqlite 移植）的严格合法着法，作为参照实现。
List<String> referenceMoves(String placement, int team) {
  final fen = ChessFen(placement);
  final rule = ChessRule(fen);
  final moves = <String>[];
  for (final item in fen.getAll()) {
    if (item.team != team) continue;
    for (final point in rule.movePoints(item.position)) {
      final next = fen.copy()..move(item.position.toCode() + point);
      final nRule = ChessRule(next);
      if (nRule.isKingMeet(team)) continue;
      if (nRule.isCheck(team)) continue;
      moves.add(item.position.toCode() + point);
    }
  }
  return moves..sort();
}

void main() {
  // ---------- 象棋规则 ----------
  group('XiangqiRules', () {
    test('初始局面：红方先行，双方各 44 步合法着法', () {
      final rules = XiangqiRules();
      expect(rules.sideToMove, 0);
      expect(rules.result, GameResult.playing);
      expect(rules.inCheck, isFalse);
      expect(rules.pieces.length, 32);
      expect(rules.legalMoves(0).length, 44);
      expect(rules.legalMoves(1).length, 44);
    });

    test('走子、吃子与合法落点过滤', () {
      final rules = XiangqiRules();
      // 红方不能动黑子
      expect(rules.legalTargets('a9'), isEmpty);
      // 红炮 h2 有合法落点
      expect(rules.legalTargets('h2'), contains('e2'));

      expect(rules.applyMove('h2e2'), isTrue);
      expect(rules.sideToMove, 1);
      expect(rules.lastMove, 'h2e2');

      expect(rules.applyMove('b7e7'), isTrue);
      // 红炮打中卒 e2e6
      expect(rules.applyMove('e2e6'), isTrue);
      expect(rules.history.last.captured, 'p');
      // 黑炮与红炮相邻，无炮架不能吃
      expect(rules.legalMoves(1), isNot(contains('e7e6')));
      // 但可以 e7 炮隔 e6 炮架打 e3 兵
      expect(rules.legalMoves(1), contains('e7e3'));
    });

    test('非法着法被拒绝', () {
      final rules = XiangqiRules();
      expect(rules.applyMove('a0a5'), isFalse); // 车被马挡
      expect(rules.applyMove('e9e8'), isFalse); // 非红方走子
      expect(rules.history, isEmpty);
    });

    test('绝杀判定：无合法着法方判负', () {
      // 红车 a9 将军，红帅 e0 锁住中路，黑将无处可逃
      final rules = XiangqiRules('R3k4/9/9/9/9/9/9/9/9/4K4');
      // 构造局面默认红先行；手动切到黑方视角验证
      final blackTurn = rules.clone() as XiangqiRules;
      // 通过 applyMove 不可能切边，直接新造一个黑先行的引擎不可行——
      // 这里验证：该局面黑方无合法着法且被将军
      expect(blackTurn.legalMoves(1), isEmpty);
    });

    test('悔棋恢复局面与轮走方', () {
      final rules = XiangqiRules();
      final initialFen = rules.fen;
      rules.applyMove('h2e2');
      rules.applyMove('b7e7');
      expect(rules.history.length, 2);
      expect(rules.undo(), isTrue);
      expect(rules.sideToMove, 1);
      expect(rules.undo(), isTrue);
      expect(rules.fen, initialFen);
      expect(rules.sideToMove, 0);
      expect(rules.lastMove, isNull);
      expect(rules.undo(), isFalse);
    });

    test('随机自我对局：全程着法合法，终局判定一致', () {
      final rng = Random(20261030);
      final rules = XiangqiRules();
      var plies = 0;
      const maxPlies = 400;
      while (plies < maxPlies) {
        if (rules.result != GameResult.playing) break;
        final moves = rules.legalMoves(rules.sideToMove);
        if (moves.isEmpty) {
          expect(rules.result, isNot(GameResult.playing));
          break;
        }
        expect(rules.applyMove(moves[rng.nextInt(moves.length)]), isTrue);
        plies++;
      }
    });
  });

  group('ChessGameController', () {
    test('点选、走子与取消选择', () {
      final controller = ChessGameController();
      // 点空位无反应
      controller.tap('e4');
      expect(controller.selected, isNull);
      // 选中红炮
      controller.tap('h2');
      expect(controller.selected, 'h2');
      expect(controller.targets, contains('e2'));
      // 再点一次取消
      controller.tap('h2');
      expect(controller.selected, isNull);
      // 选中并走子
      controller.tap('h2');
      controller.tap('e2');
      expect(controller.sideToMove, 1);
      expect(controller.selected, isNull);
      expect(controller.canUndo, isTrue);
      // 轮到黑方，红子不可选
      controller.tap('b0');
      expect(controller.selected, isNull);
      controller.dispose();
    });
  });

  // ---------- 与参照实现逐手差分 ----------
  test('初始局面：两套实现的 44 步合法着法完全一致', () {
    final rules = XiangqiRules();
    final mine = List<String>.from(rules.legalMoves(0))..sort();
    final theirs = referenceMoves(ChessFen.initFen, 0);
    expect(mine, theirs);
    expect(mine.length, 44);
  });

  test('随机对局逐手差分：合法着法集合始终一致', () {
    final rng = Random(20261030);
    final rules = XiangqiRules();
    for (var ply = 0; ply < 60; ply++) {
      final team = rules.sideToMove;
      final mine = List<String>.from(rules.legalMoves(team))..sort();
      final theirs = referenceMoves(rules.fen, team);
      expect(mine, theirs, reason: '第 $ply 手（${rules.fen}）走法集合不一致');
      if (mine.isEmpty) break;
      final mv = mine[rng.nextInt(mine.length)];
      expect(rules.applyMove(mv), isTrue);
    }
  });

  test('终局与将军判定与参照一致', () {
    // 红车 a9 将军黑将，黑无子可动
    final mate = XiangqiRules('R3k4/9/9/9/9/9/9/9/9/4K4', 1);
    expect(mate.legalMoves(1), isEmpty);
    expect(mate.result.name, 'redWin');

    // 初始局面双方均未将军
    final start = XiangqiRules();
    expect(start.inCheck, isFalse);
    expect(start.result.name, 'playing');
  });

  test('FEN 读写往返一致', () {
    final rules = XiangqiRules();
    rules.applyMove('h2e2');
    rules.applyMove('b7e7');
    final placement = rules.fen;
    final rebuilt = XiangqiRules(placement, rules.sideToMove);
    expect(rebuilt.fen, placement);
    expect(rebuilt.legalMoves(rebuilt.sideToMove),
        rules.legalMoves(rules.sideToMove));
  });

  // ---------- 揭棋规则 ----------
  test('开局：将帅明置，其余 15 子暗置且位置棋种正确', () {
    final rules = JieqiRules(Random(1));
    final pieces = rules.pieces;
    expect(pieces.length, 32);

    final kings = pieces.where((p) => p.kind == 'k');
    expect(kings.length, 2);
    expect(kings.every((p) => p.revealed), isTrue);
    expect(kings.map((p) => p.pos).toSet(), <String>{'e0', 'e9'});

    final dark = pieces.where((p) => !p.revealed);
    expect(dark.length, 30);
    // 暗子的有效走法 = 所在格位原棋种
    expect(rules.pieces.firstWhere((p) => p.pos == 'a0').code, 'R');
    expect(rules.pieces.firstWhere((p) => p.pos == 'b2').code, 'C');
    expect(rules.pieces.firstWhere((p) => p.pos == 'e3').code, 'P');
    expect(rules.pieces.firstWhere((p) => p.pos == 'a9').code, 'r');
    expect(rules.pieces.firstWhere((p) => p.pos == 'h7').code, 'c');
  });

  test('暗子走法由格位决定：兵位暗子第一步只能前进一步', () {
    final rules = JieqiRules(Random(2));
    expect(rules.legalTargets('e3'), <String>['e4']);
    // 车位暗子可直行
    expect(rules.legalTargets('a0'), contains('a2'));
    // 己方不能动对方子
    expect(rules.legalTargets('a9'), isEmpty);
  });

  test('暗子走动后翻开，此后按真实棋种走子', () {
    final rules = JieqiRules(Random(3));
    final before = rules.pieces.firstWhere((p) => p.pos == 'b0');
    expect(before.revealed, isFalse);

    rules.applyMove('b0c2');
    final moved = rules.pieces.firstWhere((p) => p.pos == 'c2');
    expect(moved.revealed, isTrue);
    // 翻开后 code 变成真实身份（不再等于格位棋种 b2=炮）
    expect(rules.history.last.flipped, isTrue);
    expect(moved.code, isNot('C'));
  });

  test('明士、明象可过河；暗子仍受原位棋种限制', () {
    // 明仕走到河界外（e5）：可自由斜走，不受九宫限制
    final advisor = JieqiState.fromFen('3k5/9/9/9/4A4/9/9/9/9/4K4 w')!;
    final aMoves = advisor.legalMoves().map(moveToCode).toList();
    expect(aMoves, contains('e5d6'));
    expect(aMoves, contains('e5f4'));

    // 明象（e5）亦不受河界限制
    final elephant = JieqiState.fromFen('3k5/9/9/9/4B4/9/9/9/9/4K4 w')!;
    final bMoves = elephant.legalMoves().map(moveToCode).toList();
    expect(bMoves.any((m) => m.startsWith('e5')), isTrue);

    // 暗子（相位 c0）按原位棋种走，不越过河界
    final dark = JieqiState.fromFen('3k5/9/9/9/9/9/9/9/9/2X1K4 w')!;
    expect(CoreBoard.fenChar(dark.board.cells[idxFromCode('c0')]), 'B');
    final dMoves =
        dark.legalMoves().map(moveToCode).where((m) => m.startsWith('c0'));
    expect(dMoves, isNotEmpty);
    expect(dMoves.every((m) => int.parse(m[3]) <= 4), isTrue);
  });

  test('被吃暗子不泄露身份', () {
    final rules = JieqiRules(Random(5));
    // 找到一步可以吃掉对方暗子的着法
    var found = false;
    for (var i = 0; i < 40 && !found; i++) {
      final moves = rules.legalMoves(rules.sideToMove);
      if (moves.isEmpty) break;
      final mv = moves.first;
      final to = mv.substring(2, 4);
      final target = rules.pieces.where((p) => p.pos == to).toList();
      if (target.isNotEmpty && !target.first.revealed) {
        rules.applyMove(mv);
        expect(rules.history.last.captured, isNull,
            reason: '被吃暗子的身份不得出现在记录中');
        found = true;
      } else {
        rules.applyMove(mv);
      }
    }
  });

  test('暗子池：翻开后扣减，总数守恒', () {
    final state = JieqiState.initial(Random(7));
    expect(state.poolTotal(0).round(), 15);
    expect(state.poolTotal(1).round(), 15);
    final mv = state.legalMoves().firstWhere((m) => state.revealed[moveFrom(m)] == 0);
    final undo = state.make(mv);
    expect(state.poolTotal(0), closeTo(14, 0.001));
    state.unmake(undo);
    expect(state.poolTotal(0), closeTo(15, 0.001));
  });

  test('make/unmake 完全可逆（随机 60 手）', () {
    final rng = Random(11);
    final state = JieqiState.initial(rng);
    for (var i = 0; i < 60; i++) {
      final moves = state.legalMoves();
      if (moves.isEmpty) break;
      final snapshot = state.copy();
      final mv = moves[rng.nextInt(moves.length)];
      final undo = state.make(mv);
      state.unmake(undo);
      expect(state.board.cells, snapshot.board.cells);
      expect(state.revealed, snapshot.revealed);
      expect(state.truth, snapshot.truth);
      expect(state.pool[0], snapshot.pool[0]);
      expect(state.pool[1], snapshot.pool[1]);
      expect(state.side, snapshot.side);
    }
  });

  test('随机自我对局可正常结束或持续推进', () {
    final rng = Random(13);
    final rules = JieqiRules(rng);
    var plies = 0;
    while (plies < 300) {
      if (rules.result != GameResult.playing) break;
      final moves = rules.legalMoves(rules.sideToMove);
      if (moves.isEmpty) break;
      expect(rules.applyMove(moves[rng.nextInt(moves.length)]), isTrue);
      plies++;
    }
    expect(plies, greaterThan(10));
  });

  test('揭棋 FEN 往返：明子身份保留，暗子重新随机', () {
    final rules = JieqiRules(Random(17));
    rules.applyMove('b0c2');
    final fen = rules.fen;
    expect(fen.split(' ')[0], contains('x'));

    final restored = JieqiState.fromFen(fen, Random(19));
    expect(restored, isNotNull);
    final restoredRules = JieqiRules.fromFen(fen, Random(19));
    expect(restoredRules.fen, fen);
    expect(restoredRules.sideToMove, rules.sideToMove);
    // 明子（含翻开的子）位置一致
    final revealedBefore = rules.pieces
        .where((p) => p.revealed)
        .map((p) => '${p.pos}${p.code}')
        .toSet();
    final revealedAfter = restoredRules.pieces
        .where((p) => p.revealed)
        .map((p) => '${p.pos}${p.code}')
        .toSet();
    expect(revealedAfter, revealedBefore);
  });

  test('与正常象棋共用接口：两者都能被同一流程驱动', () {
    for (final engine in <RulesEngine>[XiangqiRules(), JieqiRules(Random(23))]) {
      expect(engine.pieces.length, 32);
      expect(engine.result, GameResult.playing);
      final targets = engine.legalTargets(engine.sideToMove == 0 ? 'b0' : 'b9');
      expect(targets, isNotEmpty);
      expect(engine.applyMove(engine.sideToMove == 0 ? 'b0c2' : 'b9c7'), isTrue);
      expect(engine.history.length, 1);
      expect(engine.undo(), isTrue);
      expect(engine.history.length, 0);
    }
  });

  group('明士/明象自由标志（freeAE）', () {
    test('明士在对方底线左右有子、斜向空可走', () {
      // 红明士 e9，黑将 d9，红兵 f9，斜向 d8/f8 空
      final st = JieqiState.fromFen('3kAP3/9/9/9/9/9/9/9/9/4K4 w')!;
      final moves = st.legalMoves().map(moveToCode).toList();
      expect(moves, contains('e9d8'));
      expect(moves, contains('e9f8'));
    });

    test('翻开后连续走子到对方底线，标志不因试走/试吃丢失', () {
      // 红帅 e0；黑将 d9 + 黑车 i9（供黑方走子并触发试吃士）；红暗子 e3
      final rules = JieqiRules.fromFen('3k4r/9/9/9/9/9/4X4/9/9/4K4 w');
      final e3 = idxFromCode('e3');
      rules.state.truth[e3] = kAdvisor;
      rules.state.pool[0][kAdvisor] = rules.state.pool[0][kAdvisor] - 1;
      rules.state.pool[0][kPawn] = rules.state.pool[0][kPawn] + 1;

      expect(rules.applyMove('e3e4'), isTrue); // 翻开为明士
      expect(rules.applyMove('i9h9'), isTrue);
      expect(
        rules.legalTargets('e4'),
        containsAll(<String>['d5', 'f5', 'd3', 'f3']),
      );

      // 一路斜走到对方底线 f9（期间黑方走子反复触发试走/试吃）
      expect(rules.applyMove('e4f5'), isTrue);
      expect(rules.applyMove('h9i9'), isTrue);
      expect(rules.applyMove('f5e6'), isTrue);
      expect(rules.applyMove('i9h9'), isTrue);
      expect(rules.applyMove('e6f7'), isTrue);
      expect(rules.applyMove('h9i9'), isTrue);
      expect(rules.applyMove('f7e8'), isTrue);
      // 黑被 e8 明士将军，只能避将（走 d8，避免与红帅同列照面）
      expect(rules.applyMove('d9d8'), isTrue);
      expect(
        rules.legalTargets('e8'),
        containsAll(<String>['d9', 'f9', 'd7', 'f7']),
      );
      expect(rules.applyMove('e8f9'), isTrue);
      expect(rules.applyMove('d8d9'), isTrue);
      // 到对方底线 f9：斜向 e8/g8（空）
      expect(rules.legalTargets('f9'), containsAll(<String>['e8', 'g8']));
    });

    test('明士在对方底线 d9 左右有子、斜向空可过', () {
      // 黑将 c9、黑卒 e9 夹住红明士 d9；斜向 c8/e8 空
      final st = JieqiState.fromFen('2kAp4/9/9/9/9/9/9/9/9/K8 w')!;
      final moves = st.legalMoves().map(moveToCode).toList();
      expect(moves, contains('d9c8'));
      expect(moves, contains('d9e8'));
    });

    test('明象过河后自由标志不丢', () {
      final rules = JieqiRules.fromFen('3k4r/9/9/9/9/9/4X4/9/9/4K4 w');
      final e3 = idxFromCode('e3');
      rules.state.truth[e3] = kElephant;
      rules.state.pool[0][kElephant] = rules.state.pool[0][kElephant] - 1;
      rules.state.pool[0][kPawn] = rules.state.pool[0][kPawn] + 1;

      expect(rules.applyMove('e3e4'), isTrue); // 翻开为明象
      expect(rules.applyMove('i9h9'), isTrue);
      expect(rules.legalTargets('e4'), containsAll(<String>['g6', 'c6']));
      expect(rules.applyMove('e4g6'), isTrue);
      expect(rules.applyMove('h9i9'), isTrue);
      expect(rules.applyMove('g6e8'), isTrue);
      expect(rules.applyMove('i9h9'), isTrue);
      expect(rules.legalTargets('e8'), containsAll(<String>['g6', 'c6']));
    });
  });
}
