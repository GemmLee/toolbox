import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ai/ai_config.dart';
import 'ai/ai_runner.dart';
import 'rules/jieqi_rules.dart';
import 'rules/rules_engine.dart';
import 'rules/xiangqi_rules.dart';

/// 对局模式。
enum ChessMode { normal, jieqi }

/// 对手类型。
enum OpponentKind { human, ai }

/// 吃子栏里的一枚被吃棋子。
class CapturedPiece {
  const CapturedPiece({required this.code, this.hidden = false});

  /// 真实棋子码（大写红方 / 小写黑方）。
  final String code;

  /// 是否以「暗」占位显示（身份对玩家不公开）。
  final bool hidden;
}

/// 一步棋走完后的配音线索。
///
/// [check] 表示这步走完后「对方」正被将军（规则引擎的 inCheck 针对
/// 当前轮走方，落子后轮到对方，故正好是行棋方将军）。
class ChessMoveFeedback {
  const ChessMoveFeedback({required this.captured, required this.check});

  final bool captured;
  final bool check;
}

/// 对局控制器：持有规则引擎、选中状态、AI 与对局流程，供 UI 监听。
class ChessGameController extends ChangeNotifier {
  ChessGameController({
    this.mode = ChessMode.normal,
    this.opponent = OpponentKind.human,
    this.level = AiLevel.normal,
    this.previewDelay = const Duration(milliseconds: 420),
  }) : _engine = _createEngine(mode);

  ChessMode mode;
  OpponentKind opponent;
  AiLevel level;

  /// 电脑走子前，把要动的棋子高亮多长时间（0 表示不等待）。
  final Duration previewDelay;

  /// 每次成功落子后回调（人类与 AI 均触发），供页面播放配音。
  void Function(ChessMoveFeedback feedback)? onMovePlayed;

  RulesEngine _engine;
  String? _selected;
  List<String> _targets = const <String>[];
  bool _thinking = false;
  int _generation = 0;
  bool _disposed = false;

  /// 刚走完的棋子位置（金色高亮，保留到另一方走子）。
  String? _activePos;

  /// 电脑即将走动的棋子位置（走子前的短暂高亮）。
  String? _previewPos;

  static RulesEngine _createEngine(ChessMode mode) =>
      mode == ChessMode.jieqi ? JieqiRules(Random()) : XiangqiRules();

  RulesEngine get engine => _engine;
  String? get selected => _selected;
  List<String> get targets => _targets;
  bool get thinking => _thinking;
  int get sideToMove => _engine.sideToMove;
  GameResult get result => _engine.result;
  bool get inCheck => _engine.inCheck;
  String? get lastMove => _engine.lastMove;

  /// 需要高亮的棋子位置：电脑思考完毕待走时是起点，走完后是落点。
  String? get activePos => _previewPos ?? _activePos;
  List<MoveRecord> get history => _engine.history;
  bool get canUndo => _engine.history.isNotEmpty && !_thinking;

  /// 人类执子方（对电脑时固定执红）。
  static const int humanTeam = 0;

  /// 电脑执子方。
  static const int aiTeam = 1;

  /// 某方（[byTeam]）吃到的棋子，按吃掉先后排列。
  ///
  /// 揭棋人机局里，电脑吃掉的暗子不向玩家公开真实身份，以
  /// [CapturedPiece.hidden] 标记占位；玩家自己吃掉的子照实显示。
  /// 正常象棋、以及揭棋双人局（同屏共用，无法隔离）全部照实显示。
  List<CapturedPiece> capturesBy(int byTeam) {
    final out = <CapturedPiece>[];
    for (final rec in history) {
      final code = rec.captured;
      if (code == null) continue;
      if (_teamOf(rec.piece) != byTeam) continue;
      out.add(CapturedPiece(code: code, hidden: hidesCapture(rec)));
    }
    return out;
  }

  /// 该步吃掉的是否要隐藏身份（仅揭棋人机局中电脑吃掉暗子时）。
  bool hidesCapture(MoveRecord rec) {
    if (!rec.capturedHidden) return false;
    if (mode != ChessMode.jieqi || opponent != OpponentKind.ai) return false;
    return _teamOf(rec.piece) != humanTeam;
  }

  /// 棋子码归属方：大写为红方（0），小写为黑方（1）。
  static int _teamOf(String code) =>
      code.isEmpty || code == code.toUpperCase() ? 0 : 1;

  /// 点击棋盘交叉点。
  Future<void> tap(String posCode) async {
    if (_thinking || result != GameResult.playing) return;
    // 对 AI 时人类固定执红
    if (opponent == OpponentKind.ai && _engine.sideToMove != 0) return;

    final pieces = {for (final p in _engine.pieces) p.pos: p};
    final piece = pieces[posCode];

    if (_selected == null) {
      if (piece != null && piece.team == _engine.sideToMove) _select(posCode);
      return;
    }
    if (posCode == _selected) {
      _clearSelection();
      return;
    }
    if (_targets.contains(posCode)) {
      final move = _selected! + posCode;
      _clearSelection(notify: false);
      if (_engine.applyMove(move)) {
        _activePos = posCode;
        _previewPos = null;
        notifyListeners();
        _announceMove();
        await _maybeAiMove();
      }
      return;
    }
    if (piece != null && piece.team == _engine.sideToMove) {
      _select(posCode);
    } else {
      _clearSelection();
    }
  }

  void _select(String posCode) {
    _selected = posCode;
    _targets = _engine.legalTargets(posCode);
    _activePos = null; // 另一方开始走子，上一手高亮熄灭
    _previewPos = null;
    notifyListeners();
  }

  void _clearSelection({bool notify = true}) {
    _selected = null;
    _targets = const <String>[];
    if (notify) notifyListeners();
  }

  /// 轮到 AI 时在后台 Isolate 中搜索着法。
  Future<void> _maybeAiMove() async {
    if (opponent != OpponentKind.ai) return;
    if (result != GameResult.playing) return;
    final gen = ++_generation;
    _thinking = true;
    _activePos = null;
    _previewPos = null;
    notifyListeners();
    final modeName = mode == ChessMode.jieqi ? 'jieqi' : 'normal';
    final move = await ChessAi(level, modeName).chooseMove(engine: _engine);
    if (_disposed || gen != _generation) return;
    _thinking = false;
    if (move != null && move.length >= 4) {
      // 先把要动的棋子高亮一下，再落子，让电脑的走法看得清
      _previewPos = move.substring(0, 2);
      notifyListeners();
      if (previewDelay > Duration.zero) {
        await Future<void>.delayed(previewDelay);
        if (_disposed || gen != _generation) return;
      }
      _previewPos = null;
      _engine.applyMove(move);
      _activePos = move.substring(2, 4);
      _announceMove();
    }
    notifyListeners();
  }

  /// 从最新一步记录与落子后的局面生成配音线索。
  void _announceMove() {
    final callback = onMovePlayed;
    if (callback == null) return;
    final history = _engine.history;
    final captured = history.isNotEmpty && history.last.captured != null;
    callback(
      ChessMoveFeedback(captured: captured, check: _engine.inCheck),
    );
  }

  /// 手动触发 AI 走子（AI 先手场景）。
  Future<void> requestAiMove() => _maybeAiMove();

  /// 悔棋：PvP 退一步；对 AI 退到人类回合。
  void undo() {
    _generation++; // 取消进行中的 AI 搜索
    _thinking = false;
    var times = opponent == OpponentKind.ai ? 2 : 1;
    while (times > 0 && _engine.history.isNotEmpty) {
      _engine.undo();
      times--;
    }
    _clearSelection(notify: false);
    _previewPos = null;
    final last = _engine.lastMove;
    _activePos = last?.substring(2, 4);
    notifyListeners();
  }

  /// 开新局（可同时切换模式 / 对手 / 难度）。
  void newGame({
    ChessMode? mode,
    OpponentKind? opponent,
    AiLevel? level,
  }) {
    _generation++;
    _thinking = false;
    if (mode != null) this.mode = mode;
    if (opponent != null) this.opponent = opponent;
    if (level != null) this.level = level;
    _engine = _createEngine(this.mode);
    _clearSelection(notify: false);
    _activePos = null;
    _previewPos = null;
    notifyListeners();
  }

  /// 导入 FEN（揭棋 FEN 用 x/X 表示暗子）。
  bool loadFen(String fen) {
    final text = fen.trim();
    if (text.isEmpty) return false;
    final engine = mode == ChessMode.jieqi
        ? JieqiRules.fromFen(text, Random())
        : XiangqiRules(_placementOf(text), _sideOf(text));
    if (engine.pieces.length < 2) return false;
    _generation++;
    _thinking = false;
    _engine = engine;
    _clearSelection(notify: false);
    _activePos = null;
    _previewPos = null;
    notifyListeners();
    return true;
  }

  /// 用摆子模式编辑出的 FEN 开一局新棋（仅正常模式）。
  ///
  /// 返回 false 表示 FEN 无效。开局后若轮到 AI 走子会自动思考。
  Future<bool> startFromFen(
    String fen, {
    OpponentKind? opponent,
    AiLevel? level,
  }) async {
    final text = fen.trim();
    if (text.isEmpty) return false;
    final engine = XiangqiRules(_placementOf(text), _sideOf(text));
    if (engine.pieces.length < 2) return false;
    _generation++;
    _thinking = false;
    mode = ChessMode.normal;
    if (opponent != null) this.opponent = opponent;
    if (level != null) this.level = level;
    _engine = engine;
    _clearSelection(notify: false);
    _activePos = null;
    _previewPos = null;
    notifyListeners();
    if (this.opponent == OpponentKind.ai && _engine.sideToMove != 0) {
      await _maybeAiMove();
    }
    return true;
  }

  static String _placementOf(String fen) =>
      fen.trim().split(RegExp(r'\s+')).first;

  static int _sideOf(String fen) {
    final parts = fen.trim().split(RegExp(r'\s+'));
    return parts.length > 1 && parts[1].toLowerCase().startsWith('b') ? 1 : 0;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
