import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'settings/theme_palette.dart';

/// 设计令牌：圆角与间距统一在这里取值，避免各页面各写一套。
abstract final class AppTokens {
  static const double radiusXs = 8;
  static const double radiusSm = 12;
  static const double radiusMd = 14;
  static const double radiusLg = 18;
  static const double radiusXl = 24;

  static const double gapXs = 4;
  static const double gapSm = 8;
  static const double gapMd = 12;
  static const double gapLg = 16;
  static const double gapXl = 24;

  /// 卡片描边：比 outlineVariant 更淡，只做「分界」不做「框」。
  static Color hairline(ColorScheme scheme) =>
      scheme.outlineVariant.withOpacity(0.9);

  /// 悬浮投影：低透明度、大模糊，模拟自然光而不是硬阴影。
  static List<BoxShadow> softShadow(bool isDark) => <BoxShadow>[
        BoxShadow(
          color: Colors.black.withOpacity(isDark ? 0.32 : 0.05),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ];
}

/// 全局主题：Material 3 + 可配置 seed 色 + 深浅色跟随设置。
///
/// 与「直接用 `ColorScheme.fromSeed`」的区别：
/// 1. 用 [DynamicSchemeVariant.fidelity] 生成，主题色更接近用户点选的颜色；
/// 2. 中性色（surface / outline）都向 seed 轻染 2%~7%，避免默认的中性灰
///    让界面显得发灰、发冷；
/// 3. `onPrimary` / `onSecondary` 等按对比度自动取深/浅，保证 WCAG AA；
/// 4. 卡片、按钮、输入框、导航栏的圆角与描边统一在 [AppTokens] 内取。
class AppTheme {
  AppTheme._();

  static Color get seed => ThemePalette.byId(ThemePalette.defaultId).color;

  static ThemeData light([Color? seedColor]) =>
      _build(Brightness.light, seedColor ?? seed);

  static ThemeData dark([Color? seedColor]) =>
      _build(Brightness.dark, seedColor ?? seed);

  /// 对外暴露，便于测试里核对配色（对比度、深浅）。
  static ColorScheme schemeFor(Color seed, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final base = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      contrastLevel: 0.0,
    );
    Color tint(Color color, double amount) => Color.lerp(color, seed, amount)!;

    final surface = isDark
        ? tint(const Color(0xFF16181D), 0.07)
        : tint(const Color(0xFFFFFFFF), 0.012);
    final surfaceLow = isDark
        ? tint(const Color(0xFF1B1E24), 0.06)
        : tint(const Color(0xFFF7F9FC), 0.02);
    final surfaceContainer = isDark
        ? tint(const Color(0xFF1F232A), 0.06)
        : tint(const Color(0xFFF2F4F9), 0.022);
    final surfaceHigh = isDark
        ? tint(const Color(0xFF252932), 0.055)
        : tint(const Color(0xFFEBEEF5), 0.022);
    final surfaceHighest = isDark
        ? tint(const Color(0xFF2C313B), 0.05)
        : tint(const Color(0xFFE3E7EF), 0.022);

    final onSurface = isDark
        ? tint(const Color(0xFFEAECF1), 0.02)
        : tint(const Color(0xFF15171C), 0.015);
    final onSurfaceVariant = isDark
        ? tint(const Color(0xFFA9AFBB), 0.05)
        : tint(const Color(0xFF59606A), 0.06);
    final outline = isDark
        ? tint(const Color(0xFF454B55), 0.05)
        : tint(const Color(0xFFC4C9D3), 0.06);
    final outlineVariant = isDark
        ? tint(const Color(0xFF2E333C), 0.045)
        : tint(const Color(0xFFE1E5ED), 0.05);

    return base.copyWith(
      primary: base.primary,
      onPrimary: readableOn(base.primary),
      primaryContainer: base.primaryContainer,
      onPrimaryContainer: base.onPrimaryContainer,
      secondary: base.secondary,
      onSecondary: readableOn(base.secondary),
      tertiary: base.tertiary,
      onTertiary: readableOn(base.tertiary),
      surface: surface,
      onSurface: onSurface,
      onSurfaceVariant: onSurfaceVariant,
      surfaceDim: isDark ? tint(const Color(0xFF101216), 0.05) : surfaceHigh,
      surfaceBright: isDark ? surfaceHigh : Colors.white,
      surfaceContainerLowest:
          isDark ? tint(const Color(0xFF111318), 0.05) : Colors.white,
      surfaceContainerLow: surfaceLow,
      surfaceContainer: surfaceContainer,
      surfaceContainerHigh: surfaceHigh,
      surfaceContainerHighest: surfaceHighest,
      outline: outline,
      outlineVariant: outlineVariant,
      surfaceTint: Colors.transparent,
      inverseSurface: isDark ? const Color(0xFFE7EAEF) : const Color(0xFF24282F),
      onInverseSurface:
          isDark ? const Color(0xFF15171C) : const Color(0xFFF4F6FA),
    );
  }

  static ThemeData _build(Brightness brightness, Color seedColor) {
    final scheme = schemeFor(seedColor, brightness);
    final isDark = brightness == Brightness.dark;
    final text = _textTheme(scheme);
    // 页面底色：比卡片更深一档，卡片才能「浮」在背景上。
    final canvas = isDark
        ? Color.lerp(const Color(0xFF0E1014), seedColor, 0.05)!
        : Color.lerp(const Color(0xFFF4F6FA), seedColor, 0.025)!;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: text,
      scaffoldBackgroundColor: canvas,
      canvasColor: scheme.surface,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withOpacity(0.85),
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        iconTheme: IconThemeData(color: scheme.onSurface, size: 22),
        actionsIconTheme: IconThemeData(color: scheme.onSurface, size: 22),
        titleTextStyle: text.titleLarge?.copyWith(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        systemOverlayStyle: (isDark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark)
            .copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: canvas,
          systemNavigationBarIconBrightness:
              isDark ? Brightness.light : Brightness.dark,
        ),
      ),
      cardTheme: CardTheme(
        elevation: isDark ? 0 : 1.5,
        shadowColor: Colors.black.withOpacity(isDark ? 0.4 : 0.10),
        surfaceTintColor: Colors.transparent,
        color: scheme.surface,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          side: BorderSide(
            color: scheme.outlineVariant.withOpacity(isDark ? 0.5 : 0.85),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: isDark ? scheme.surfaceContainerHigh : scheme.surfaceContainer,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withOpacity(0.75),
        ),
        labelStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        floatingLabelStyle: text.bodyMedium?.copyWith(color: scheme.primary),
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: BorderSide(color: scheme.error, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: BorderSide(color: scheme.error, width: 1.4),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 66,
        elevation: 0,
        backgroundColor: scheme.surface.withOpacity(isDark ? 0.86 : 0.9),
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withOpacity(isDark ? 0.24 : 0.13),
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: selected ? 23 : 22,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return (selected ? text.labelMedium : text.labelMedium)?.copyWith(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 46),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
          textStyle: text.labelLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
          textStyle: text.labelLarge?.copyWith(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          foregroundColor: scheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
          textStyle: text.labelLarge?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      chipTheme: ChipThemeData.fromDefaults(
        brightness: brightness,
        secondaryColor: scheme.primary,
        labelStyle: text.labelMedium ?? const TextStyle(),
      ).copyWith(
        backgroundColor: scheme.surface,
        selectedColor: scheme.primary.withOpacity(isDark ? 0.24 : 0.12),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
        ),
        showCheckmark: false,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        labelStyle: text.labelMedium?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        subtitleTextStyle: text.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        minVerticalPadding: 6,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.primary.withOpacity(0.16),
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withOpacity(0.12),
        valueIndicatorColor: scheme.primary,
        valueIndicatorTextStyle: text.labelMedium?.copyWith(
          color: scheme.onPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            // 浅色主题色（蜜蜂黄等）上白色滑块会糊成一片，按对比度取前景。
            return readableOn(scheme.primary);
          }
          return isDark ? scheme.outline : Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return scheme.surfaceContainerHighest;
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: isDark ? scheme.primary : scheme.inversePrimary,
        elevation: 3,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: Colors.black.withOpacity(isDark ? 0.5 : 0.16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusXl),
        ),
        titleTextStyle: text.titleLarge?.copyWith(fontSize: 18),
        contentTextStyle: text.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppTokens.radiusXl),
          ),
        ),
        dragHandleColor: scheme.outlineVariant,
        showDragHandle: true,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shadowColor: Colors.black.withOpacity(isDark ? 0.5 : 0.14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd + 2),
        ),
        textStyle: text.bodyMedium,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.primary.withOpacity(0.15),
        circularTrackColor: scheme.primary.withOpacity(0.12),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withOpacity(0.22),
        selectionHandleColor: scheme.primary,
      ),
    );
  }

  /// 中文界面需要更松的行高、更小的字间距。
  static TextTheme _textTheme(ColorScheme scheme) {
    final base = Typography.material2021().black.apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        );
    return base.copyWith(
      headlineSmall: base.headlineSmall?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        height: 1.28,
        letterSpacing: -0.2,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        height: 1.3,
        letterSpacing: 0,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
        height: 1.35,
        letterSpacing: 0,
      ),
      titleSmall: base.titleSmall?.copyWith(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        height: 1.35,
        letterSpacing: 0.1,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        fontSize: 15,
        height: 1.55,
        letterSpacing: 0,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        fontSize: 13.8,
        height: 1.55,
        letterSpacing: 0,
      ),
      bodySmall: base.bodySmall?.copyWith(
        fontSize: 12.2,
        height: 1.45,
        letterSpacing: 0,
      ),
      labelLarge: base.labelLarge?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      labelSmall: base.labelSmall?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
      ),
    );
  }

  /// 前景色自动取深/浅，保证文字与底色的对比度。
  ///
  /// [base] 用于半透明填充色（如 `Colors.red.withOpacity(0.38)`）：先把它
  /// 合成到实际底色上再算亮度，否则 `computeLuminance()` 会忽略 alpha 而误判，
  /// 导致深色块上仍然给黑色文字。深色块自动返回白色，浅色块返回深色。
  static Color readableOn(
    Color background, {
    Color light = Colors.white,
    Color dark = const Color(0xFF14161B),
    Color? base,
  }) {
    final bg = (base != null && background.alpha < 255)
        ? Color.alphaBlend(background, base)
        : background;
    return contrast(bg, light) >= contrast(bg, dark) ? light : dark;
  }

  /// WCAG 对比度（1~21）。
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = math.max(la, lb);
    final lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }
}
