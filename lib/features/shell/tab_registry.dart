import 'package:flutter/material.dart';

import '../../core/settings/app_l10n.dart';
import '../overview/tools_overview_page.dart';
import '../user/user_page.dart';

/// 底部导航项。
///
/// 扩展方式：在 [kAppTabs] 追加一条即可，[HomeShell] 会自动生成导航按钮。
/// 标题/文案以函数形式提供，切换语言时自动跟随。
class AppTab {
  const AppTab({
    required this.id,
    required this.title,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
  });

  final String id;

  /// 顶部 AppBar 标题。
  final String Function(AppL10n l10n) title;

  /// 底部导航文案。
  final String Function(AppL10n l10n) label;
  final IconData icon;
  final IconData selectedIcon;
  final WidgetBuilder builder;
}

final List<AppTab> kAppTabs = <AppTab>[
  AppTab(
    id: 'overview',
    title: (l10n) => l10n.appTitle,
    label: (l10n) => l10n.tabOverview,
    icon: Icons.grid_view_outlined,
    selectedIcon: Icons.grid_view_rounded,
    builder: (_) => const ToolsOverviewPage(),
  ),
  AppTab(
    id: 'user',
    title: (l10n) => l10n.tabUser,
    label: (l10n) => l10n.tabUser,
    icon: Icons.person_outline,
    selectedIcon: Icons.person,
    builder: (_) => const UserPage(),
  ),
];
