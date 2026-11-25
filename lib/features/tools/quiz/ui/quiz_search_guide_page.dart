import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';

/// 搜题页教程：把三种搜题方式与使用前的准备讲清楚。
class QuizSearchGuidePage extends StatelessWidget {
  const QuizSearchGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('搜题教程'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          SectionCard(
            key: const ValueKey('quiz-guide-import-bank'),
            title: tr('导入题库（详细步骤）'),
            subtitle: tr('没有题库，三种搜题都查不到答案'),
            children: <Widget>[
              _GuideRow(
                icon: Icons.description_outlined,
                title: tr('题库长什么样'),
                text: tr(
                    '支持 .json 与 .xlsx 两种文件。\n.json：根节点含 version、bankName、questions，每题写 type、stem、options、answer，判断题不写 options（App 自动补「正确 / 错误」）。\n.xlsx：每行一题，列依次为 题型（可省略）| 题干 | 选项A | 选项B | … | 空一列 | 答案 | 解析（可省略）；选项后空一列写答案，有表头自动跳过；不写题型时自动判断，重复题自动去重。'),
              ),
              _GuideRow(
                icon: Icons.auto_awesome_outlined,
                title: tr('方式一：内置 AI 导入'),
                text: tr(
                    '在「用户 → AI 配置」填好 API key 与模型，再到「刷题 → 导入题库 → AI 导入」选 Word / Excel / txt / md 等资料，内置「题库转换」技能转成题库后确认入库。'),
              ),
              _GuideRow(
                icon: Icons.download_outlined,
                title: tr('方式二：交给其他 AI'),
                text: tr(
                    '在「用户 → AI 配置 → 技能」导出内置「题库转换」Markdown 技能，交给任意 AI 按题库 JSON 规范输出，再存成 .json 文件。'),
              ),
              _GuideRow(
                icon: Icons.folder_open_outlined,
                title: tr('把题库文件放进存储空间'),
                text: tr(
                    '题库文件存到「用户 → 存储空间」便于复用、分享和备份；微信 / QQ 收到的文件选「用其他应用打开」→ XMtools 会自动归档到这里。'),
              ),
              _GuideRow(
                icon: Icons.tune_outlined,
                title: tr('可选：设置默认打开工具'),
                text: tr(
                    '在「用户 → 默认打开工具」把 .json 设为「导入题库」，以后从外部 App 打开或分享题库文件会直接进入导入预览，不必再手动选文件。'),
              ),
              _GuideRow(
                icon: Icons.quiz_outlined,
                title: tr('在刷题助手里导入'),
                text: tr(
                    '「刷题 → 导入题库」，从手机或存储空间选 .json / .xlsx 文件，自动识别格式并预览题数与校验提示，确认后写入题库。'),
              ),
              _GuideRow(
                icon: Icons.check_circle_outlined,
                title: tr('导入后检查'),
                text: tr(
                    '回到「刷题」首页能看到新题库，可拖动调整顺序、导出 JSON / Excel 备份；三种搜题都只从已导入的题库里匹配答案。'),
              ),
              SmallHint(
                text: tr('导入前会逐题校验：题型不支持、题干为空或答案格式不对都会列出题号，改好源文件重新导入即可。'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: tr('使用前准备'),
            children: <Widget>[
              _GuideRow(
                icon: Icons.library_books_outlined,
                title: tr('先导入题库'),
                text: tr('三种搜题都从已导入的 JSON 题库里找答案，导入方法见本页最上方的「导入题库」。'),
              ),
              _GuideRow(
                icon: Icons.layers_outlined,
                title: tr('授予悬浮窗权限'),
                text: tr('便捷搜题与智能搜题需要在其他应用上层显示，首次开启时按提示授权。'),
              ),
              _GuideRow(
                icon: Icons.accessibility_new_outlined,
                title: tr('智能搜题还需无障碍'),
                text: tr('智能搜题靠无障碍服务读取屏幕内容，开启页会引导前往系统设置。'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: tr('三种搜题方式'),
            children: <Widget>[
              _GuideRow(
                icon: Icons.image_search_outlined,
                title: tr('拍照搜题'),
                text: tr('拍下题目或从相册选图，识别文字后按题干与选项匹配题库，查看答案与解析。'),
              ),
              _GuideRow(
                icon: Icons.picture_in_picture_alt_outlined,
                title: tr('便捷搜题'),
                text: tr('在其他应用里用汉字首字母输入，例如 AQ 对应「安全」；可限定题库与题型，× 一键清空。'),
              ),
              _GuideRow(
                icon: Icons.center_focus_strong_outlined,
                title: tr('智能搜题'),
                text: tr('用绿色框选窗框住题目，换题会自动重新识别；尽量把题干和选项一起框进去，匹配更准。'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: tr('查看多条结果'),
            children: <Widget>[
              _GuideRow(
                icon: Icons.swipe_outlined,
                title: tr('左右滑动切换'),
                text: tr('结果按相关度从高到低排列，在悬浮窗答案上左右滑动即可逐条查看。'),
              ),
              _GuideRow(
                icon: Icons.format_list_numbered_outlined,
                title: tr('每次显示数'),
                text: tr('在便捷搜题、智能搜题的设置里调整一次最多出几道题，默认 3 道。'),
              ),
              SmallHint(text: tr('答案窗可拖动、缩放并上下滚动；左下角标记可收成边缘小球，点小球恢复。')),
            ],
          ),
        ],
      ),
    );
  }
}

class _GuideRow extends StatelessWidget {
  const _GuideRow({
    required this.icon,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(text, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
