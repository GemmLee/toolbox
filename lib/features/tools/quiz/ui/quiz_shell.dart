import 'package:flutter/material.dart';

import '../../../../core/app_theme.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import 'quiz_common.dart';
import 'quiz_page.dart';
import 'quiz_photo_search_page.dart';
import 'quiz_quick_search_page.dart';
import 'quiz_search_guide_page.dart';
import 'quiz_smart_search_page.dart';

/// 刷题助手外壳：底部导航切换「刷题」（原首页）与「搜题」。
///
/// 两页放在 [PageView] 里，可左右滑动切换；每页用 keep-alive 包住，
/// 来回切换不会丢掉题库列表的滚动位置与筛选状态。
class QuizShell extends StatefulWidget {
  const QuizShell({super.key});

  @override
  State<QuizShell> createState() => _QuizShellState();
}

class _QuizShellState extends State<QuizShell> {
  final PageController _pager = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  /// 点底部导航：切页并让 PageView 跟过去，两处状态只由 [_index] 驱动。
  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    if (_pager.hasClients) {
      _pager.animateToPage(
        index,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        key: const ValueKey('quiz-pager'),
        controller: _pager,
        onPageChanged: (index) => setState(() => _index = index),
        children: const <Widget>[
          _KeepAlivePage(child: QuizPage()),
          _KeepAlivePage(child: QuizSearchTabPage()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        key: const ValueKey('quiz-bottom-nav'),
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: <Widget>[
          NavigationDestination(
            key: const ValueKey('quiz-tab-practice'),
            icon: const Icon(Icons.quiz_outlined),
            selectedIcon: const Icon(Icons.quiz),
            label: tr('刷题'),
          ),
          NavigationDestination(
            key: const ValueKey('quiz-tab-search'),
            icon: const Icon(Icons.search_outlined),
            selectedIcon: const Icon(Icons.search),
            label: tr('搜题'),
          ),
        ],
      ),
    );
  }
}

/// PageView 会把离屏页销毁，这里让每页常驻，保住滚动位置与加载结果。
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 「搜题」页：与工具总览同款的三列圆角方形卡片。
class QuizSearchTabPage extends StatelessWidget {
  const QuizSearchTabPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 三色是「拍照 / 便捷 / 智能」的功能编码色，刻意保留以利辨识。
    // 浅色用原值（与既有视觉一致），深色整体提亮一档，保证图标在深底上清晰。
    final dark = Theme.of(context).brightness == Brightness.dark;
    final photoAccent =
        dark ? const Color(0xFFB9A4FF) : const Color(0xFF7A5AF8);
    final quickAccent =
        dark ? const Color(0xFF5BD8A8) : const Color(0xFF17A673);
    final smartAccent =
        dark ? const Color(0xFFFFB570) : const Color(0xFFE8873A);
    return Scaffold(
      appBar: AppBar(title: Text(tr('搜题'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 10.0;
              final width = (constraints.maxWidth - gap * 2) / 3;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: <Widget>[
                  _SearchCard(
                    key: const ValueKey('quiz-search-photo'),
                    width: width,
                    icon: Icons.image_search_outlined,
                    accent: photoAccent,
                    title: tr('拍照搜题'),
                    description: tr('拍下题目，匹配题库里的题与答案'),
                    onTap: () => Navigator.of(context).push(
                      quizRoute<void>(
                        builder: (_) => const QuizPhotoSearchPage(),
                      ),
                    ),
                  ),
                  _SearchCard(
                    key: const ValueKey('quiz-search-quick'),
                    width: width,
                    icon: Icons.picture_in_picture_alt_outlined,
                    accent: quickAccent,
                    title: tr('便捷搜题'),
                    description: tr('悬浮窗跨应用搜题，不抢输入焦点'),
                    onTap: () => Navigator.of(context).push(
                      quizRoute<void>(
                        builder: (_) => const QuizQuickSearchPage(),
                      ),
                    ),
                  ),
                  _SearchCard(
                    key: const ValueKey('quiz-search-smart'),
                    width: width,
                    icon: Icons.center_focus_strong_outlined,
                    accent: smartAccent,
                    title: tr('智能搜题'),
                    description: tr('框选题目，换题自动出答案'),
                    onTap: () => Navigator.of(context).push(
                      quizRoute<void>(
                        builder: (_) => const QuizSmartSearchPage(),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          _GuideCard(
            onTap: () => Navigator.of(context).push(
              quizRoute<void>(
                builder: (_) => const QuizSearchGuidePage(),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SmallHint(
            text: tr('本功能仅供学习参考，请勿用于考试'),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// 教程入口：整宽卡片，点进去看三种搜题方式与使用前准备。
class _GuideCard extends StatelessWidget {
  const _GuideCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('quiz-search-guide'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              Icon(Icons.menu_book_outlined, color: scheme.primary, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(tr('使用教程'), style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      tr('导入题库、三种搜题方式与权限准备'),
                      maxLines: 2,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// 与工具总览卡片同款：边长跟随三列网格、图标不加圆角框。
class _SearchCard extends StatelessWidget {
  const _SearchCard({
    super.key,
    required this.width,
    required this.icon,
    required this.accent,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final double width;
  final IconData icon;
  final Color accent;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: width,
      height: width,
      child: Material(
        color: theme.cardTheme.color,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          side: BorderSide(color: scheme.outlineVariant.withOpacity(0.9)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.topLeft,
                        radius: 1.15,
                        colors: <Color>[
                          accent.withOpacity(0.10),
                          accent.withOpacity(0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(11, 12, 11, 11),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(icon, color: accent, size: 26),
                    const Spacer(),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 13.6,
                        height: 1.25,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant.withOpacity(0.9),
                        fontSize: 11,
                        height: 1.25,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
