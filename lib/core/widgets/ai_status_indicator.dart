/// AI 状态动画：用不同的视觉区分「等待响应」「正在接收」「上传/处理中」。
///
/// 纯 AnimatedWidget 手写，无第三方依赖。三处 AI 场景（助手、AI 解析、
/// 题库转换）共用，避免各自手搓静态转圈导致语义不一致。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 三个依次跳动的圆点：等待 AI 开始返回（类比 GPT 的思考动画）。
class AiThinkingDots extends StatefulWidget {
  const AiThinkingDots({
    super.key,
    this.color,
    this.size = 6,
    this.keyPrefix = 'ai-dots',
  });

  final Color? color;
  final double size;
  final String keyPrefix;

  @override
  State<AiThinkingDots> createState() => _AiThinkingDotsState();
}

class _AiThinkingDotsState extends State<AiThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          key: ValueKey('${widget.keyPrefix}-row'),
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(3, (i) {
            // 每颗点相位错开 1/3 周期，用 sin 让高度做平滑起伏。
            final phase = (_controller.value + i / 3) % 1.0;
            final lift =
                (0.5 - 0.5 * math.cos(phase * 2 * math.pi)) * widget.size;
            return Container(
              key: ValueKey('${widget.keyPrefix}-$i'),
              margin: EdgeInsets.only(
                  right: i < 2 ? widget.size * 0.6 : 0, bottom: lift),
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: color.withOpacity(0.45 + 0.55 * (lift / widget.size)),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}

/// 闪烁的竖条光标：跟在正在接收的文本后面，表示「正在打字」。
class AiTypingCursor extends StatefulWidget {
  const AiTypingCursor({
    super.key,
    this.color,
    this.height = 14,
    this.width = 2,
  });

  final Color? color;
  final double height;
  final double width;

  @override
  State<AiTypingCursor> createState() => _AiTypingCursorState();
}

class _AiTypingCursorState extends State<AiTypingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Opacity(
        opacity: 0.15 + 0.85 * _controller.value,
        child: Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(widget.width / 2),
          ),
        ),
      ),
    );
  }
}

/// 通用状态动画条：左侧动画 + 右侧文案。
///
/// - [waiting]：跳动三点 + 文案，等待 AI 开始返回。
/// - [streaming]：文本已到，用闪烁光标表示正在接收（文案可选）。
/// - [uploading]：不确定/确定进度条 + 百分比，上传或处理数据。
enum AiVisualState { waiting, streaming, uploading }

class AiStatusIndicator extends StatelessWidget {
  const AiStatusIndicator.waiting({
    super.key,
    this.label,
    this.color,
  })  : state = AiVisualState.waiting,
        progress = null;

  const AiStatusIndicator.uploading({
    super.key,
    this.label,
    this.color,
    this.progress,
  }) : state = AiVisualState.uploading;

  const AiStatusIndicator.streaming({
    super.key,
    this.label,
    this.color,
  })  : state = AiVisualState.streaming,
        progress = null;

  final AiVisualState state;
  final String? label;
  final Color? color;

  /// 上传进度 0~1；null 表示不确定进度。
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.primary;
    final textStyle = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    if (state == AiVisualState.uploading) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 2,
              color: accent,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label ?? '',
              style: textStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(width: 8),
            Text(
              '${(progress! * 100).clamp(0, 100).round()}%',
              style: textStyle,
            ),
          ],
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (state == AiVisualState.waiting)
          AiThinkingDots(color: accent, size: 5)
        else
          AiTypingCursor(color: accent, height: 13),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label ?? '',
            style: textStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
