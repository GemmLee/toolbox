import 'dart:math';

import '../data/assistant_api.dart';

/// 一段独立对话（左侧栏的一行）。
///
/// 消息、标题、更新时间都随会话一起持久化，切换会话不影响正在生成的请求。
class AssistantSession {
  AssistantSession({
    required this.id,
    required this.title,
    List<ChatMessage>? messages,
    DateTime? updatedAt,
  })  : messages = messages ?? <ChatMessage>[],
        updatedAt = updatedAt ?? DateTime.now();

  factory AssistantSession.fromJson(Map<String, dynamic> json) {
    final raw = json['messages'];
    return AssistantSession(
      id: json['id'] as String? ?? newId(),
      title: json['title'] as String? ?? '',
      messages: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : <ChatMessage>[],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['updatedAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch),
    )..draft = json['draft'] as String? ?? ''
      ..skillId = json['skillId'] as String? ?? '';
  }

  /// 生成唯一 id（毫秒时间戳 + 随机后缀，避免快速连建撞车）。
  static String newId() {
    final rnd = Random().nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    return 'c-${DateTime.now().millisecondsSinceEpoch}-$rnd';
  }

  final String id;
  final List<ChatMessage> messages;
  String title;
  DateTime updatedAt;

  /// 生成中被中断时已收到的内容（定期落盘，下次打开转成消息）。
  String draft = '';

  /// 这段对话选定的技能 id（空 = 自由对话）。技能跟着对话走，
  /// 切换对话不会把选择重置掉。
  String skillId = '';

  int get size => messages.length;

  /// 用第一条用户消息给会话起名。
  static String titleFrom(String text, {int max = 24}) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '';
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'draft': draft,
        'skillId': skillId,
        'messages': messages.map((m) => m.toJson()).toList(),
      };
}
