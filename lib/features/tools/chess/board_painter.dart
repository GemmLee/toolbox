import 'package:flutter/material.dart';

import 'rules/rules_engine.dart';

/// 棋盘几何：负责位置码与屏幕坐标的相互换算。
///
/// 位置码：列 a-i（0-8），行 0-9；红方底线为 0，黑方底线为 9。
/// 屏幕上 y=9 在顶部（黑方），y=0 在底部（红方）。
class BoardGeometry {
  BoardGeometry(Size size)
      : cell = _fitCell(size),
        margin = _fitCell(size) * 0.55;

  static const int cols = 9;
  static const int rows = 10;

  final double cell;
  final double margin;

  static double _fitCell(Size size) {
    const marginFactor = 0.55;
    final byWidth = size.width / (cols - 1 + marginFactor * 2);
    final byHeight = size.height / (rows - 1 + marginFactor * 2);
    return byWidth < byHeight ? byWidth : byHeight;
  }

  double get boardWidth => margin * 2 + (cols - 1) * cell;
  double get boardHeight => margin * 2 + (rows - 1) * cell;

  Offset posToOffset(String code) {
    final x = code.codeUnitAt(0) - 0x61; // 'a'
    final y = int.parse(code[1]);
    return Offset(margin + x * cell, margin + (rows - 1 - y) * cell);
  }

  /// 把触点换算为最近的交叉点位置码；超过阈值返回 null。
  String? offsetToPos(Offset offset) {
    final fx = (offset.dx - margin) / cell;
    final fy = (offset.dy - margin) / cell;
    final x = fx.round();
    final yRow = fy.round();
    if (x < 0 || x >= cols || yRow < 0 || yRow >= rows) return null;
    if ((fx - x).abs() > 0.42 || (fy - yRow).abs() > 0.42) return null;
    final y = rows - 1 - yRow;
    return '${String.fromCharCode(0x61 + x)}$y';
  }
}

/// 棋子显示文字（简体中文 / 繁体中文两套）。
class PieceChars {
  PieceChars({this.traditional = false});

  final bool traditional;

  static const Map<String, String> _zh = <String, String>{
    'K': '帅', 'A': '仕', 'B': '相', 'R': '车', 'N': '马', 'C': '炮', 'P': '兵',
    'k': '将', 'a': '士', 'b': '象', 'r': '车', 'n': '马', 'c': '砲', 'p': '卒',
  };

  static const Map<String, String> _tw = <String, String>{
    'K': '帥', 'A': '仕', 'B': '相', 'R': '俥', 'N': '傌', 'C': '炮', 'P': '兵',
    'k': '將', 'a': '士', 'b': '象', 'r': '車', 'n': '馬', 'c': '砲', 'p': '卒',
  };

  String of(String code) =>
      (traditional ? _tw : _zh)[code] ?? code;
}

/// 棋盘 + 棋子绘制器。
class ChessBoardPainter extends CustomPainter {
  ChessBoardPainter({
    required this.pieces,
    required this.chars,
    this.selected,
    this.targets = const <String>[],
    this.lastMove,
    this.checkKingPos,
    this.activePos,
    this.animFrom,
    this.animTo,
    this.animProgress = 1,
  });

  final List<PieceView> pieces;
  final PieceChars chars;
  final String? selected;
  final List<String> targets;

  /// 坐标着法（如 'h2e2'），用于最近一步高亮。
  final String? lastMove;

  /// 被将军一方老将的位置（红色光晕提示）。
  final String? checkKingPos;

  /// 正在走动 / 刚走完的棋子位置（金色高亮，持续到另一方走子）。
  final String? activePos;

  /// 走子动画：棋子从 [animFrom] 滑向 [animTo]，[animProgress] 为 0-1 插值。
  /// 动画播放中，落点棋子不按格位绘制，改画在插值位置上。
  final String? animFrom;
  final String? animTo;
  final double animProgress;

  static const Color _boardBg = Color(0xFFF6E3B4);
  static const Color _boardEdge = Color(0xFF7A4A21);
  static const Color _line = Color(0xFF8A5A2B);
  static const Color _red = Color(0xFFC62828);
  static const Color _black = Color(0xFF2B2B2B);
  static const Color _pieceBg = Color(0xFFFDF6E0);
  static const Color _highlight = Color(0xFF2E7D32);
  static const Color _active = Color(0xFFF9A825);

  @override
  void paint(Canvas canvas, Size size) {
    final geo = BoardGeometry(size);
    final boardRect =
        Rect.fromLTWH(0, 0, geo.boardWidth, geo.boardHeight);

    // 底板
    canvas.drawRect(boardRect, Paint()..color = _boardBg);

    final gridPaint = Paint()
      ..color = _line
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    _drawGrid(canvas, geo, gridPaint);
    _drawPalace(canvas, geo, gridPaint);
    _drawStarMarks(canvas, geo, gridPaint);
    _drawRiver(canvas, geo);
    _drawLastMove(canvas, geo);
    _drawTargets(canvas, geo);
    _drawActiveGlow(canvas, geo);

    // 移动中的棋子：跳过落点格位，最后画在插值位置上（保证浮在其他棋子上方）
    PieceView? moving;
    for (final piece in pieces) {
      if (animFrom != null && animTo != null && piece.pos == animTo) {
        moving = piece;
        continue;
      }
      _drawPiece(canvas, geo, piece);
    }
    if (moving != null && animFrom != null) {
      final from = geo.posToOffset(animFrom!);
      final to = geo.posToOffset(moving.pos);
      final c = Offset.lerp(from, to, animProgress.clamp(0.0, 1.0))!;
      _drawPieceAt(canvas, geo, moving, c);
    }

    _drawSelection(canvas, geo);
    _drawActiveRing(canvas, geo);
    _drawCheckHalo(canvas, geo);

    // 外框
    canvas.drawRect(
      boardRect.deflate(0.5),
      Paint()
        ..color = _boardEdge
        ..strokeWidth = 2.4
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawGrid(Canvas canvas, BoardGeometry geo, Paint paint) {
    // 横线
    for (var row = 0; row < BoardGeometry.rows; row++) {
      final y = geo.margin + row * geo.cell;
      canvas.drawLine(
        Offset(geo.margin, y),
        Offset(geo.margin + (BoardGeometry.cols - 1) * geo.cell, y),
        paint,
      );
    }
    // 竖线：边线贯通，中间线在楚河汉界处断开
    final top = geo.margin;
    final riverTop = geo.margin + 4 * geo.cell;
    final riverBottom = geo.margin + 5 * geo.cell;
    final bottom = geo.margin + (BoardGeometry.rows - 1) * geo.cell;
    for (var col = 0; col < BoardGeometry.cols; col++) {
      final x = geo.margin + col * geo.cell;
      if (col == 0 || col == BoardGeometry.cols - 1) {
        canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
      } else {
        canvas.drawLine(Offset(x, top), Offset(x, riverTop), paint);
        canvas.drawLine(Offset(x, riverBottom), Offset(x, bottom), paint);
      }
    }
  }

  void _drawPalace(Canvas canvas, BoardGeometry geo, Paint paint) {
    // 上方（黑方）九宫
    canvas.drawLine(geo.posToOffset('d9'), geo.posToOffset('f7'), paint);
    canvas.drawLine(geo.posToOffset('f9'), geo.posToOffset('d7'), paint);
    // 下方（红方）九宫
    canvas.drawLine(geo.posToOffset('d2'), geo.posToOffset('f0'), paint);
    canvas.drawLine(geo.posToOffset('f2'), geo.posToOffset('d0'), paint);
  }

  void _drawStarMarks(Canvas canvas, BoardGeometry geo, Paint paint) {
    const starPos = <String>[
      'b7', 'h7', 'b2', 'h2', // 炮位
      'a6', 'c6', 'e6', 'g6', 'i6', // 黑卒位
      'a3', 'c3', 'e3', 'g3', 'i3', // 红兵位
    ];
    const gap = 3.0;
    final len = geo.cell * 0.12;
    for (final code in starPos) {
      final c = geo.posToOffset(code);
      // 四个角的短折线；靠边位置只画朝内的角
      final dirs = <List<int>>[
        if (code[0] != 'a') ...[
          [-1, -1],
          [-1, 1],
        ],
        if (code[0] != 'i') ...[
          [1, -1],
          [1, 1],
        ],
      ];
      for (final d in dirs) {
        final dx = d[0].toDouble();
        final dy = d[1].toDouble();
        final corner = c + Offset(dx * gap, dy * gap);
        canvas.drawLine(
          corner,
          corner + Offset(dx * len, 0),
          paint,
        );
        canvas.drawLine(
          corner,
          corner + Offset(0, dy * len),
          paint,
        );
      }
    }
  }

  void _drawRiver(Canvas canvas, BoardGeometry geo) {
    final style = TextStyle(
      color: _line.withOpacity(0.85),
      fontSize: geo.cell * 0.46,
      fontWeight: FontWeight.w600,
      letterSpacing: geo.cell * 0.35,
      height: 1,
    );
    final y = geo.margin + 4.5 * geo.cell;
    final left = TextPainter(
      text: TextSpan(text: '楚 河', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final right = TextPainter(
      text: TextSpan(text: '漢 界', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    left.paint(
      canvas,
      Offset(geo.margin + geo.cell * 1.1, y - left.height / 2),
    );
    right.paint(
      canvas,
      Offset(geo.margin + geo.cell * 5.2, y - right.height / 2),
    );
  }

  void _drawLastMove(Canvas canvas, BoardGeometry geo) {
    if (lastMove == null || lastMove!.length < 4) return;
    final paint = Paint()
      ..color = _highlight.withOpacity(0.22)
      ..style = PaintingStyle.fill;
    final r = geo.cell * 0.47;
    canvas.drawCircle(geo.posToOffset(lastMove!.substring(0, 2)), r, paint);
    canvas.drawCircle(geo.posToOffset(lastMove!.substring(2, 4)), r, paint);
  }

  void _drawTargets(Canvas canvas, BoardGeometry geo) {
    final occupied = {for (final p in pieces) p.pos};
    final dotPaint = Paint()..color = _highlight.withOpacity(0.85);
    final ringPaint = Paint()
      ..color = _highlight.withOpacity(0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final target in targets) {
      final c = geo.posToOffset(target);
      if (occupied.contains(target)) {
        // 可吃子：画圆环
        canvas.drawCircle(c, geo.cell * 0.45, ringPaint);
      } else {
        canvas.drawCircle(c, geo.cell * 0.09, dotPaint);
      }
    }
  }

  void _drawPiece(Canvas canvas, BoardGeometry geo, PieceView piece) {
    _drawPieceAt(canvas, geo, piece, geo.posToOffset(piece.pos));
  }

  /// 在屏幕坐标 [c] 处绘制一枚棋子（供格位绘制与走子动画共用）。
  void _drawPieceAt(Canvas canvas, BoardGeometry geo, PieceView piece,
      Offset c) {
    final radius = geo.cell * 0.42;
    final teamColor = piece.team == 0 ? _red : _black;

    if (!piece.revealed) {
      // 暗子背面（揭棋）：深色圆盘 + 内圈
      canvas.drawCircle(c, radius, Paint()..color = const Color(0xFF8D6E4A));
      canvas.drawCircle(
        c,
        radius * 0.78,
        Paint()
          ..color = const Color(0xFF6E5233)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: '?',
          style: TextStyle(
            color: const Color(0xFFF6E3B4),
            fontSize: radius * 0.9,
            fontWeight: FontWeight.bold,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
      return;
    }

    // 阴影 + 盘面 + 边框
    canvas.drawCircle(
      c + const Offset(1, 1.5),
      radius,
      Paint()..color = Colors.black.withOpacity(0.18),
    );
    canvas.drawCircle(c, radius, Paint()..color = _pieceBg);
    canvas.drawCircle(
      c,
      radius,
      Paint()
        ..color = teamColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
    canvas.drawCircle(
      c,
      radius * 0.82,
      Paint()
        ..color = teamColor.withOpacity(0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );

    final tp = TextPainter(
      text: TextSpan(
        text: chars.of(piece.code),
        style: TextStyle(
          color: teamColor,
          fontSize: radius * 1.05,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawSelection(Canvas canvas, BoardGeometry geo) {
    if (selected == null) return;
    canvas.drawCircle(
      geo.posToOffset(selected!),
      geo.cell * 0.47,
      Paint()
        ..color = _highlight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4,
    );
  }

  /// 正在走动 / 刚走完的棋子：先铺一层暖色柔光（画在棋子下方）。
  void _drawActiveGlow(Canvas canvas, BoardGeometry geo) {
    if (activePos == null) return;
    final c = geo.posToOffset(activePos!);
    canvas.drawCircle(
      c,
      geo.cell * 0.5,
      Paint()..color = _active.withOpacity(0.30),
    );
    canvas.drawCircle(
      c,
      geo.cell * 0.56,
      Paint()
        ..color = _active.withOpacity(0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
  }

  /// 金色描边（画在棋子上方，确保压住棋子边缘）。
  void _drawActiveRing(Canvas canvas, BoardGeometry geo) {
    if (activePos == null) return;
    canvas.drawCircle(
      geo.posToOffset(activePos!),
      geo.cell * 0.44,
      Paint()
        ..color = _active
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6,
    );
  }

  void _drawCheckHalo(Canvas canvas, BoardGeometry geo) {
    if (checkKingPos == null) return;
    canvas.drawCircle(
      geo.posToOffset(checkKingPos!),
      geo.cell * 0.47,
      Paint()..color = _red.withOpacity(0.35),
    );
  }

  @override
  bool shouldRepaint(covariant ChessBoardPainter oldDelegate) => true;
}
