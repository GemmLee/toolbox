import 'dart:io';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../settings/app_background.dart';

/// 叠在自定义背景上的文字 / 图标应当取的前景色。
///
/// 浅色主题 + 深色自定义图片时，AppBar 标题、状态栏图标与裸露文字如果还按
/// 主题取深色就会看不清。这里由 [AppBackdrop] 按背景实际亮度算出前景色，
/// 页面里用 [foregroundOf] 取值；没有 AppBackdrop 祖先时回退到主题默认色。
class BackdropStyle extends InheritedWidget {
  const BackdropStyle({
    super.key,
    required this.foreground,
    required this.isDark,
    required super.child,
  });

  final Color foreground;
  final bool isDark;

  static BackdropStyle? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BackdropStyle>();

  static Color foregroundOf(BuildContext context, Color fallback) =>
      maybeOf(context)?.foreground ?? fallback;

  static bool isDarkOf(BuildContext context, {bool fallback = false}) =>
      maybeOf(context)?.isDark ?? fallback;

  @override
  bool updateShouldNotify(BackdropStyle oldWidget) =>
      foreground != oldWidget.foreground || isDark != oldWidget.isDark;
}

/// 全屏背景层：底色渐变 + 两团柔光 + 用户选择的纯色 / 渐变 / 图片。
///
/// 设计意图：大面积纯色会让界面显得「塑料感」，所以即使选择「无背景」，
/// 也会用主题色做一层极淡的竖向渐变与两处径向柔光，模拟自然环境光。
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({
    super.key,
    required this.kind,
    required this.colorId,
    required this.gradientId,
    required this.imagePath,
    this.imageLuminance,
    required this.child,
  });

  final BackgroundKind kind;
  final String colorId;
  final String gradientId;
  final String? imagePath;

  /// 自定义背景图的平均线性亮度（0~1）；老版本没有此值时为 null。
  final double? imageLuminance;
  final Widget child;

  bool get _hasImage =>
      kind == BackgroundKind.image &&
      imagePath != null &&
      imagePath!.isNotEmpty &&
      File(imagePath!).existsSync();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final darkBackdrop = _darkBackdrop(theme);
    final onBackdrop = darkBackdrop ? Colors.white : scheme.onSurface;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. 基础层
        if (_hasImage)
          DecoratedBox(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: FileImage(File(imagePath!)),
                fit: BoxFit.cover,
                colorFilter: isDark
                    ? const ColorFilter.mode(
                        Color(0x8C000000), BlendMode.darken)
                    : null,
              ),
            ),
          )
        else
          DecoratedBox(decoration: _baseDecoration(theme, isDark)),

        // 2. 柔光：只在非图片背景上叠加，给平面加一点空气感
        if (!_hasImage) ...[
          _Glow(
            alignment: const Alignment(0.95, -1.05),
            diameter: 440,
            color: scheme.primary,
            opacity: isDark ? 0.20 : 0.13,
          ),
          _Glow(
            alignment: const Alignment(-1.05, 1.1),
            diameter: 520,
            color: scheme.tertiary,
            opacity: isDark ? 0.14 : 0.10,
          ),
        ],

        // 3. 图片背景：上下加一层淡淡的雾，保证标题与底栏可读
        if (_hasImage)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Colors.black.withOpacity(isDark ? 0.28 : 0.16),
                  Colors.transparent,
                  Colors.black.withOpacity(isDark ? 0.22 : 0.10),
                ],
                stops: const <double>[0, 0.32, 1],
              ),
            ),
          ),

        Theme(
          data: theme.copyWith(
            appBarTheme: theme.appBarTheme.copyWith(
              foregroundColor: onBackdrop,
              iconTheme: IconThemeData(color: onBackdrop, size: 22),
              actionsIconTheme: IconThemeData(color: onBackdrop, size: 22),
              titleTextStyle: theme.appBarTheme.titleTextStyle
                  ?.copyWith(color: onBackdrop),
              systemOverlayStyle:
                  theme.appBarTheme.systemOverlayStyle?.copyWith(
                statusBarIconBrightness:
                    darkBackdrop ? Brightness.light : Brightness.dark,
                statusBarBrightness:
                    darkBackdrop ? Brightness.dark : Brightness.light,
              ),
            ),
          ),
          child: BackdropStyle(
            foreground: onBackdrop,
            isDark: darkBackdrop,
            child: child,
          ),
        ),
      ],
    );
  }

  /// 背景是否偏深：偏深时叠在背景上的文字/图标统一取白色。
  ///
  /// 纯色 / 渐变按主题色板亮度判断；自定义图片用选图时采样的平均线性亮度，
  /// 并计入背景层那层黑色雾，所以阈值略放宽到 0.24。
  static bool isDarkBackdrop({
    required BackgroundKind kind,
    required String colorId,
    required String gradientId,
    required bool hasImage,
    required double? imageLuminance,
    required Brightness brightness,
  }) {
    final isDarkTheme = brightness == Brightness.dark;
    switch (kind) {
      case BackgroundKind.color:
        final c = AppBackgrounds.colorById(colorId)?.color;
        if (c == null) return isDarkTheme;
        return AppTheme.readableOn(
              isDarkTheme ? AppBackgrounds.dim(c) : c,
            ) ==
            Colors.white;
      case BackgroundKind.gradient:
        final g = AppBackgrounds.gradientById(gradientId);
        if (g == null) return isDarkTheme;
        final colors = isDarkTheme
            ? g.colors.map(AppBackgrounds.dim).toList()
            : g.colors;
        final average = colors.reduce((a, b) => Color.lerp(a, b, 0.5)!);
        return AppTheme.readableOn(average) == Colors.white;
      case BackgroundKind.image:
        if (!hasImage) return isDarkTheme;
        return imageLuminance == null ? isDarkTheme : imageLuminance < 0.24;
      case BackgroundKind.none:
        return isDarkTheme;
    }
  }

  bool _darkBackdrop(ThemeData theme) => isDarkBackdrop(
        kind: kind,
        colorId: colorId,
        gradientId: gradientId,
        hasImage: _hasImage,
        imageLuminance: imageLuminance,
        brightness: theme.brightness,
      );

  /// 无 / 纯色 / 渐变 三种情况的基础底色。
  BoxDecoration _baseDecoration(ThemeData theme, bool isDark) {
    final canvas = theme.scaffoldBackgroundColor;
    switch (kind) {
      case BackgroundKind.color:
        final c = AppBackgrounds.colorById(colorId);
        if (c == null) break;
        final base = isDark ? AppBackgrounds.dim(c.color) : c.color;
        // 纯色也做一点上下明暗，避免整屏死板
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color.lerp(base, Colors.white, isDark ? 0.02 : 0.16)!,
              base,
              Color.lerp(base, Colors.black, isDark ? 0.16 : 0.04)!,
            ],
          ),
        );
      case BackgroundKind.gradient:
        final g = AppBackgrounds.gradientById(gradientId);
        if (g == null) break;
        final colors = isDark
            ? g.colors.map(AppBackgrounds.dim).toList(growable: false)
            : g.colors;
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
            stops: colors.length == 2
                ? const <double>[0, 1]
                : List<double>.generate(
                    colors.length,
                    (i) => i / (colors.length - 1),
                  ),
          ),
        );
      case BackgroundKind.none:
      case BackgroundKind.image:
        break;
    }

    // 默认：主题色极淡的竖向渐变
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color.alphaBlend(
            theme.colorScheme.primary.withOpacity(isDark ? 0.10 : 0.05),
            canvas,
          ),
          canvas,
          Color.alphaBlend(
            theme.colorScheme.tertiary.withOpacity(isDark ? 0.08 : 0.04),
            canvas,
          ),
        ],
        stops: const <double>[0, 0.42, 1],
      ),
    );
  }
}

/// 一团柔光：径向渐变，边缘完全透明。
class _Glow extends StatelessWidget {
  const _Glow({
    required this.alignment,
    required this.diameter,
    required this.color,
    required this.opacity,
  });

  final Alignment alignment;
  final double diameter;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: SizedBox(
          width: diameter,
          height: diameter,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: <Color>[
                  color.withOpacity(opacity),
                  color.withOpacity(opacity * 0.35),
                  color.withOpacity(0),
                ],
                stops: const <double>[0, 0.55, 1],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
