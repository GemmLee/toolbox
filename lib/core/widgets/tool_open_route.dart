import 'package:flutter/material.dart';

/// 打开工具页的进场动效：淡入 + 从 0.97 轻微放大 + 向上 6% 高度滑入。
///
/// 时间刻意短（300ms，退出 220ms）：工具页是高频入口，动效只负责让
/// 「点的是这张卡、打开的是这一页」在视觉上连起来，不能让人等。
/// 系统开启「移除动画」时直接跳过，不做无意义的过渡。
class ToolOpenRoute<T> extends PageRouteBuilder<T> {
  ToolOpenRoute({
    required WidgetBuilder builder,
    super.settings,
  }) : super(
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 220),
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
              return child;
            }
            // 位移与缩放共用一条前快后缓的曲线；淡入单独用更短的区间，
            // 免得整段过渡都蒙着一层灰。
            final move = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            final fade = CurvedAnimation(
              parent: animation,
              curve: const Interval(0, 0.7, curve: Curves.easeOut),
            );
            return FadeTransition(
              opacity: fade,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.03),
                  end: Offset.zero,
                ).animate(move),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.97, end: 1).animate(move),
                  child: child,
                ),
              ),
            );
          },
        );
}
