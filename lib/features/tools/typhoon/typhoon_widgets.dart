import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import 'typhoon_geo.dart';
import 'typhoon_map.dart';

/// 台风播报页共用的小组件（列表与详情都用到，或仅一处使用但体量独立）。

/// 预警等级徽章：白 / 蓝 / 黄 / 橙 / 红。
class TyphoonWarnBadge extends StatelessWidget {
  const TyphoonWarnBadge({super.key, required this.level});

  final String level;

  static const Map<String, Color> _colors = <String, Color>{
    'white': Colors.grey,
    'blue': Colors.blue,
    'yellow': Colors.amber,
    'orange': Colors.orange,
    'red': Colors.red,
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[level.toLowerCase()] ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${tr('预警')}${level.toUpperCase()}',
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 生命周期最大强度徽章：仅对达到「强台风」及以上的台风显示。
class TyphoonStrengthBadge extends StatelessWidget {
  const TyphoonStrengthBadge({super.key, required this.strength});

  final TyphoonStrength strength;

  @override
  Widget build(BuildContext context) {
    final color = typhoonStrengthColor(
      strength,
      dark: Theme.of(context).brightness == Brightness.dark,
    );
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        tr(strengthLabel(strength)),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 加载失败占位：错误信息 + 重试。
class TyphoonErrorCard extends StatelessWidget {
  const TyphoonErrorCard({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(tr('重试')),
              ),
            ],
          ),
        ),
      );
}

/// 该年度没有台风记录。
class TyphoonEmptyCard extends StatelessWidget {
  const TyphoonEmptyCard({super.key, required this.year});

  final int year;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '$year${tr('年暂无台风记录')}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
}

/// 图例：单色圆点 + 文案。
class LegendDot extends StatelessWidget {
  const LegendDot({super.key, required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

/// 图例：多色渐变线段（路径按强度着色）。
class LegendGradient extends StatelessWidget {
  const LegendGradient({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 3,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: LinearGradient(
                colors: [
                  for (final s in kLegendStrengths) typhoonStrengthColor(s),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}
