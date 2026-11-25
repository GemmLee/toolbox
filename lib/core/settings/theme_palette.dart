import 'package:flutter/material.dart';

/// 全局主题色板：id 持久化到设置，color 作为 Material seed。
class ThemePaletteEntry {
  const ThemePaletteEntry(this.id, this.name, this.color);

  final String id;
  final String name;
  final Color color;
}

abstract final class ThemePalette {
  static const String defaultId = 'skyBlue';

  static const List<ThemePaletteEntry> all = <ThemePaletteEntry>[
    ThemePaletteEntry('beeYellow', '蜜蜂黄', Color(0xFFF0B429)),
    ThemePaletteEntry('flameOrange', '火焰橙', Color(0xFFF2794B)),
    ThemePaletteEntry('glazeGreen', '琉璃绿', Color(0xFF3E9C8C)),
    ThemePaletteEntry('violet', '青莲紫', Color(0xFF8A5BC4)),
    ThemePaletteEntry('cherryRed', '樱绯红', Color(0xFFE0326E)),
    ThemePaletteEntry('skyBlue', '晴空蓝', Color(0xFF4C7DFF)),
    ThemePaletteEntry('forestMoon', '林间月', Color(0xFF8FD0B2)),
    ThemePaletteEntry('duskDune', '黄昏沙丘', Color(0xFFF0C987)),
    ThemePaletteEntry('snowPine', '雪与松', Color(0xFFB49BE0)),
    ThemePaletteEntry('mistland', '迷雾仙境', Color(0xFF8FC3F2)),
    ThemePaletteEntry('warmOrange', '暖阳橘', Color(0xFFF2926B)),
    ThemePaletteEntry('mintTeal', '薄荷青', Color(0xFF4FB5A3)),
    ThemePaletteEntry('roseGold', '玫瑰金', Color(0xFFA87B93)),
    ThemePaletteEntry('deepSeaBlue', '深海蓝', Color(0xFF1D5BD6)),
    ThemePaletteEntry('mapleRed', '枫叶红', Color(0xFFD03B2E)),
    ThemePaletteEntry('emeraldGreen', '翡翠绿', Color(0xFF3E8E4B)),
    ThemePaletteEntry('lavender', '薰衣草', Color(0xFF9D8BD9)),
    ThemePaletteEntry('amberYellow', '琥珀黄', Color(0xFFE8A33C)),
    ThemePaletteEntry('carmineRed', '胭脂红', Color(0xFFC22A5E)),
    ThemePaletteEntry('indigoBlue', '靛青蓝', Color(0xFF3B4BC8)),
    ThemePaletteEntry('oliveGreen', '橄榄绿', Color(0xFF6E9A3C)),
    ThemePaletteEntry('coralPink', '珊瑚粉', Color(0xFFF58F7C)),
    ThemePaletteEntry('darkGreen', '墨绿色', Color(0xFF2E6B47)),
    ThemePaletteEntry('violetOrchid', '紫罗兰', Color(0xFF7B3FD1)),
  ];

  static ThemePaletteEntry byId(String? id) {
    for (final entry in all) {
      if (entry.id == id) return entry;
    }
    return all.firstWhere((e) => e.id == defaultId);
  }
}
