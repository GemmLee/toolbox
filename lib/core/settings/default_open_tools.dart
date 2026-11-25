/// 「默认打开工具」的数据模型：按文件扩展名决定外部导入的默认动作。
///
/// 这里只放纯常量与纯函数，不依赖 Flutter / 多语言，方便单测与设置页复用。
library;

/// 外部文件（「用其他应用打开」或「分享到 XMtools」）的默认处理方式。
enum DefaultOpenAction {
  /// 直接用文字阅读器打开。
  reader,

  /// 当作题库 JSON 校验并进入导入预览。
  quizBank,
}

/// 一组共用同一套处理方式的扩展名。
class DefaultOpenRule {
  const DefaultOpenRule({
    required this.id,
    required this.extensions,
    required this.actions,
    required this.defaultAction,
  });

  /// 持久化用的稳定 id，不随文案变化。
  final String id;
  final List<String> extensions;

  /// 该格式目前支持的全部动作；只有一个时设置页只展示、不提供切换。
  final List<DefaultOpenAction> actions;
  final DefaultOpenAction defaultAction;

  String get label => extensions.map((e) => '.$e').join(' / ');
}

/// XMtools 内部能处理的全部文本格式，按可选动作分组。
///
/// 新增处理方式时只要在这里给对应格式加一个 [DefaultOpenAction]，
/// 设置页与外部导入链路会自动跟上，不需要再改 UI。
const List<DefaultOpenRule> kDefaultOpenRules = <DefaultOpenRule>[
  DefaultOpenRule(
    id: 'json',
    extensions: <String>['json'],
    actions: <DefaultOpenAction>[
      DefaultOpenAction.quizBank,
      DefaultOpenAction.reader,
    ],
    // 题库 JSON 是最常见的场景，默认直接进刷题助手的导入预览。
    defaultAction: DefaultOpenAction.quizBank,
  ),
  DefaultOpenRule(
    id: 'markdown',
    extensions: <String>['md', 'markdown'],
    actions: <DefaultOpenAction>[DefaultOpenAction.reader],
    defaultAction: DefaultOpenAction.reader,
  ),
  DefaultOpenRule(
    id: 'html',
    extensions: <String>['html', 'htm'],
    actions: <DefaultOpenAction>[DefaultOpenAction.reader],
    defaultAction: DefaultOpenAction.reader,
  ),
  DefaultOpenRule(
    id: 'text',
    extensions: <String>[
      'txt',
      'text',
      'log',
      'csv',
      'tsv',
      'xml',
      'yaml',
      'yml',
    ],
    actions: <DefaultOpenAction>[DefaultOpenAction.reader],
    defaultAction: DefaultOpenAction.reader,
  ),
];

/// 小写扩展名（不含点）；无扩展名返回空串。
String extensionOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1).toLowerCase();
}

DefaultOpenRule? ruleForExtension(String ext) {
  if (ext.isEmpty) return null;
  for (final rule in kDefaultOpenRules) {
    if (rule.extensions.contains(ext)) return rule;
  }
  return null;
}

DefaultOpenRule? ruleForFileName(String fileName) =>
    ruleForExtension(extensionOf(fileName));

/// 外部导入支持的所有扩展名（供 FileImportBridge 过滤）。
Set<String> get kSupportedImportExtensions => <String>{
      for (final rule in kDefaultOpenRules) ...rule.extensions,
    };

/// 持久化值。
String actionKey(DefaultOpenAction action) => switch (action) {
      DefaultOpenAction.reader => 'reader',
      DefaultOpenAction.quizBank => 'quizBank',
    };

DefaultOpenAction? actionFromKey(Object? key) => switch (key) {
      'reader' => DefaultOpenAction.reader,
      'quizBank' => DefaultOpenAction.quizBank,
      _ => null,
    };

/// 动作中文名（调用方用 tr() 翻译）。
String actionName(DefaultOpenAction action) => switch (action) {
      DefaultOpenAction.reader => '文字阅读器',
      DefaultOpenAction.quizBank => '导入题库',
    };

/// 动作说明（调用方用 tr() 翻译）。
String actionDescription(DefaultOpenAction action) => switch (action) {
      DefaultOpenAction.reader => '按原文打开，md / html 渲染、json 高亮、txt 可编辑',
      DefaultOpenAction.quizBank => '校验后直接进导入预览，确认即写入题库',
    };
