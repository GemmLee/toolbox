import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/chess/ai/ai_config.dart';
import 'package:toolbox/features/tools/chess/board_editor_page.dart';
import 'package:toolbox/features/tools/chess/chess_page.dart';
import 'package:toolbox/features/tools/chess/game_controller.dart';
import '../support/test_env.dart';

/// 揭棋局面：红车 a0 可吃黑暗卒 a6；黑车 i9 可吃红暗卒 i3。
///
/// 暗子必须摆在各自的初始格位上（FEN 里 x/X 的身份由格位决定）。
/// 两将不可同列对脸，否则红方开局即被「白脸将」将军而没有任何走法。
const String _fen = '3k4r/9/9/x8/9/9/8X/9/9/R3K4 w';

/// 走出一红一黑各吃一个暗子的局面。
Future<ChessGameController> _playJieqiCaptures() async {
  final c = ChessGameController(
    mode: ChessMode.jieqi,
    opponent: OpponentKind.human,
  );
  expect(c.loadFen(_fen), isTrue);
  await c.tap('a0'); // 红车
  await c.tap('a6'); // 吃黑暗卒
  await c.tap('i9'); // 黑车
  await c.tap('i3'); // 吃红暗卒
  expect(c.history.length, 2);
  return c;
}

void main() {
  // setUp 里就要用 SharedPreferences 的 mock，必须先初始化 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------- 对局页 ----------
  installCleanEnv();

  testWidgets('象棋页渲染并可通过点击走子', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChessPage()));
    await tester.pumpAndSettle();

    expect(find.text('红方走子'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);

    // 棋盘几何：boardWidth = cell * (8 + 0.55 * 2)
    final board = tester.getRect(find.byKey(const ValueKey('chess-board')));
    final cell = board.width / 9.1;
    const marginFactor = 0.55;

    Offset at(String code) {
      final col = code.codeUnitAt(0) - 0x61;
      final row = int.parse(code[1]);
      return board.topLeft +
          Offset((marginFactor + col) * cell, (marginFactor + 9 - row) * cell);
    }

    await tester.tapAt(at('h2'));
    await tester.pumpAndSettle();
    await tester.tapAt(at('e2'));
    await tester.pumpAndSettle();

    expect(find.text('黑方走子'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chess-undo')));
    await tester.pumpAndSettle();
    expect(find.text('红方走子'), findsOneWidget);
  });

  testWidgets('可切换到揭棋模式：暗子背面渲染，走动后翻开', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChessPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('揭棋'));
    await tester.pumpAndSettle();

    // 揭棋开局：双方各 15 个暗子 + 2 个明将
    final boardState = tester.state<ChessPageState>(find.byType(ChessPage));
    final pieces = boardState.controller.engine.pieces;
    expect(pieces.where((p) => !p.revealed).length, 30);
    expect(pieces.where((p) => p.revealed).length, 2);

    const from = 'e3';
    final target = boardState.controller.engine.legalTargets(from).first;
    await boardState.controller.tap(from);
    await tester.pumpAndSettle();
    await boardState.controller.tap(target);
    await tester.pumpAndSettle();

    final history = boardState.controller.history;
    expect(history.length, 1);
    expect(history.first.flipped, isTrue);
    expect(history.first.captured, isNull);
  });

  testWidgets('对局记录可查看', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChessPage()));
    await tester.pumpAndSettle();

    final state = tester.state<ChessPageState>(find.byType(ChessPage));
    await state.controller.tap('h2');
    await tester.pumpAndSettle();
    await state.controller.tap('e2');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('chess-history')));
    await tester.pumpAndSettle();
    expect(find.text('对局记录'), findsOneWidget);
    expect(find.text('红 h2e2'), findsOneWidget);
  });

  testWidgets('走子后落点保持高亮，直到另一方选中棋子', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChessPage()));
    await tester.pumpAndSettle();

    final state = tester.state<ChessPageState>(find.byType(ChessPage));
    await state.controller.tap('h2');
    await tester.pumpAndSettle();
    // 仅选中、尚未走子时没有「走完」高亮
    expect(state.controller.activePos, isNull);

    await state.controller.tap('e2');
    await tester.pumpAndSettle();
    expect(state.controller.activePos, 'e2');

    // 黑方选中自己的棋子后，上一手高亮熄灭
    await state.controller.tap('b9');
    await tester.pumpAndSettle();
    expect(state.controller.activePos, isNull);
  });

  // ---------- 摆子模式 ----------
  Offset boardPoint(WidgetTester tester, String code) {
    final board = tester.getRect(find.byKey(const ValueKey('editor-board')));
    final cell = board.width / 9.1;
    const margin = 0.55;
    final col = code.codeUnitAt(0) - 0x61;
    final row = int.parse(code[1]);
    return board.topLeft +
        Offset((margin + col) * cell, (margin + 9 - row) * cell);
  }

  testWidgets('摆子模式：清空、放置、移除、撤销与完成返回 FEN', (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: OutlinedButton(
              onPressed: () async {
                result = await Navigator.of(context).push<String>(
                  MaterialPageRoute<String>(
                      builder: (_) => const BoardEditorPage()),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 清空棋盘
    await tester.tap(find.byKey(const ValueKey('editor-clear')));
    await tester.pumpAndSettle();

    // 选择红车放到 a5（空点）
    await tester.tap(find.byKey(const ValueKey('editor-palette-R')));
    await tester.pumpAndSettle();
    await tester.tapAt(boardPoint(tester, 'a5'));
    await tester.pumpAndSettle();

    // 取消选择后再点 a5 = 移除
    await tester.tap(find.byKey(const ValueKey('editor-palette-R')));
    await tester.pumpAndSettle();
    await tester.tapAt(boardPoint(tester, 'a5'));
    await tester.pumpAndSettle();

    // 黑卒放到 a3，然后撤销
    await tester.tap(find.byKey(const ValueKey('editor-palette-p')));
    await tester.pumpAndSettle();
    await tester.tapAt(boardPoint(tester, 'a3'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-undo')));
    await tester.pumpAndSettle();

    // 再放一个红车到 b5，验证放置可保留
    await tester.tap(find.byKey(const ValueKey('editor-palette-R')));
    await tester.pumpAndSettle();
    await tester.tapAt(boardPoint(tester, 'b5'));
    await tester.pumpAndSettle();

    // 补上双方老将
    await tester.tap(find.byKey(const ValueKey('editor-palette-K')));
    await tester.pumpAndSettle();
    await tester.tapAt(boardPoint(tester, 'e0'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-palette-k')));
    await tester.pumpAndSettle();
    await tester.tapAt(boardPoint(tester, 'd9'));
    await tester.pumpAndSettle();

    // 完成并返回 FEN
    await tester.tap(find.byKey(const ValueKey('editor-done')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(
      result,
      '3k5/9/9/9/1R7/9/9/9/9/4K4 w',
    );
  });

  testWidgets('校验：缺少黑将不能完成', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BoardEditorPage()));
    await tester.pumpAndSettle();

    // 未选棋子点击黑将 e9 移除
    await tester.tapAt(boardPoint(tester, 'e9'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('editor-done')));
    await tester.pumpAndSettle();

    expect(find.text('双方各需一将一帅'), findsOneWidget);
    // 未返回（无 Navigator.pop 结果）
  });

  testWidgets('黑先切换写入 FEN', (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: OutlinedButton(
              onPressed: () async {
                result = await Navigator.of(context).push<String>(
                  MaterialPageRoute<String>(
                      builder: (_) => const BoardEditorPage()),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('黑先'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-done')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result, endsWith(' b'));
  });

  testWidgets('对局页摆子入口：完成弹出开始对局并按所选 FEN 开局', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChessPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('chess-editor')));
    await tester.pumpAndSettle();
    expect(find.text('摆子模式'), findsOneWidget);

    // 初始局面直接完成
    await tester.tap(find.byKey(const ValueKey('editor-done')));
    await tester.pumpAndSettle();

    // 开始对局对话框：选电脑 + 新手
    await tester.tap(find.text('电脑').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('新手').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();

    final state = tester.state<ChessPageState>(find.byType(ChessPage));
    expect(state.controller.mode, isNotNull);
    expect(state.controller.history, isEmpty);
  });

  // ---------- 走子高亮 ----------
  test('电脑走子：先高亮待走棋子，落子后保持落点高亮', () async {
    final controller = ChessGameController(
      opponent: OpponentKind.ai,
      level: AiLevel.novice,
      // 拉长预览时间，便于在测试里观察中间态
      previewDelay: const Duration(milliseconds: 1500),
    );
    addTearDown(controller.dispose);

    await controller.tap('h2');
    // 不等待：AI 走子流程包含搜索 + 预览延迟
    unawaited(controller.tap('e2'));

    // 等搜索结束、进入预览阶段
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(controller.thinking, isFalse);
    expect(controller.history.length, 1, reason: '预览阶段还不应该落子');
    final preview = controller.activePos;
    expect(preview, isNotNull, reason: '待走棋子应先高亮');

    // 等预览结束、落子完成
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(controller.history.length, 2);
    final applied = controller.history.last.move;
    expect(preview, applied.substring(0, 2), reason: '预览高亮应在起点');
    expect(controller.activePos, applied.substring(2, 4),
        reason: '落子后高亮移到落点');

    // 人类选中棋子后，高亮熄灭
    await controller.tap('c0');
    expect(controller.activePos, isNull);
  });

  // ---------- 吃子栏显示 ----------
  test('揭棋记录把「真实身份」与「是否公开」分开保存', () async {
    final c = await _playJieqiCaptures();
    addTearDown(c.dispose);

    final h = c.history;
    // 红车吃黑暗卒：真实身份照记（小写），但标记为未公开
    expect(h[0].captured, isNotNull);
    expect(h[0].capturedHidden, isTrue);
    expect(h[0].captured, h[0].captured!.toLowerCase());
    // 黑车吃红暗卒：真实身份照记（大写）
    expect(h[1].captured, isNotNull);
    expect(h[1].capturedHidden, isTrue);
    expect(h[1].captured, h[1].captured!.toUpperCase());
  });

  test('揭棋双人：吃子栏全部显示真实身份', () async {
    final c = await _playJieqiCaptures();
    addTearDown(c.dispose);

    final red = c.capturesBy(ChessGameController.humanTeam);
    final black = c.capturesBy(ChessGameController.aiTeam);
    expect(red.single.hidden, isFalse);
    expect(red.single.code, c.history[0].captured);
    expect(black.single.hidden, isFalse);
    expect(black.single.code, c.history[1].captured);
  });

  test('揭棋人机：电脑吃掉的暗子隐藏身份，玩家吃掉的照实显示', () async {
    final c = await _playJieqiCaptures();
    addTearDown(c.dispose);
    c.opponent = OpponentKind.ai;

    final mine = c.capturesBy(ChessGameController.humanTeam).single;
    final ai = c.capturesBy(ChessGameController.aiTeam).single;
    expect(mine.hidden, isFalse, reason: '玩家吃掉的子应显示真身');
    expect(mine.code, c.history[0].captured);
    expect(ai.hidden, isTrue, reason: '电脑吃掉的暗子不应泄露身份');

    // 记录列表用同一套策略
    expect(c.hidesCapture(c.history[0]), isFalse);
    expect(c.hidesCapture(c.history[1]), isTrue);
  });

  testWidgets('吃子栏渲染：人机揭棋中电脑吃子显示「暗」，玩家吃子显示真身', (tester) async {
    final c = await _playJieqiCaptures();
    c.opponent = OpponentKind.ai;

    await tester.pumpWidget(MaterialApp(home: ChessPage(controller: c)));
    await tester.pumpAndSettle();

    final redText =
        tester.widget<Text>(find.byKey(const ValueKey('captures-red'))).data;
    final blackText =
        tester.widget<Text>(find.byKey(const ValueKey('captures-black'))).data;
    expect(redText, isNotNull);
    expect(redText, isNot('暗'));
    expect(blackText, '暗');
  });
}
