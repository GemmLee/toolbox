import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../insurance.dart';
import '../settings/tool_texts.dart';

/// 五险一金比例紧凑编辑表：每行「项目 | 个人 % | 单位 %」，下划线输入样式。
///
/// 计算器与个人信息页共用，避免两处维护两套布局。
class RateTable extends StatelessWidget {
  const RateTable({
    super.key,
    required this.personal,
    required this.employer,
    this.onChanged,
  });

  final Map<String, TextEditingController> personal;
  final Map<String, TextEditingController> employer;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
    return Column(
      children: [
        Row(
          children: [
            const Spacer(),
            SizedBox(width: _cellWidth, child: Text(tr('个人 %'), textAlign: TextAlign.center, style: headerStyle)),
            const SizedBox(width: 8),
            SizedBox(width: _cellWidth, child: Text(tr('单位 %'), textAlign: TextAlign.center, style: headerStyle)),
          ],
        ),
        const SizedBox(height: 8),
        for (final item in kInsuranceItems)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(tr(item.name), style: theme.textTheme.bodySmall),
                ),
                SizedBox(width: _cellWidth, child: _cell(context, personal[item.id]!)),
                const SizedBox(width: 8),
                SizedBox(width: _cellWidth, child: _cell(context, employer[item.id]!)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _cell(BuildContext context, TextEditingController controller) {
    final scheme = Theme.of(context).colorScheme;
    InputDecoration underline(Color color, {double width = 1}) =>
        InputDecoration(
          isDense: true,
          filled: false,
          contentPadding: const EdgeInsets.fromLTRB(0, 6, 0, 5),
          border: UnderlineInputBorder(
            borderSide: BorderSide(color: color, width: width),
          ),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: color, width: width),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: scheme.primary, width: 1.3),
          ),
          suffixText: '%',
          suffixStyle: TextStyle(
            fontSize: 10,
            color: scheme.onSurfaceVariant,
          ),
        );
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w500,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      onChanged: onChanged == null ? null : (_) => onChanged!(),
      decoration: underline(scheme.outlineVariant),
    );
  }
}

const double _cellWidth = 82;
