import 'package:flutter/material.dart';

/// 紧凑分段控件的一段。
class MiniSegmentedOption<T> {
  const MiniSegmentedOption({
    required this.value,
    required this.label,
    this.key,
  });

  final T value;
  final String label;

  /// 落在可选文本上的 key，方便测试直接点某一段。
  final Key? key;
}

/// 轻量分段选择器：把 Material 的 SegmentedButton 换成一颗小胶囊。
///
/// [SegmentedButton] 自带 40dp 高度、两侧大内边距与分割线，放在密集的页面里
/// 一行就吃掉半屏宽。这里按内容宽度排布（或 [expanded] 均分），高度默认 30，
/// 选中段用主色的浅底 + 主色文字，视觉上更像一个开关而不是一排按钮。
class MiniSegmented<T> extends StatelessWidget {
  const MiniSegmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.height = 30,
    this.fontSize = 12.5,
    this.expanded = false,
  });

  final List<MiniSegmentedOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final double height;
  final double fontSize;

  /// true 时各段等分可用宽度；false 时按文字宽度紧凑排列。
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(height / 2);
    final items = <Widget>[];
    for (var i = 0; i < options.length; i++) {
      final option = options[i];
      if (i > 0) {
        items.add(const SizedBox(width: 2));
      }
      final segment = _Segment(
        label: option.label,
        textKey: option.key,
        active: option.value == selected,
        radius: radius,
        fontSize: fontSize,
        onTap: () => onChanged(option.value),
      );
      items.add(expanded ? Expanded(child: segment) : segment);
    }
    return Container(
      height: height,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.onSurface.withOpacity(0.06),
        borderRadius: radius,
      ),
      child: Row(
        mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: items,
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.active,
    required this.radius,
    required this.fontSize,
    required this.onTap,
    this.textKey,
  });

  final String label;
  final bool active;
  final BorderRadius radius;
  final double fontSize;
  final VoidCallback onTap;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: active ? scheme.primary.withOpacity(0.16) : Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Center(
            child: Text(
              label,
              key: textKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                height: 1.1,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
