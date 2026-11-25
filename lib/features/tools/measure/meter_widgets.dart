import 'package:flutter/material.dart';

/// 环境量测量（分贝仪 / 光强计）共用的展示组件。
///
/// 两者版式完全一致——顶部标题 + 分级胶囊、大号读数、电平条、峰值/平均、
/// 开始/停止按钮、错误条、参考值表——只有单位、分级颜色与校准区不同。
/// 这里收口公共布局，两个视图只保留自己的业务差异。

/// 分级胶囊标签，例如「正常」「正常室内」。
class MeterZoneBadge extends StatelessWidget {
  const MeterZoneBadge({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

/// 主读数：大号数值 + 单位，右端可带一句口径说明（如「≈ 估算值」）。
class MeterReading extends StatelessWidget {
  const MeterReading({
    super.key,
    required this.value,
    required this.unit,
    required this.color,
    this.caption,
    this.valueKey,
  });

  /// 已格式化的读数；null 表示尚未开始测量，显示占位横线。
  final String? value;
  final String unit;

  /// 数值颜色（通常跟随分级色）。
  final Color color;
  final String? caption;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final missing = value == null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          missing ? '—' : value!,
          key: valueKey,
          style: theme.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1,
            color: missing ? scheme.outline : color,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 4),
          child: Text(
            unit,
            style: theme.textTheme.titleMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const Spacer(),
        if (!missing && caption != null)
          Text(
            caption!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// 0~1 电平条，带等分刻度（分贝 8 格、光照 6 格）。
class MeterLevelBar extends StatelessWidget {
  const MeterLevelBar({
    super.key,
    required this.level,
    required this.color,
    this.divisions = 8,
  });

  final double level;
  final Color color;
  final int divisions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: 34,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              Container(
                height: 12,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              Container(
                height: 12,
                width: width * level.clamp(0.0, 1.0),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: <Color>[color.withOpacity(0.55), color],
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: MeterScalePainter(
                    scheme: scheme,
                    divisions: divisions,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 电平条上的等分刻度线。
class MeterScalePainter extends CustomPainter {
  MeterScalePainter({required this.scheme, required this.divisions});

  final ColorScheme scheme;
  final int divisions;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = scheme.onSurface.withOpacity(0.18)
      ..strokeWidth = 1;
    for (var i = 0; i <= divisions; i++) {
      final x = size.width * i / divisions;
      canvas.drawLine(
        Offset(x, size.height / 2 - 9),
        Offset(x, size.height / 2 + 9),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant MeterScalePainter oldDelegate) =>
      oldDelegate.divisions != divisions || oldDelegate.scheme != scheme;
}

/// 标签在上、数值在下的紧凑统计（峰值 / 平均）。
class MeterStat extends StatelessWidget {
  const MeterStat({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 传感器不可用 / 无权限时的提示条。
class MeterErrorBanner extends StatelessWidget {
  const MeterErrorBanner({
    super.key,
    required this.icon,
    required this.message,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「常见 xx 参考」表 + 脚注。
class MeterReferenceCard extends StatelessWidget {
  const MeterReferenceCard({
    super.key,
    required this.title,
    required this.rows,
    required this.note,
    this.valueWidth = 66,
  });

  final String title;

  /// 每行 `[数值文本, 说明]`。
  final List<List<String>> rows;
  final String note;

  /// 左列固定宽度，让冒号后面的说明对齐。
  final double valueWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: valueWidth,
                      child: Text(
                        row[0],
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        row[1],
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Text(
              note,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 测量页顶部的标题栏：图标 + 标题 + 右侧分级胶囊。
class MeterHeader extends StatelessWidget {
  const MeterHeader({
    super.key,
    required this.icon,
    required this.title,
    this.badge,
  });

  final IconData icon;
  final String title;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Text(title, style: theme.textTheme.titleSmall),
        const Spacer(),
        if (badge != null) badge!,
      ],
    );
  }
}
