import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import '../logic/quiz_photo_match.dart';

/// 应用内降级浮窗：系统悬浮窗授权失败 / 被 ROM 拦截时用它顶上。
///
/// 交互与系统悬浮窗保持一致：自绘键盘（不弹系统输入法）、
/// 只有四向箭头把手能拖动、键盘与结果面板同一个容器切换。
class InAppQuickSearch extends StatefulWidget {
  const InAppQuickSearch({
    super.key,
    required this.repo,
    required this.onClose,
    this.bankId,
    this.bankIds,
    this.matcher,
  });

  final QuizRepository repo;
  final VoidCallback onClose;

  /// 只在这个题库里搜（null = 全部题库）；兼容老调用方。
  final String? bankId;

  /// 只在这些题库里搜（空集合 / null = 全部题库），优先于 [bankId]。
  final Set<String>? bankIds;

  final Future<PhotoMatch?> Function(QuizRepository repo, String text)? matcher;

  @override
  State<InAppQuickSearch> createState() => _InAppQuickSearchState();
}

class _InAppQuickSearchState extends State<InAppQuickSearch> {
  static const List<List<String>> _rows = <List<String>>[
    <String>['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    <String>['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    <String>['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    <String>['z', 'x', 'c', 'v', 'b', 'n', 'm'],
  ];

  final TextEditingController _input = TextEditingController();
  Offset _offset = const Offset(24, 96);
  bool _showKeyboard = true;
  bool _busy = false;
  PhotoMatch? _match;

  @override
  void didUpdateWidget(covariant InAppQuickSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了搜索题库：上一条结果不再属于当前范围，先清掉等用户重搜。
    final changed = widget.bankIds == null
        ? oldWidget.bankId != widget.bankId
        : oldWidget.bankIds == null ||
            oldWidget.bankIds!.length != widget.bankIds!.length ||
            !oldWidget.bankIds!.containsAll(widget.bankIds!);
    if (changed) _match = null;
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    final matcher = widget.matcher ??
        ((repo, text) => bestMatchForText(
              repo,
              text,
              bankId: widget.bankId,
              bankIds: widget.bankIds,
            ));
    final match = await matcher(widget.repo, text);
    if (!mounted) return;
    setState(() {
      _match = match;
      _busy = false;
      _showKeyboard = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            (constraints.maxWidth - 32).clamp(260.0, 330.0).toDouble();
        return Stack(
          children: <Widget>[
            Positioned(
              left: _offset.dx,
              top: _offset.dy,
              child: SizedBox(
                width: width,
                child: _panel(context),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _panel(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface.withOpacity(0.97),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withOpacity(0.22),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: _searchBox(context),
            ),
            if (_showKeyboard) _keyboard(context) else _result(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 36,
      child: Row(
        children: <Widget>[
          // 顶部中间整条都能拖动（不再画四向箭头）。
          Expanded(
            child: GestureDetector(
              key: const ValueKey('inapp-quick-drag'),
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) {
                setState(() {
                  _offset += details.delta;
                  final size = MediaQuery.sizeOf(context);
                  _offset = Offset(
                    _offset.dx.clamp(0.0, size.width - 80),
                    _offset.dy.clamp(0.0, size.height - 120),
                  );
                });
              },
              child: Center(
                child: Container(
                  width: 34,
                  height: 4,
                  margin: const EdgeInsets.only(left: 34),
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('inapp-quick-close'),
            iconSize: 20,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            visualDensity: VisualDensity.compact,
            tooltip: tr('关闭'),
            onPressed: widget.onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  /// 应用内浮窗本来就在 Flutter 里，中文可以直接借系统输入法：弹一个输入框就好。
  Future<void> _openChineseInput() async {
    final controller = TextEditingController(text: _input.text);
    controller.selection =
        TextSelection.collapsed(offset: controller.text.length);
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('输入关键词')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('输入题干关键词，如 三次握手')),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            key: const ValueKey('inapp-quick-chinese-ok'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(tr('确定')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || !mounted) return;
    setState(() => _input.text = text.trim());
  }

  Widget _searchBox(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GestureDetector(
      onTap: () => setState(() => _showKeyboard = true),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withOpacity(0.7),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.search, size: 17, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _input.text.isEmpty ? tr('输入题干关键词，如 三次握手') : _input.text,
                key: const ValueKey('inapp-quick-input'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _input.text.isEmpty
                      ? scheme.onSurfaceVariant
                      : scheme.onSurface,
                ),
              ),
            ),
            if (_input.text.isNotEmpty)
              GestureDetector(
                onTap: () => setState(() {
                  _input.clear();
                  _match = null;
                }),
                child: Icon(Icons.cancel,
                    size: 16, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  void _append(String ch) {
    if (_input.text.length >= 40) return;
    setState(() => _input.text = _input.text + ch);
  }

  void _backspace() {
    if (_input.text.isEmpty) return;
    setState(() {
      _input.text = _input.text.substring(0, _input.text.length - 1);
    });
  }

  Widget _keyboard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final row in _rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: <Widget>[
                  for (final key in row) _key(context, key, () => _append(key)),
                  if (row.length < 10) const Spacer(),
                  if (row.last == 'm')
                    _actionKey(
                      context,
                      icon: Icons.backspace_outlined,
                      onTap: _backspace,
                    ),
                ],
              ),
            ),
          const SizedBox(height: 2),
          SizedBox(
            height: 34,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 46,
                  child: OutlinedButton(
                    key: const ValueKey('inapp-quick-chinese'),
                    onPressed: _openChineseInput,
                    style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                    child:
                        Text(tr('中/英'), style: const TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('inapp-quick-go'),
                    onPressed: _busy ? null : _search,
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      backgroundColor: const Color(0xFF34C759),
                    ),
                    child: Text(
                      tr('搜索'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 62,
                  child: OutlinedButton(
                    key: const ValueKey('inapp-quick-collapse'),
                    onPressed: () async {
                      await _search();
                    },
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      foregroundColor: scheme.onSurfaceVariant,
                    ),
                    child: Text(tr('收起'), style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _key(BuildContext context, String label, VoidCallback onTap) {
    final theme = Theme.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: SizedBox(
          height: 34,
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              backgroundColor:
                  theme.colorScheme.surfaceContainerHighest.withOpacity(0.6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
              ),
            ),
            child: Text(
              label.toUpperCase(),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionKey(
    BuildContext context, {
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1.5),
      child: SizedBox(
        height: 34,
        width: 44,
        child: TextButton(
          key: const ValueKey('inapp-quick-backspace'),
          onPressed: onTap,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            backgroundColor: const Color(0xFF34C759),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          child: Icon(icon, size: 16, color: Colors.white),
        ),
      ),
    );
  }

  Widget _result(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    // 答案与正确选项用主题主色（蓝）高亮，绿色只留给搜索按钮，
    // 避免浮窗里「绿色」既代表按钮又代表答案。
    final correctBg = dark
        ? scheme.primary.withOpacity(0.24)
        : scheme.primary.withOpacity(0.12);
    final correctFg = dark ? const Color(0xFF8AB4F8) : scheme.primary;
    final match = _match;
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(12, 4, 12, 16),
        child: LinearProgressIndicator(),
      );
    }
    if (match == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                tr('没有匹配到题目'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _showKeyboard = true),
              child: Text(tr('改词')),
            ),
          ],
        ),
      );
    }
    final question = match.question;
    final answers = question.answer.map((a) => a.toLowerCase()).toSet();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            question.stem,
            key: const ValueKey('inapp-quick-stem'),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          for (final option in question.options.take(4))
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: answers.contains(option.key.toLowerCase())
                      ? correctBg
                      : null,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  optionLabelOf(question, option),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.35,
                    color: answers.contains(option.key.toLowerCase())
                        ? correctFg
                        : null,
                    fontWeight: answers.contains(option.key.toLowerCase())
                        ? FontWeight.w700
                        : null,
                  ),
                ),
              ),
            ),
          if (answers.isNotEmpty)
            Text(
              '${tr('答案')}：${answerLabelOf(question)}',
              key: const ValueKey('inapp-quick-answer'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: correctFg,
                fontWeight: FontWeight.w700,
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('inapp-quick-edit'),
              onPressed: () => setState(() => _showKeyboard = true),
              child: Text(tr('改词')),
            ),
          ),
        ],
      ),
    );
  }
}
