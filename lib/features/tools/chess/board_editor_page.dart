import 'package:flutter/material.dart';

import '../../../core/settings/settings_controller.dart';
import '../../../core/settings/tool_texts.dart';
import 'board_painter.dart';
import 'engine/chess_core.dart';
import 'rules/rules_engine.dart';
import 'rules/xiangqi_rules.dart';
import '../../../core/widgets/app_widgets.dart';

/// 每方每种棋子的数量上限。
const Map<String, int> _kindLimit = <String, int>{
  'k': 1, 'a': 2, 'b': 2, 'n': 2, 'r': 2, 'c': 2, 'p': 5,
};

/// 棋盘编辑页：点选下方棋子托盘，再点棋盘交叉点放置 / 替换；
/// 未选中棋子时点击棋盘上的棋子将其移除。完成后返回 FEN。
class BoardEditorPage extends StatefulWidget {
  const BoardEditorPage({super.key, this.initialFen});

  /// 进入编辑器时的初始局面（仅摆放字段；null 用标准初始局面）。
  final String? initialFen;

  @override
  State<BoardEditorPage> createState() => _BoardEditorPageState();
}

class _BoardEditorPageState extends State<BoardEditorPage> {
  late Map<String, String> _cells;
  late final Map<String, String> _entrySnapshot;
  late final String _entryFen;
  int _side = 0; // 0 = 红先, 1 = 黑先
  String? _palette; // 选中的托盘棋子（FEN 字符）
  final List<List<MapEntry<String, String?>>> _undoStack =
      <List<MapEntry<String, String?>>>[];

  @override
  void initState() {
    super.initState();
    _entryFen = widget.initialFen ?? CoreBoard.initialFen;
    _entrySnapshot = _parsePlacement(_entryFen);
    _cells = Map<String, String>.from(_entrySnapshot);
    _side = _entryFen.trim().split(RegExp(r'\s+')).length > 1 &&
            _entryFen.trim().split(RegExp(r'\s+'))[1].startsWith('b')
        ? 1
        : 0;
  }

  static Map<String, String> _parsePlacement(String fen) {
    final cells = <String, String>{};
    final placement = fen.trim().split(RegExp(r'\s+')).first;
    final rows = placement.split('/');
    for (var r = 0; r < 10 && r < rows.length; r++) {
      final y = 9 - r;
      var x = 0;
      for (var i = 0; i < rows[r].length; i++) {
        final ch = rows[r][i];
        final digit = int.tryParse(ch);
        if (digit != null) {
          x += digit;
        } else {
          cells['${String.fromCharCode(0x61 + x)}$y'] = ch;
          x++;
        }
      }
    }
    return cells;
  }

  String get _placement {
    final buf = StringBuffer();
    for (var r = 0; r < 10; r++) {
      final y = 9 - r;
      var empty = 0;
      if (r > 0) buf.write('/');
      for (var x = 0; x < 9; x++) {
        final code = _cells['${String.fromCharCode(0x61 + x)}$y'];
        if (code == null) {
          empty++;
        } else {
          if (empty > 0) buf.write(empty);
          empty = 0;
          buf.write(code);
        }
      }
      if (empty > 0) buf.write(empty);
    }
    return buf.toString();
  }

  void _pushUndo(List<MapEntry<String, String?>> changes) {
    _undoStack.add(changes);
    if (_undoStack.length > 200) _undoStack.removeAt(0);
  }

  /// 单点变更的撤销记录。
  List<MapEntry<String, String?>> _change(String pos, String? code) =>
      <MapEntry<String, String?>>[MapEntry(pos, _cells[pos])];

  void _tapPoint(String pos) {
    if (_palette != null) {
      if (_cells[pos] == _palette) {
        // 再点同一种棋子 = 移除
        _pushUndo(_change(pos, null));
        setState(() {
          _cells.remove(pos);
          _palette = null;
        });
        return;
      }
      if (!_checkLimit(_palette!)) return;
      _pushUndo(_change(pos, _palette));
      setState(() => _cells[pos] = _palette!);
      return;
    }
    // 未选中棋子：点击已有棋子 = 移除
    if (_cells.containsKey(pos)) {
      _pushUndo(_change(pos, null));
      setState(() => _cells.remove(pos));
    }
  }

  bool _checkLimit(String code) {
    // 按「颜色 + 棋种」计数：红帅与黑将各占 1 个名额，互不影响。
    final limit = _kindLimit[code.toLowerCase()]!;
    final count = _cells.values.where((c) => c == code).length;
    if (count < limit) return true;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(tr('棋子超出数量限制'))));
    return false;
  }

  // ---- 整体操作（各记一次撤销） ----

  void _restore() {
    final changes = <MapEntry<String, String?>>[
      for (final pos in _cells.keys.toSet().union(_entrySnapshot.keys.toSet()))
        MapEntry(pos, _entrySnapshot[pos]),
    ];
    _pushUndo(changes);
    setState(() => _cells = Map<String, String>.from(_entrySnapshot));
  }

  void _clearAll() {
    _pushUndo(<MapEntry<String, String?>>[
      for (final entry in _cells.entries) MapEntry(entry.key, entry.value),
    ]);
    setState(() => _cells.clear());
  }

  void _initial() {
    final target = _parsePlacement(CoreBoard.initialFen);
    _pushUndo(<MapEntry<String, String?>>[
      for (final pos in _cells.keys.toSet().union(target.keys.toSet()))
        MapEntry(pos, target[pos]),
    ]);
    setState(() => _cells = Map<String, String>.from(target));
  }

  void _swapSides() {
    final swapped = <String, String>{};
    final changes = <MapEntry<String, String?>>[];
    _cells.forEach((pos, code) {
      final next = code == code.toUpperCase()
          ? code.toLowerCase()
          : code.toUpperCase();
      swapped[pos] = next;
      changes.add(MapEntry(pos, code));
    });
    _pushUndo(changes);
    setState(() => _cells = swapped);
  }

  void _flipBoard() {
    final flipped = <String, String>{};
    final changes = <MapEntry<String, String?>>[];
    _cells.forEach((pos, code) {
      final x = 8 - (pos.codeUnitAt(0) - 0x61);
      final y = 9 - int.parse(pos[1]);
      final next = '${String.fromCharCode(0x61 + x)}$y';
      flipped[next] = code;
      // 上下映射为双射，next 集合与原 occupied 集合相同：
      // 撤销时把每个位置还原为翻转前的棋子即可。
      changes.add(MapEntry(pos, code));
    });
    _pushUndo(changes);
    setState(() => _cells = flipped);
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    final changes = _undoStack.removeLast();
    setState(() {
      for (final change in changes.reversed) {
        if (change.value == null) {
          _cells.remove(change.key);
        } else {
          _cells[change.key] = change.value!;
        }
      }
    });
  }

  // ---- 校验与完成 ----

  void _finish() {
    final placement = _placement;
    if (_cells.values.where((c) => c == 'K').length != 1 ||
        _cells.values.where((c) => c == 'k').length != 1) {
      showToast(context, tr('双方各需一将一帅'));
      return;
    }
    // 将帅照面检查
    for (final k in const <String>['K', 'k']) {
      final pos = _cells.entries.firstWhere((e) => e.value == k).key;
      final x = pos[0];
      final y = int.parse(pos[1]);
      var facing = false;
      for (final e in _cells.entries) {
        if (e.value != (k == 'K' ? 'k' : 'K')) continue;
        if (e.key[0] != x) continue;
        final otherY = int.parse(e.key[1]);
        final lo = y < otherY ? y : otherY;
        final hi = y < otherY ? otherY : y;
        var blocked = false;
        for (var yy = lo + 1; yy < hi; yy++) {
          if (_cells.containsKey('$x$yy')) blocked = true;
        }
        if (!blocked) facing = true;
      }
      if (facing) {
        showToast(context, tr('将帅不能照面'));
        return;
      }
    }
    final engine = XiangqiRules(placement, _side);
    if (engine.result != GameResult.playing) {
      showToast(context, tr('当前方无合法着法'));
      return;
    }
    Navigator.of(context).pop('$placement ${_side == 0 ? 'w' : 'b'}');
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final traditional = SettingsController.instance.effectiveLanguage ==
        AppLanguage.traditionalChinese;
    final chars = PieceChars(traditional: traditional);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('摆子模式')),
        actions: [
          IconButton(
            tooltip: tr('返回'),
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(
                      constraints.maxWidth - 8,
                      constraints.maxHeight - 8,
                    );
                    final geo = BoardGeometry(size);
                    final pieces = <PieceView>[
                      for (final entry in _cells.entries)
                        PieceView(
                          code: entry.value,
                          team: entry.value == entry.value.toUpperCase() ? 0 : 1,
                          pos: entry.key,
                        ),
                    ];
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) {
                        final pos = geo.offsetToPos(details.localPosition);
                        if (pos != null) _tapPoint(pos);
                      },
                      child: CustomPaint(
                        key: const ValueKey('editor-board'),
                        size: Size(geo.boardWidth, geo.boardHeight),
                        painter: ChessBoardPainter(
                          pieces: pieces,
                          chars: chars,
                          selected: null,
                          targets: const <String>[],
                          lastMove: null,
                          checkKingPos: null,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            _buildHint(),
            _buildPalette(chars),
            _buildSideRow(),
            _buildButtons(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHint() {
    return SmallHint(
      text: tr('选择棋子后点击交叉点放置/替换；未选时点击棋子移除'),
    );
  }

  Widget _buildPalette(PieceChars chars) {
    const order = <String>['r', 'n', 'b', 'c', 'a', 'p', 'k'];
    Widget chip(String code) {
      final selected = _palette == code;
      final isRed = code == code.toUpperCase();
      return GestureDetector(
        key: ValueKey('editor-palette-$code'),
        onTap: () => setState(() => _palette = selected ? null : code),
        child: Container(
          width: 44,
          height: 44,
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFF3E3C3),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : (isRed ? const Color(0xFFC62828) : const Color(0xFF2B2B2B)),
              width: selected ? 3 : 2,
            ),
            boxShadow: const <BoxShadow>[
              BoxShadow(blurRadius: 2, offset: Offset(0, 1)),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            chars.of(code),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: isRed ? const Color(0xFFC62828) : const Color(0xFF2B2B2B),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              for (final kind in order) chip(kind.toUpperCase()),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[for (final kind in order) chip(kind)],
          ),
        ],
      ),
    );
  }

  Widget _buildSideRow() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: <Widget>[
          Text(tr('先行方'), style: theme.textTheme.bodySmall),
          const SizedBox(width: 8),
          Expanded(
            child: SegmentedButton<int>(
              key: const ValueKey('editor-side'),
              segments: <ButtonSegment<int>>[
                ButtonSegment<int>(value: 0, label: Text(tr('红先'))),
                ButtonSegment<int>(value: 1, label: Text(tr('黑先'))),
              ],
              selected: <int>{_side},
              onSelectionChanged: (s) => setState(() => _side = s.first),
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: WidgetStatePropertyAll<TextStyle>(
                  theme.textTheme.bodySmall ?? const TextStyle(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildButtons(BuildContext context) {
    Widget button(String label, VoidCallback onTap, {String? keyValue}) {
      return Padding(
        padding: const EdgeInsets.all(4),
        child: OutlinedButton(
          key: keyValue == null ? null : ValueKey(keyValue),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(72, 40),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          onPressed: onTap,
          child: Text(label),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              button(tr('还原'), _restore, keyValue: 'editor-restore'),
              button(tr('清空'), _clearAll, keyValue: 'editor-clear'),
              button(tr('初始'), _initial, keyValue: 'editor-initial'),
              button(tr('换边'), _swapSides, keyValue: 'editor-swap'),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              button(
                _undoStack.isEmpty ? tr('撤消') : '${tr('撤消')}(${_undoStack.length})',
                _undo,
                keyValue: 'editor-undo',
              ),
              button(tr('翻转'), _flipBoard, keyValue: 'editor-flip'),
              button(
                tr('完成'),
                () => _finish(),
                keyValue: 'editor-done',
              ),
              button(
                tr('返回'),
                () => Navigator.of(context).pop(),
                keyValue: 'editor-back',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
