import 'package:flutter/material.dart';

/// 背景类型：无 / 纯色 / 渐变 / 自定义图片。
enum BackgroundKind { none, color, gradient, image }

/// 内置纯色背景（浅色系，深色模式下自动压暗）。
class AppBackgroundColor {
  const AppBackgroundColor(this.id, this.name, this.color);

  final String id;
  final String name;
  final Color color;
}

/// 内置渐变背景。
class AppBackgroundGradient {
  const AppBackgroundGradient(this.id, this.name, this.colors);

  final String id;
  final String name;
  final List<Color> colors;
}

abstract final class AppBackgrounds {
  /// 纯色：偏自然材质（云、沙、瓷、麻），明度都在 95% 以上，
  /// 保证与白色卡片仍有层次，又不会抢前景内容。
  static const List<AppBackgroundColor> colors = <AppBackgroundColor>[
    AppBackgroundColor('cloud', '云雾白', Color(0xFFF6F7FA)),
    AppBackgroundColor('sky', '晴空蓝', Color(0xFFEBF2FF)),
    AppBackgroundColor('mint', '薄荷绿', Color(0xFFEBF7F1)),
    AppBackgroundColor('sand', '暖米杏', Color(0xFFF9F2E7)),
    AppBackgroundColor('sakura', '樱花粉', Color(0xFFFCEFF3)),
    AppBackgroundColor('lilac', '淡紫罗兰', Color(0xFFF2EFFD)),
    AppBackgroundColor('celadon', '青瓷', Color(0xFFEDF6F4)),
    AppBackgroundColor('oat', '燕麦', Color(0xFFF6F2EA)),
  ];

  /// 渐变：三点渐变，中间略亮，像自然光穿过一层薄雾。
  static const List<AppBackgroundGradient> gradients = <AppBackgroundGradient>[
    AppBackgroundGradient(
      'dawn',
      '晨雾',
      <Color>[Color(0xFFE7F0FF), Color(0xFFF5F2FF), Color(0xFFFDF7FF)],
    ),
    AppBackgroundGradient(
      'sunrise',
      '日出',
      <Color>[Color(0xFFFFE9D9), Color(0xFFFFF3E9), Color(0xFFFFFAF4)],
    ),
    AppBackgroundGradient(
      'forest',
      '竹林',
      <Color>[Color(0xFFE3F6EB), Color(0xFFEFFBF4), Color(0xFFF7FDF9)],
    ),
    AppBackgroundGradient(
      'dusk',
      '暮光',
      <Color>[Color(0xFFEDE7FF), Color(0xFFECF1FF), Color(0xFFF5F9FF)],
    ),
    AppBackgroundGradient(
      'seasalt',
      '海盐',
      <Color>[Color(0xFFE3F3F9), Color(0xFFEEFAFD), Color(0xFFF7FDFE)],
    ),
    AppBackgroundGradient(
      'peach',
      '蜜桃',
      <Color>[Color(0xFFFFE8EB), Color(0xFFFFF2F1), Color(0xFFFFF9F4)],
    ),
    AppBackgroundGradient(
      'linen',
      '亚麻',
      <Color>[Color(0xFFF4EFE4), Color(0xFFFAF6EF), Color(0xFFFDFBF6)],
    ),
    AppBackgroundGradient(
      'aurora',
      '极光',
      <Color>[Color(0xFFE5F4F1), Color(0xFFE9F1FD), Color(0xFFF5EEFB)],
    ),
  ];

  static AppBackgroundColor? colorById(String? id) {
    for (final item in colors) {
      if (item.id == id) return item;
    }
    return null;
  }

  static AppBackgroundGradient? gradientById(String? id) {
    for (final item in gradients) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// 深色模式压暗：保留色相，避免整屏发灰。
  static Color dim(Color color) =>
      Color.lerp(color, const Color(0xFF0F1217), 0.86) ?? color;
}
