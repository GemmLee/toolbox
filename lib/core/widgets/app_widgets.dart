import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/tool_texts.dart';

/// 轻提示：统一去重、时长与 mounted 保护。
void showToast(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ));
}

/// 复制文本到剪贴板并提示。
Future<void> copyWithToast(
  BuildContext context,
  String text, {
  String? toast,
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showToast(context, toast ?? tr('已复制'));
}

/// 通用分区卡片。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.dense = false,
    required this.children,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  /// 紧凑排布：内边距与标题下的留白一起收窄，用于字段多、需要一屏看完的页面。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: dense
            ? const EdgeInsets.fromLTRB(14, 10, 14, 12)
            : const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            SizedBox(height: dense ? 10 : 14),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// 数字输入框，统一键盘类型与输入过滤。
class NumberField extends StatelessWidget {
  const NumberField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.suffix,
    this.helper,
    this.onChanged,
    this.enabled = true,
    this.outerPadding = const EdgeInsets.only(bottom: 12),
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? suffix;
  final String? helper;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final EdgeInsetsGeometry outerPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: outerPadding,
      child: TextField(
        controller: controller,
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixText: suffix,
          helperText: helper,
          helperMaxLines: 2,
        ),
      ),
    );
  }
}

/// 带左右加减号的数字微调输入框：点一下按 [step] 增减，也可以直接输入。
///
/// 用于题目数量、答对次数这类需要「微调一两格」的场合；[fieldKey] 传给内部
/// TextField，方便 widget 测试沿用原来的 `count-xxx` key。
class NumberStepField extends StatefulWidget {
  const NumberStepField({
    super.key,
    required this.controller,
    required this.fieldKey,
    this.onChanged,
    this.min = 0,
    this.max = 9999,
    this.step = 1,
    this.width = 128,
    this.hint = '0',
    this.stepKeyPrefix,
    this.allowDecimal = false,
  });

  final TextEditingController controller;
  final Key fieldKey;
  final ValueChanged<String>? onChanged;
  final double min;
  final double max;
  final double step;
  final double width;
  final String hint;

  /// 传入后，加减按钮会带 `$prefix-minus` / `$prefix-plus` 两个 key。
  final String? stepKeyPrefix;
  final bool allowDecimal;

  @override
  State<NumberStepField> createState() => _NumberStepFieldState();
}

class _NumberStepFieldState extends State<NumberStepField> {
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_syncFocus);
  }

  void _syncFocus() {
    final hasFocus = _focus.hasFocus;
    if (_focused != hasFocus) setState(() => _focused = hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_syncFocus);
    _focus.dispose();
    super.dispose();
  }

  void _step(double delta) {
    final parsed = double.tryParse(widget.controller.text.trim());
    final base = parsed ?? widget.min;
    final value = (base + delta).clamp(widget.min, widget.max);
    final text = _format(value);
    if (text == widget.controller.text) return;
    widget.controller
      ..text = text
      ..selection = TextSelection.collapsed(offset: text.length);
    widget.onChanged?.call(text);
  }

  String _format(double value) {
    if (widget.allowDecimal && value != value.roundToDouble()) {
      return value.toStringAsFixed(1);
    }
    final n = value.round();
    return (widget.min > 0 || n > 0) ? '$n' : '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: widget.width,
      height: 38,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _button(Icons.remove, -widget.step),
          Expanded(
            child: TextField(
              key: widget.fieldKey,
              controller: widget.controller,
              focusNode: _focus,
              keyboardType: TextInputType.numberWithOptions(
                decimal: widget.allowDecimal,
              ),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(
                  RegExp(widget.allowDecimal ? r'[0-9.]' : r'[0-9]'),
                ),
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: InputDecoration(
                isDense: true,
                hintText: _focused ? null : widget.hint,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: const OutlineInputBorder(),
              ),
              onChanged: widget.onChanged,
            ),
          ),
          _button(Icons.add, widget.step),
        ],
      ),
    );
  }

  Widget _button(IconData icon, double delta) {
    return SizedBox(
      width: 34,
      height: 42,
      child: IconButton(
        key: widget.stepKeyPrefix == null
            ? null
            : ValueKey<String>(
                '${widget.stepKeyPrefix}-${delta < 0 ? 'minus' : 'plus'}',
              ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 34, height: 42),
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        icon: Icon(icon),
        onPressed: () => _step(delta),
      ),
    );
  }
}

/// 结果行：左侧标签，右侧数值（可带副标题）。
class StatRow extends StatelessWidget {
  const StatRow({
    super.key,
    required this.label,
    required this.value,
    this.secondary,
    this.emphasize = false,
    this.valueColor,
    this.flexibleValue = false,
  });

  final String label;
  final String value;
  final String? secondary;
  final bool emphasize;
  final Color? valueColor;

  /// 长值（IP 列表、情报来源等）允许换行，避免把左侧标签挤成一个字一行。
  final bool flexibleValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: emphasize ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (secondary != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      secondary!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (flexibleValue)
            Flexible(
              flex: 1,
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
                  color: valueColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            )
          else
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
                color: valueColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

/// 轻提示条。
class HintBanner extends StatelessWidget {
  const HintBanner({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.color,
  });

  final String text;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tone = color ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tone.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: tone,
                    height: 1.45,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 说明气泡：默认只显示一个感叹号图标，点开才展示完整说明。
/// 用于收纳不影响操作、但偶尔需要查阅的长文案，避免页面被小字注释占满。
///
/// 只放在「说明主体旁边」：AppBar actions、卡片 / 折叠卡的 trailing、标题行
/// 末尾、输入框 suffixIcon 等。不要作为 ListView / Column 里单独占一行的
/// 子项，也不要把一行放得下的短说明改成气泡——那种情况用 [SmallHint]。
class InfoHint extends StatelessWidget {
  const InfoHint({
    super.key,
    required this.text,
    this.title,
    this.color,
    this.icon = Icons.info_outline,
  });

  final String text;
  final String? title;
  final Color? color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tone = color ?? Theme.of(context).colorScheme.primary;
    return IconButton(
      icon: Icon(icon, size: 19, color: tone),
      tooltip: tr('说明'),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      visualDensity: VisualDensity.compact,
      onPressed: () => showInfoHint(context, text, title: title),
    );
  }
}

/// 常驻的一行小字说明：短促提示用这个，样式统一、不占中间位置。
/// 只有需要折叠的长说明才用 [InfoHint]，且气泡应放在标题 / 输入框 / 卡片
/// 主体旁边，不要作为内容流里单独占一行的子项。
class SmallHint extends StatelessWidget {
  const SmallHint({
    super.key,
    required this.text,
    this.maxLines = 2,
    this.color,
    this.textAlign,
  });

  final String text;
  final int maxLines;

  /// 警告 / 错误态可覆写颜色，其余保持弱化色。
  final Color? color;

  /// 居中空态里可传 TextAlign.center。
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
      style: theme.textTheme.bodySmall?.copyWith(
        color: color ?? theme.colorScheme.onSurfaceVariant,
        height: 1.35,
      ),
    );
  }
}

/// 点开 [InfoHint] 后弹出的说明内容；点遮罩或「关闭」即可收起。
Future<void> showInfoHint(
  BuildContext context,
  String text, {
  String? title,
}) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.info_outline,
            color: Theme.of(context).colorScheme.primary),
        title: title == null ? null : Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(child: Text(text)),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('关闭')),
          ),
        ],
      ),
    );

/// 通用空态 / 错误态占位：图标 + 标题（可选）+ 说明 + 操作（可选）。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.text,
    this.title,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String text;
  final String? title;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            if (title != null) ...[
              Text(
                title!,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
            ],
            Text(
              text,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 统计小格：默认数值在上、标签在下（用于得分、正确率、存储占用等）。
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.value,
    required this.label,
    this.valueColor,
    this.compact = false,
    this.labelFirst = false,
  });

  final String value;
  final String label;
  final Color? valueColor;

  /// 紧凑模式：数值用小号字（详情页多列场景）。
  final bool compact;

  /// 标签在上、数值在下并左对齐（设备状态等「键值对」式多列布局）。
  final bool labelFirst;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle =
        (compact ? theme.textTheme.bodySmall : theme.textTheme.titleMedium)
            ?.copyWith(
      fontWeight: FontWeight.w700,
      color: valueColor,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final labelText = Text(
      label,
      textAlign: labelFirst ? TextAlign.start : TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(
        fontSize: compact ? 11 : null,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final valueText = Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: valueStyle,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          labelFirst ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: labelFirst
          ? <Widget>[labelText, const SizedBox(height: 2), valueText]
          : <Widget>[valueText, const SizedBox(height: 2), labelText],
    );
  }
}
