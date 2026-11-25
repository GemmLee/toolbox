/// OpenAI 兼容平台的预设信息，以及用户自定义平台的数据模型。
class AssistantPlatform {
  const AssistantPlatform({
    required this.name,
    required this.baseUrl,
    required this.models,
    this.balanceKind = BalanceKind.none,
    this.id = '',
    this.isCustom = false,
  });

  final String name;
  final String baseUrl;
  final List<String> models;
  final BalanceKind balanceKind;

  /// 自定义平台的唯一 id（预设为空字符串）。
  final String id;
  final bool isCustom;

  factory AssistantPlatform.fromJson(Map<String, dynamic> j) =>
      AssistantPlatform(
        name: (j['name'] ?? '').toString(),
        baseUrl: (j['baseUrl'] ?? '').toString(),
        models: j['models'] is List
            ? (j['models'] as List)
                .map((e) => e.toString().trim())
                .where((s) => s.isNotEmpty)
                .toList(growable: false)
            : const <String>[],
        id: (j['id'] ?? '').toString(),
        isCustom: true,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'models': models,
      };

  static const List<AssistantPlatform> presets = <AssistantPlatform>[
    AssistantPlatform(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com/v1',
      // deepseek-chat / deepseek-reasoner 官方仍兼容（映射到 v4-flash 的
      // 非思考 / 思考模式），保留给已有配置；新配置优先 v4 系列。
      models: <String>[
        'deepseek-v4-flash',
        'deepseek-v4-pro',
        'deepseek-chat',
        'deepseek-reasoner',
      ],
      balanceKind: BalanceKind.deepseek,
    ),
    AssistantPlatform(
      name: '智谱 GLM',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      // 只列当前主流在售的对话模型（2026-11）；旧日期版与 v/plus 变体已淘汰，
      // 不在预设里堆砌——需要时仍可直接输入官方 model id。
      models: <String>[
        'glm-5.3',
        'glm-5.3-flash',
        'glm-5.3-flashx',
        'glm-5.2',
        'glm-5',
        'glm-4.7',
        'glm-4.7-flash',
        'glm-4.6',
        'glm-4.5-air',
        'glm-4.5-flash',
      ],
    ),
    AssistantPlatform(
      name: '通义千问',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      // 百炼 OpenAI 兼容模式当前主力：qwen3.8 / 3.7 / 3.6 系列，
      // qwen-plus / qwen-max 等短名仍兼容，保留给已有配置。
      models: <String>[
        'qwen3.8-max',
        'qwen3.8-flash',
        'qwen3.7-plus',
        'qwen3.6-plus',
        'qwen-plus',
        'qwen-flash',
        'qwen-max',
      ],
    ),
    AssistantPlatform(
      name: '月之暗面 Kimi',
      baseUrl: 'https://api.moonshot.cn/v1',
      // moonshot-v1 / kimi-k2 系列已于 2026 年陆续下线，换成当前在售模型。
      models: <String>[
        'kimi-k3.1-pro',
        'kimi-k3',
        'kimi-k2.7-code',
        'kimi-k2.6',
      ],
      balanceKind: BalanceKind.moonshot,
    ),
    AssistantPlatform(
      name: 'SiliconFlow 硅基流动',
      baseUrl: 'https://api.siliconflow.cn/v1',
      models: <String>[
        'deepseek-ai/DeepSeek-V4.1-Flash',
        'Pro/deepseek-ai/DeepSeek-V3.2',
        'Qwen/Qwen3.8-27B',
        'zai-org/GLM-5.3-Flash',
        'moonshotai/Kimi-K2.7-Code',
        'tencent/Hy4-preview',
      ],
      balanceKind: BalanceKind.siliconflow,
    ),
    AssistantPlatform(
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      models: <String>[
        'gpt-5.5',
        'gpt-5.4',
        'gpt-5.4-mini',
        'gpt-5.2',
        'gpt-5',
        'gpt-5-mini',
        'gpt-4.1',
      ],
    ),
  ];

  /// 预设 + 用户自定义平台。
  static List<AssistantPlatform> all(List<AssistantPlatform> custom) =>
      <AssistantPlatform>[...presets, ...custom];

  /// 按 baseUrl 匹配平台。自定义平台优先（避免自定义地址恰好落在某个
  /// 预设地址前缀下时被误判为预设平台）；[custom] 省略时只匹配预设。
  static AssistantPlatform? match(
    String baseUrl, [
    List<AssistantPlatform> custom = const <AssistantPlatform>[],
  ]) {
    final normalized = baseUrl.trim().toLowerCase();
    for (final p in custom) {
      final url = p.baseUrl.trim().toLowerCase();
      if (url.isEmpty) continue;
      if (normalized.startsWith(url)) return p;
    }
    for (final p in presets) {
      if (normalized.startsWith(p.baseUrl.toLowerCase())) return p;
    }
    return null;
  }
}

/// 判断输入模型是否属于该平台的预设（忽略大小写与首尾空格）。
///
/// 官方模型 id 大小写不敏感，用户也可能带空格粘贴；原来的 `contains` 完全相等
/// 判定会把 `GLM-4.5-Flash` 这类合法写法误报为「不在预设列表」。
bool isKnownModel(String input, AssistantPlatform platform) {
  final s = input.trim().toLowerCase();
  if (s.isEmpty) return true;
  return platform.models.any((m) => m.trim().toLowerCase() == s);
}

/// 把用户输入的模型文本（逗号 / 换行 / 空格 / 分号分隔）解析成模型列表，
/// 去重并保持输入顺序。
List<String> parsePlatformModels(String raw) {
  final parts = raw
      .split(RegExp(r'[\s,，;；]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  final seen = <String>{};
  return <String>[
    for (final p in parts)
      if (seen.add(p)) p
  ];
}

/// 余额查询方式。
enum BalanceKind { none, deepseek, moonshot, siliconflow }
