import 'package:flutter/material.dart';

import '../../core/platform/browser_opener.dart';
import '../../core/settings/app_l10n.dart';
import '../../core/settings/app_version.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/widgets/app_widgets.dart';
import 'app_update_service.dart';

/// 「关于」页：应用信息 + 检测更新 + 简介与反馈 + 两个可点进的说明入口。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.updateService, this.updateServiceOpener});

  /// 可注入以便测试；默认从公开 R2 域名读取 version.json。
  final AppUpdateService? updateService;

  /// 更新下载按钮的浏览器打开器，可注入以便测试。
  final BrowserOpener? updateServiceOpener;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const List<GuideItem> _gettingStarted = <GuideItem>[
    GuideItem(
      Icons.quiz_outlined,
      '开始刷题',
      '导入 JSON 题库后，在「刷题」页选题库即可练习或考试；断点续答会自动接上次的进度，答题卡可左右滑动跳题。',
    ),
    GuideItem(
      Icons.image_search_outlined,
      '三种搜题',
      '拍照搜题、便捷搜题、智能搜题都从已导入的题库里找答案；权限、框选与首字母用法见「搜题 → 使用教程」。',
    ),
    GuideItem(
      Icons.auto_awesome_outlined,
      '把资料变成题库',
      '「刷题 → 导入题库 → AI 导入」会调用内置题库转换技能（需自己的 API key），也可把该技能导出给其他 AI 工具；完整流程在搜题教程里。',
    ),
    GuideItem(
      Icons.folder_open_outlined,
      '导入文档与文件位置',
      '在微信、QQ 里对 txt / json / md 选择「用其他应用打开」→ XMtools，按「用户 → 默认打开工具」的设置处理；文件统一进「用户 → 存储空间」。',
    ),
  ];

  static const List<GuideItem> _popularTools = <GuideItem>[
    GuideItem(
      Icons.quiz_outlined,
      '刷题助手',
      '练习 / 考试 / 断点续答，配错题本、收藏、笔记与文件夹分类；做题时点题型旁的铅笔可改题干、选项与答案，还能单题库导出 JSON 或 Excel。',
    ),
    GuideItem(
      Icons.image_search_outlined,
      '搜题工具',
      '拍照搜题离线识别题干；便捷搜题用首字母跨应用查；智能搜题框选题干自动出答案，支持限定题库范围。',
    ),
    GuideItem(
      Icons.article_outlined,
      '文字阅读器',
      'md 表格 / 任务列表渲染、json 着色、txt 可编辑覆盖保存；长文档按块加载，不截断。',
    ),
    GuideItem(
      Icons.photo_camera_outlined,
      '证件照',
      '照片转证件照会先校验人脸再抠图换底；已有证件照可直接换底色、改尺寸与体积，出图后还能反复换底。',
    ),
    GuideItem(
      Icons.auto_awesome_outlined,
      '智能助手',
      '先在「用户 → AI 配置」填写模型接口与密钥；技能是 Markdown 格式，可从存储空间导入。',
    ),
    GuideItem(
      Icons.document_scanner_outlined,
      '文字识别',
      '拍照或从相册选图，离线识别中文 / 英文印刷体，结果可编辑、复制或存到存储空间。',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppL10n.of();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset(
                      'assets/logo.png',
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.appTitle,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.aboutVersion,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          _UpdateCard(
            service: widget.updateService,
            opener: widget.updateServiceOpener,
          ),
          const SizedBox(height: 4),
          // 简介与反馈合并成一张卡，紧挨着应用信息与更新。
          _introCard(context, theme, l10n),
          const SizedBox(height: 4),
          _entryCard(
            context,
            theme,
            key: const ValueKey('about-guide-start'),
            icon: Icons.explore_outlined,
            title: tr('快速上手'),
            subtitle: tr('刷题、搜题、导入文件与默认打开方式'),
            items: _gettingStarted,
          ),
          const SizedBox(height: 4),
          _entryCard(
            context,
            theme,
            key: const ValueKey('about-guide-tools'),
            icon: Icons.widgets_outlined,
            title: tr('常用工具'),
            subtitle: tr('刷题与搜题、阅读器、证件照、AI 助手'),
            items: _popularTools,
          ),
        ],
      ),
    );
  }

  /// 简介 + 反馈与建议（同一张卡，分隔线分开）。
  Widget _introCard(BuildContext context, ThemeData theme, AppL10n l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.aboutBody,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 14),
            Divider(
              height: 1,
              color: theme.colorScheme.outlineVariant.withOpacity(0.6),
            ),
            const SizedBox(height: 12),
            Text(
              tr('反馈与建议'),
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '${tr('欢迎提出任何意见与建议，指出bug')}\n'
              '${tr('发送到：ljm123aa@163.com')}',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  /// 入口卡：只放标题与一行概述，点进去才展开具体说明。
  Widget _entryCard(
    BuildContext context,
    ThemeData theme, {
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required List<GuideItem> items,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: key,
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => AboutGuidePage(title: title, items: items),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 22, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 说明详情页：入口卡点进来后逐条展开。
class AboutGuidePage extends StatelessWidget {
  const AboutGuidePage({
    super.key,
    required this.title,
    required this.items,
  });

  final String title;
  final List<GuideItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Column(
                children: <Widget>[
                  for (var i = 0; i < items.length; i++) ...<Widget>[
                    _GuideRow(item: items[i], theme: theme),
                    if (i < items.length - 1)
                      Divider(
                        height: 1,
                        color:
                            theme.colorScheme.outlineVariant.withOpacity(0.6),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideRow extends StatelessWidget {
  const _GuideRow({required this.item, required this.theme});

  final GuideItem item;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(item.icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  tr(item.title),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  tr(item.text),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 检测更新卡：点按钮拉取 R2 的 version.json，有新版本则给出下载按钮（跳浏览器）。
///
/// 只显示公开直链，不暴露任何私有域名或密钥。
class _UpdateCard extends StatefulWidget {
  const _UpdateCard({this.service, BrowserOpener? opener}) : _opener = opener;

  final AppUpdateService? service;
  final BrowserOpener? _opener;

  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> {
  late AppUpdateService _service;
  BrowserOpener? _opener;
  bool _checking = false;
  AppUpdateInfo? _info;
  String? _error;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? AppUpdateService();
    _opener = widget._opener;
  }

  @override
  void dispose() {
    if (widget.service == null) _service.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
      _info = null;
    });
    try {
      final info = await _service.fetch();
      if (!mounted) return;
      setState(() {
        _info = info;
        _checking = false;
      });
    } on AppUpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _checking = false;
      });
    }
  }

  Future<void> _download() async {
    final info = _info;
    if (info == null || _downloading) return;
    setState(() => _downloading = true);
    final opener = _opener ?? BrowserOpener();
    final url = info.apkUrl(_service.baseUrl);
    final ok = await opener.open(url);
    if (!mounted) return;
    setState(() => _downloading = false);
    if (!ok) showToast(context, tr('无法打开浏览器，请检查系统设置'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasUpdate =
        _info != null && isNewerVersion(_info!.version, kAppVersion);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.system_update_outlined,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tr('检测更新'),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (_checking)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton(
                    key: const ValueKey('about-check-update'),
                    onPressed: _check,
                    child: Text(_info == null ? tr('检测更新') : tr('重新检测')),
                  ),
              ],
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                '${tr('检测失败')}：$_error',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (_info != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                hasUpdate
                    ? trf('发现新版本 {version}',
                        <String, Object?>{'version': _info!.version})
                    : tr('当前已是最新版本'),
                style: theme.textTheme.bodyMedium,
              ),
              if (_info!.notes.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  _info!.notes,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (hasUpdate) ...<Widget>[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const ValueKey('about-download-update'),
                    onPressed: _downloading ? null : _download,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(_downloading ? tr('正在打开…') : tr('下载新版本')),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// 一条说明：图标 + 标题 + 正文。
class GuideItem {
  const GuideItem(this.icon, this.title, this.text);

  final IconData icon;
  final String title;
  final String text;
}
