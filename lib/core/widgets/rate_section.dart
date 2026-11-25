import 'package:flutter/material.dart';

import 'collapse_card.dart';
import 'rate_table.dart';

/// 可折叠的「五险一金比例」编辑卡片，默认收起，节省纵向空间。
///
/// 折叠交互完全复用 [CollapseCard]，这里只负责装配比例表。
class RateSection extends StatelessWidget {
  const RateSection({
    super.key,
    required this.personal,
    required this.employer,
    required this.title,
    this.onChanged,
    this.actions,
    this.initiallyExpanded = false,
    this.dense = false,
    this.subtitle,
  });

  final Map<String, TextEditingController> personal;
  final Map<String, TextEditingController> employer;
  final String title;
  final String? subtitle;

  /// 输入变化回调（计算器页用于实时重算）。
  final VoidCallback? onChanged;

  /// 标题右侧的额外操作（如「用城市默认」）。
  final List<Widget>? actions;

  /// 是否默认展开（独立设置页可传 true）。
  final bool initiallyExpanded;

  /// 紧凑排布（工资计算器等字段密集的页面）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return CollapseCard(
      title: title,
      subtitle: subtitle,
      actions: actions,
      initiallyExpanded: initiallyExpanded,
      dense: dense,
      children: <Widget>[
        RateTable(
          personal: personal,
          employer: employer,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
