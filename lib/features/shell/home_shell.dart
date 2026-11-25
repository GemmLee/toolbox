import 'package:flutter/material.dart';

import '../../core/platform/file_import_bridge.dart';
import '../../core/settings/app_l10n.dart';
import '../../core/settings/default_open_tools.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/storage/app_files.dart';
import '../../core/widgets/app_backdrop.dart';
import '../../core/widgets/app_widgets.dart';
import '../tools/quiz/logic/quiz_import.dart';
import '../tools/quiz/ui/quiz_common.dart';
import '../tools/quiz/ui/quiz_import_page.dart';
import '../tools/text_reader/reader_view_page.dart';
import 'tab_registry.dart';

/// 应用外壳：底部导航 + IndexedStack 保持各页状态。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    FileImportBridge.instance.addListener(_onFilesImported);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingImport());
  }

  @override
  void dispose() {
    FileImportBridge.instance.removeListener(_onFilesImported);
    super.dispose();
  }

  /// 外部文件导入后直接打开阅读器；冷启动的那份在首帧回调里取。
  void _onFilesImported() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingImport());
  }

  Future<void> _openPendingImport() async {
    if (!mounted) return;
    final pending = FileImportBridge.instance.takePending();
    if (pending == null) return;
    switch (pending.action) {
      case DefaultOpenAction.reader:
        _openReader(pending.file);
      case DefaultOpenAction.quizBank:
        await _openQuizImport(pending.file);
    }
  }

  void _openReader(StoredFile file) {
    if (!mounted) return;
    Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => ReaderViewPage(file: file),
    ));
  }

  /// 设成「导入题库」的外部 JSON：先校验预览，确认后才写库。
  /// 文件不是合法题库时退回阅读器，方便直接看内容，不会把人卡死。
  Future<void> _openQuizImport(StoredFile file) async {
    try {
      final text = await AppStore.readText(file);
      final preview = QuizImporter.parse(text);
      final repo = await QuizServices.repo();
      if (!mounted) return;
      await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
        builder: (_) => QuizImportPage(repo: repo, preview: preview),
      ));
    } catch (e) {
      if (!mounted) return;
      showToast(context, trf('按题库导入失败：{e}，已打开文字阅读器', {'e': '$e'}));
      _openReader(file);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final l10n = AppL10n.of();
        final theme = Theme.of(context);
        final tabs = kAppTabs;
        final safeIndex = _index.clamp(0, tabs.length - 1);
        final scheme = theme.colorScheme;
        final isDark = theme.brightness == Brightness.dark;
        return AppBackdrop(
          kind: settings.backgroundKind,
          colorId: settings.backgroundColorId,
          gradientId: settings.backgroundGradientId,
          imagePath: settings.backgroundImagePath,
          imageLuminance: settings.backgroundImageLuminance,
          child: Scaffold(
            // 底色由 AppBackdrop 负责，Scaffold 保持透明才能看到柔光
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              title: tabs[safeIndex].id == 'overview'
                  ? Builder(builder: (context) => _brandTitle(context))
                  : Text(tabs[safeIndex].title(l10n)),
              actions: [
                if (tabs[safeIndex].id == 'overview')
                  IconButton(
                    tooltip: l10n.aboutTitle,
                    icon: const Icon(Icons.widgets_outlined),
                    onPressed: () => _showAbout(context, l10n),
                  ),
              ],
            ),
            body: IndexedStack(
              index: safeIndex,
              children: [
                for (final tab in tabs) tab.builder(context),
              ],
            ),
            // 底栏：半透明 + 顶部发丝线 + 极淡投影，浮在内容之上
            bottomNavigationBar: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: scheme.outlineVariant.withOpacity(0.7),
                  ),
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.28 : 0.04),
                    blurRadius: 20,
                    offset: const Offset(0, -6),
                  ),
                ],
              ),
              child: NavigationBar(
                selectedIndex: safeIndex,
                onDestinationSelected: (index) {
                  FocusScope.of(context).unfocus();
                  setState(() => _index = index);
                },
                destinations: [
                  for (final tab in tabs)
                    NavigationDestination(
                      icon: Icon(tab.icon),
                      selectedIcon: Icon(tab.selectedIcon),
                      label: tab.label(l10n),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 总览页 AppBar 的双色品牌标题：XM（primary）+ tools（tertiary）。
  Widget _brandTitle(BuildContext context) {
    final theme = Theme.of(context);
    // 浅色主题 + 深色自定义背景时品牌色可能也是深色，改为统一白色前景。
    // 深色主题本来就是浅色前景，保持品牌双色。
    final darkBackdrop = theme.brightness == Brightness.light &&
        BackdropStyle.maybeOf(context)?.isDark == true;
    final foreground = BackdropStyle.foregroundOf(
      context,
      theme.colorScheme.onSurface,
    );
    // 比默认 titleLarge（约 22px）增大约 50%，凸显品牌。
    final style = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: 0.5,
      fontSize: 34,
    );
    return Text.rich(
      TextSpan(
        text: 'XM',
        style: style?.copyWith(
          color: darkBackdrop ? foreground : theme.colorScheme.primary,
        ),
        children: [
          TextSpan(
            text: 'tools',
            style: style?.copyWith(
              color: darkBackdrop
                  ? foreground.withOpacity(0.75)
                  : theme.colorScheme.tertiary,
            ),
          ),
        ],
      ),
    );
  }

  /// 总览页右上角：一段简介 + 版本号，末尾给反馈邮箱。
  void _showAbout(BuildContext context, AppL10n l10n) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.aboutTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(l10n.aboutBody),
              const SizedBox(height: 12),
              Text(
                tr('反馈 bug 发送邮件到 ljm123aa@163.com'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              Text(
                l10n.aboutVersion,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
  }
}
