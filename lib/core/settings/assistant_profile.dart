import 'dart:math';

/// 新建配置时的默认接口地址与模型（不含任何内置 API Key）。
const String kDefaultAssistantBaseUrl = 'https://api.deepseek.com/v1';
const String kDefaultAssistantModel = 'deepseek-v4-flash';

/// 一个 AI 平台连接配置（多配置管理的基本单元）。
class AssistantProfile {
  AssistantProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
  });

  factory AssistantProfile.fromJson(Map<String, dynamic> json) =>
      AssistantProfile(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? '',
        model: json['model'] as String? ?? '',
        apiKey: json['apiKey'] as String? ?? '',
      );

  /// 生成唯一 id（毫秒时间戳 + 随机后缀，避免快速连建撞车）。
  static String newId() {
    final rnd = Random().nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    return 'p-${DateTime.now().millisecondsSinceEpoch}-$rnd';
  }

  final String id;
  final String name;
  final String baseUrl;
  final String model;

  /// API Key 仅保存在本机，不内置任何默认值。
  final String apiKey;

  AssistantProfile copyWith({
    String? name,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) =>
      AssistantProfile(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
        'apiKey': apiKey,
      };
}
