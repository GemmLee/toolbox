import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../core/settings/tool_texts.dart';
import 'ai/ai_config.dart';
import 'board_editor_page.dart';
import 'board_painter.dart';
import 'chess_sound.dart';
import 'game_controller.dart';
import 'rules/rules_engine.dart';
import '../../../core/widgets/app_widgets.dart';

/// 象棋对局页：正常 / 揭棋 × 双人 / 电脑（三档难度）。
class ChessPage extends StatefulWidget {
  const ChessPage({super.key, this.controller});

  /// 可选的外部控制器（测试注入用）；为空时页面自建并负责释放。
  final ChessGameController? controller;

  @override
  State<ChessPage> createState() => ChessPageState();
}

/// 对局页状态（公开以便测试驱动）。
class ChessPageState extends State<ChessPage> {
  late final ChessGameController controller;
  late final bool _ownsController;
  GameResult _lastResult = GameResult.playing;
  bool _soundOn = true;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    controller = widget.controller ?? ChessGameController();
    controller.addListener(_onUpdate);
    controller.onMovePlayed = (feedback) =>
        unawaited(ChessSound.instance.onMove(feedback));
    unawaited(_initSound());
  }

  Future<void> _initSound() async {
    await ChessSound.instance.load();
    if (mounted) setState(() => _soundOn = ChessSound.instance.enabled);
  }

  void _toggleSound() {
    final next = !_soundOn;
    setState(() => _soundOn = next);
    unawaited(ChessSound.instance.setEnabled(next));
    if (next) {
      // 打开时试听一下落子声，让用户立刻知道开关生效。
      unawaited(
        ChessSound.instance.onMove(
          const ChessMoveFeedback(captured: false, check: false),
        ),
      );
    }
  }

  @override
  void dispose() {
    controller.removeListener(_onUpdate);
    controller.onMovePlayed = null;
    if (_ownsController) controller.dispose();
    super.dispose();
  }

  void _onUpdate() {
    final result = controller.result;
    if (result != _lastResult) {
      _lastResult = result;
      if (result != GameResult.playing) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _showResult());
      }
    }
    if (mounted) setState(() {});
  }

  void _showResult() {
    if (!mounted) return;
    final title = switch (controller.result) {
      GameResult.redWin => tr('红方胜'),
      GameResult.blackWin => tr('黑方胜'),
      _ => tr('和棋'),
    };
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('对局结束')),
        content: Text(title),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('查看棋盘')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              controller.newGame();
            },
            child: Text(tr('再来一局')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final traditional = SettingsController.instance.effectiveLanguage ==
        AppLanguage.traditionalChinese;
    final chars = PieceChars(traditional: traditional);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('象棋')),
        actions: [
          IconButton(
            key: const ValueKey('chess-sound'),
            tooltip: _soundOn ? tr('关闭音效') : tr('开启音效'),
            icon: Icon(_soundOn ? Icons.volume_up : Icons.volume_off),
            onPressed: _toggleSound,
          ),
          IconButton(
            key: const ValueKey('chess-editor'),
            tooltip: tr('摆子'),
            icon: const Icon(Icons.edit),
            onPressed: _openEditor,
          ),
          IconButton(
            key: const ValueKey('chess-history'),
            tooltip: tr('对局记录'),
            icon: const Icon(Icons.history),
            onPressed: _showHistory,
          ),
          PopupMenuButton<String>(
            key: const ValueKey('chess-menu'),
            onSelected: (value) {
              if (value == 'export') {
                _showFenDialog();
              } else {
                _showImportDialog();
              }
            },
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'export', child: Text(tr('导出 FEN'))),
              PopupMenuItem<String>(value: 'import', child: Text(tr('导入 FEN'))),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _SetupBar(controller: controller),
            _StatusBar(controller: controller),
            Expanded(
              child: Center(
                // 棋盘整体上移约 20px，给底部吃子记录留出呼吸空间。
                child: Transform.translate(
                  offset: const Offset(0, -20),
                  child: _Board(
                    controller: controller,
                    chars: chars,
                  ),
                ),
              ),
            ),
            _CapturedRow(controller: controller, chars: chars),
            _ControlBar(controller: controller),
          ],
        ),
      ),
    );
  }

  /// 进入摆子模式，编辑完成后选择对手并开局。
  Future<void> _openEditor() async {
    final fen = await Navigator.of(context).push<String>(MaterialPageRoute<
        String>(
      builder: (_) => BoardEditorPage(
        initialFen:
            controller.mode == ChessMode.normal ? controller.engine.fen : null,
      ),
    ));
    if (fen == null || !mounted) return;
    await _showStartDialog(fen);
  }

  /// 选择对手与难度后开始对局。
  Future<void> _showStartDialog(String fen) async {
    var opponent = controller.opponent;
    var level = controller.level;
    final started = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(tr('开始对局')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<OpponentKind>(
                segments: <ButtonSegment<OpponentKind>>[
                  ButtonSegment<OpponentKind>(
                      value: OpponentKind.human, label: Text(tr('双人'))),
                  ButtonSegment<OpponentKind>(
                      value: OpponentKind.ai, label: Text(tr('电脑'))),
                ],
                selected: <OpponentKind>{opponent},
                onSelectionChanged: (s) =>
                    setState(() => opponent = s.first),
                showSelectedIcon: false,
              ),
              if (opponent == OpponentKind.ai)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: SegmentedButton<AiLevel>(
                    segments: <ButtonSegment<AiLevel>>[
                      ButtonSegment<AiLevel>(
                          value: AiLevel.novice, label: Text(tr('新手'))),
                      ButtonSegment<AiLevel>(
                          value: AiLevel.normal, label: Text(tr('普通'))),
                      ButtonSegment<AiLevel>(
                          value: AiLevel.master, label: Text(tr('大师'))),
                    ],
                    selected: <AiLevel>{level},
                    onSelectionChanged: (s) => setState(() => level = s.first),
                    showSelectedIcon: false,
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('开始')),
            ),
          ],
        ),
      ),
    );
    if (started != true || !mounted) return;
    final ok = await controller.startFromFen(
      fen,
      opponent: opponent,
      level: level,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('FEN 无效'))));
    }
  }

  void _showHistory() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final history = controller.history;
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: history.length + 1,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  tr('对局记录'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              );
            }
            final rec = history[index - 1];
            final side = (index - 1) % 2 == 0 ? tr('红') : tr('黑');
            final flag = rec.flipped ? ' · ${tr('翻子')}' : '';
            final eaten = rec.captured == null
                ? null
                : (controller.hidesCapture(rec) ? tr('暗') : rec.captured);
            final captured = eaten == null ? '' : ' · ${tr('吃')} $eaten';
            return ListTile(
              dense: true,
              leading: Text('${(index - 1) ~/ 2 + 1}.'),
              title: Text('$side ${rec.move}$flag$captured'),
            );
          },
        );
      },
    );
  }

  void _showFenDialog() {
    final fen = controller.engine.fen;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('导出 FEN')),
        content: SelectableText(fen),
        actions: [
          TextButton(
            onPressed: () {
              copyWithToast(context, fen);
              Navigator.of(context).pop();
            },
            child: Text(tr('复制')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('关闭')),
          ),
        ],
      ),
    );
  }

  void _showImportDialog() {
    final textController = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('导入 FEN')),
        content: TextField(
          controller: textController,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(hintText: tr('粘贴 FEN')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () {
              final ok = controller.loadFen(textController.text);
              Navigator.of(context).pop();
              if (!ok && mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(tr('FEN 无效'))));
              }
            },
            child: Text(tr('导入')),
          ),
        ],
      ),
    );
  }
}

/// 棋盘视图：负责手势换算与走子路径动画。
///
/// 每当控制器新增一手棋（对局记录变长），落点棋子就从起点滑向终点；
/// 动画时长恒定、缓动收尾，速率不随着法距离变化。
class _Board extends StatefulWidget {
  const _Board({required this.controller, required this.chars});

  final ChessGameController controller;
  final PieceChars chars;

  @override
  State<_Board> createState() => _BoardState();
}

class _BoardState extends State<_Board> with SingleTickerProviderStateMixin {
  /// 走子动画时长：落在 0.5–1s 区间，肉眼能看清棋子从起点滑到终点。
  static const Duration _animDuration = Duration(milliseconds: 700);

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: _animDuration,
    value: 1,
  );

  late final CurvedAnimation _curve =
      CurvedAnimation(parent: _anim, curve: Curves.easeInOutCubic);

  String? _animFrom;
  String? _animTo;
  int _lastHistoryLen = 0;

  @override
  void initState() {
    super.initState();
    _lastHistoryLen = widget.controller.history.length;
    widget.controller.addListener(_onControllerUpdate);
    _anim.addListener(_onTick);
    _anim.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(covariant _Board oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerUpdate);
      widget.controller.addListener(_onControllerUpdate);
      _lastHistoryLen = widget.controller.history.length;
      _anim.value = 1;
      _animFrom = null;
      _animTo = null;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdate);
    _anim.dispose();
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() {
        _animFrom = null;
        _animTo = null;
      });
    }
  }

  void _onControllerUpdate() {
    final c = widget.controller;
    final len = c.history.length;
    final move = c.lastMove;
    if (len > _lastHistoryLen && move != null && move.length >= 4) {
      // 新的一手：从起点滑向落点
      setState(() {
        _animFrom = move.substring(0, 2);
        _animTo = move.substring(2, 4);
      });
      _anim.forward(from: 0);
    } else if (len < _lastHistoryLen &&
        (_anim.isAnimating || _animFrom != null)) {
      // 悔棋 / 重开：取消进行中的动画
      _anim.stop();
      setState(() {
        _animFrom = null;
        _animTo = null;
        _anim.value = 1;
      });
    }
    _lastHistoryLen = len;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.maxWidth - 8,
          constraints.maxHeight - 8,
        );
        final geo = BoardGeometry(size);
        final animating = _animFrom != null && _animTo != null;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final pos = geo.offsetToPos(details.localPosition);
            if (pos != null) c.tap(pos);
          },
          child: CustomPaint(
            key: const ValueKey('chess-board'),
            size: Size(geo.boardWidth, geo.boardHeight),
            painter: ChessBoardPainter(
              pieces: c.engine.pieces,
              chars: widget.chars,
              selected: c.selected,
              targets: c.targets,
              lastMove: c.lastMove,
              checkKingPos: _checkKingPos(),
              activePos: c.activePos,
              animFrom: animating ? _animFrom : null,
              animTo: animating ? _animTo : null,
              animProgress: animating ? _curve.value : 1,
            ),
          ),
        );
      },
    );
  }

  /// 被将军一方老将的位置（用于光晕提示）。
  String? _checkKingPos() {
    final c = widget.controller;
    if (!c.inCheck) return null;
    final kingCode = c.sideToMove == 0 ? 'K' : 'k';
    for (final p in c.engine.pieces) {
      if (p.code == kingCode && p.revealed) return p.pos;
    }
    return null;
  }
}

/// 模式 / 对手 / 难度选择栏。
class _SetupBar extends StatelessWidget {
  const _SetupBar({required this.controller});

  final ChessGameController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<ChessMode>(
                  key: const ValueKey('chess-mode'),
                  segments: <ButtonSegment<ChessMode>>[
                    ButtonSegment<ChessMode>(
                        value: ChessMode.normal, label: Text(tr('正常'))),
                    ButtonSegment<ChessMode>(
                        value: ChessMode.jieqi, label: Text(tr('揭棋'))),
                  ],
                  selected: <ChessMode>{controller.mode},
                  onSelectionChanged: (s) => controller.newGame(mode: s.first),
                  showSelectedIcon: false,
                  style: _compactStyle(theme),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<OpponentKind>(
                  key: const ValueKey('chess-opponent'),
                  segments: <ButtonSegment<OpponentKind>>[
                    ButtonSegment<OpponentKind>(
                        value: OpponentKind.human, label: Text(tr('双人'))),
                    ButtonSegment<OpponentKind>(
                        value: OpponentKind.ai, label: Text(tr('电脑'))),
                  ],
                  selected: <OpponentKind>{controller.opponent},
                  onSelectionChanged: (s) =>
                      controller.newGame(opponent: s.first),
                  showSelectedIcon: false,
                  style: _compactStyle(theme),
                ),
              ),
            ],
          ),
          if (controller.opponent == OpponentKind.ai)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SegmentedButton<AiLevel>(
                key: const ValueKey('chess-level'),
                segments: <ButtonSegment<AiLevel>>[
                  ButtonSegment<AiLevel>(
                      value: AiLevel.novice, label: Text(tr('新手'))),
                  ButtonSegment<AiLevel>(
                      value: AiLevel.normal, label: Text(tr('普通'))),
                  ButtonSegment<AiLevel>(
                      value: AiLevel.master, label: Text(tr('大师'))),
                ],
                selected: <AiLevel>{controller.level},
                onSelectionChanged: (s) => controller.newGame(level: s.first),
                showSelectedIcon: false,
                style: _compactStyle(theme),
              ),
            ),
        ],
      ),
    );
  }

  ButtonStyle _compactStyle(ThemeData theme) => ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: WidgetStatePropertyAll<TextStyle>(
          theme.textTheme.bodySmall ?? const TextStyle(),
        ),
      );
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.controller});

  final ChessGameController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRed = controller.sideToMove == 0;
    final over = controller.result != GameResult.playing;
    final color = isRed ? const Color(0xFFC62828) : const Color(0xFF2B2B2B);
    final text =
        over ? tr('对局结束') : (isRed ? tr('红方走子') : tr('黑方走子'));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: theme.dividerColor),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          if (!over && controller.inCheck)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFC62828).withOpacity(0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                tr('将军'),
                style: theme.textTheme.labelMedium?.copyWith(
                  // 半透明红底先合成到卡片底色再取对比色，深色主题下不再黑字。
                  color: AppTheme.readableOn(
                    const Color(0xFFC62828).withOpacity(0.12),
                    base: theme.colorScheme.surface,
                  ),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (controller.thinking)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 6),
                  Text(tr('思考中'), style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          const Spacer(),
          Text(
            trf('第 {n} 手', {'n': controller.history.length}),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _CapturedRow extends StatelessWidget {
  const _CapturedRow({required this.controller, required this.chars});

  final ChessGameController controller;
  final PieceChars chars;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final redCaptures = controller.capturesBy(0);
    final blackCaptures = controller.capturesBy(1);
    if (redCaptures.isEmpty && blackCaptures.isEmpty) {
      return const SizedBox(height: 4);
    }
    Widget line(String key, String label, List<CapturedPiece> items,
        Color color) {
      return Row(
        children: [
          SizedBox(
              width: 76,
              child: Text(label,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600))),
          Expanded(
            child: Text(
              items
                  .map((e) => e.hidden ? tr('暗') : chars.of(e.code))
                  .join(' '),
              key: ValueKey<String>(key),
              style: theme.textTheme.bodyLarge
                  ?.copyWith(color: color, fontWeight: FontWeight.w700),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          line('captures-red', tr('红方吃子'), redCaptures, const Color(0xFFC62828)),
          const SizedBox(height: 2),
          line('captures-black', tr('黑方吃子'), blackCaptures,
              const Color(0xFF2B2B2B)),
        ],
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.controller});

  final ChessGameController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('chess-undo'),
              onPressed: controller.canUndo ? () => controller.undo() : null,
              icon: const Icon(Icons.undo, size: 18),
              label: Text(tr('悔棋')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.tonalIcon(
              key: const ValueKey('chess-restart'),
              onPressed: () => controller.newGame(),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(tr('重新开始')),
            ),
          ),
        ],
      ),
    );
  }
}
