import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// AIHOT 热点榜中的一条事件。
class AiHotTopic {
  const AiHotTopic({
    required this.rank,
    required this.title,
    this.sourceName = '',
    this.originalUrl = '',
    this.aihotUrl = '',
    this.storyUrl = '',
    this.sourceCount = 0,
    this.latestAt = '',
    this.sourceNames = const <String>[],
  });

  final int rank;
  final String title;
  final String sourceName;
  final String originalUrl;
  final String aihotUrl;
  final String storyUrl;
  final int sourceCount;
  final String latestAt;
  final List<String> sourceNames;

  factory AiHotTopic.fromJson(Map<String, dynamic> json) {
    final source = json['source'];
    final links = json['links'];
    return AiHotTopic(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      title: (json['title'] ?? '').toString(),
      sourceName: source is Map ? (source['name'] ?? '').toString() : '',
      originalUrl: links is Map ? (links['original'] ?? '').toString() : '',
      aihotUrl: links is Map ? (links['aihot'] ?? '').toString() : '',
      storyUrl: links is Map ? (links['story'] ?? '').toString() : '',
      sourceCount: (json['sourceCount'] as num?)?.toInt() ?? 0,
      latestAt: (json['latestAt'] ?? '').toString(),
      sourceNames: json['sourceNames'] is List
          ? (json['sourceNames'] as List)
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList(growable: false)
          : const <String>[],
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'rank': rank,
        'title': title,
        'source': <String, dynamic>{'name': sourceName},
        'links': <String, dynamic>{
          'original': originalUrl,
          'aihot': aihotUrl,
          'story': storyUrl,
        },
        'sourceCount': sourceCount,
        'latestAt': latestAt,
        'sourceNames': sourceNames,
      };
}

/// AIHOT 精选资讯中的一条。
class AiHotItem {
  const AiHotItem({
    required this.title,
    this.summary = '',
    this.sourceName = '',
    this.originalUrl = '',
    this.aihotUrl = '',
    this.publishedAt = '',
    this.category = '',
    this.score,
    this.reason = '',
  });

  final String title;
  final String summary;
  final String sourceName;
  final String originalUrl;
  final String aihotUrl;
  final String publishedAt;
  final String category;
  final int? score;
  final String reason;

  factory AiHotItem.fromJson(Map<String, dynamic> json) {
    final source = json['source'];
    final links = json['links'];
    return AiHotItem(
      title: (json['title'] ?? '').toString(),
      summary: (json['summary'] ?? '').toString(),
      sourceName: source is Map ? (source['name'] ?? '').toString() : '',
      originalUrl: links is Map ? (links['original'] ?? '').toString() : '',
      aihotUrl: links is Map ? (links['aihot'] ?? '').toString() : '',
      publishedAt: (json['publishedAt'] ?? '').toString(),
      category: (json['category'] ?? '').toString(),
      score: (json['score'] as num?)?.toInt(),
      reason: (json['reason'] ?? '').toString(),
    );
  }

  /// 原文发布时间，转成北京时间字符串（截至分钟）；解析不了时回退原文。
  String get timeLabel {
    final parsed = DateTime.tryParse(publishedAt);
    if (parsed == null) return publishedAt;
    final beijing = parsed.toUtc().add(const Duration(hours: 8));
    final m = beijing.month.toString().padLeft(2, '0');
    final d = beijing.day.toString().padLeft(2, '0');
    final h = beijing.hour.toString().padLeft(2, '0');
    final min = beijing.minute.toString().padLeft(2, '0');
    return '$m-$d $h:$min';
  }

  /// 输出可被 [AiHotItem.fromJson] 原样还原的结构，用于离线缓存。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'summary': summary,
        'source': <String, dynamic>{'name': sourceName},
        'links': <String, dynamic>{
          'original': originalUrl,
          'aihot': aihotUrl,
        },
        'publishedAt': publishedAt,
        'category': category,
        'score': score,
        'reason': reason,
      };
}

/// AIHOT 请求异常（消息可直接展示）。
class AiHotException implements Exception {
  const AiHotException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// AIHOT（aihot.news）中文 AI 资讯服务，匿名只读、无需鉴权。
///
/// - 热点榜：`GET /api/v1/hot-topics`
/// - 精选资讯：`GET /api/v1/items?mode=selected&window=24h|7d&limit=10`
class AiHotService {
  AiHotService({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  static const String baseUrl = 'https://aihot.news';
  static const String hotEndpoint = '$baseUrl/api/v1/hot-topics';
  static const String itemsEndpoint = '$baseUrl/api/v1/items';
  static const int fetchLimit = 10;

  /// 近 7 天的精选条目远多于 24 小时，接口按时间倒序取前 10 时两个窗口
  /// 必然完全重合。多取一页再按评分降序取前 10，让「近 7 天」呈现真正不同
  /// 的高分内容。
  static const int weekFetchLimit = 50;

  final http.Client _client;
  final Duration timeout;

  Future<List<AiHotTopic>> fetchHot() async {
    final decoded = _get(hotEndpoint);
    final root = await decoded;
    _requireMap(root);
    final items = root['items'];
    if (items is! List || items.isEmpty) {
      throw const AiHotException('暂时没有热点数据');
    }
    return items
        .whereType<Map>()
        .map((e) => AiHotTopic.fromJson(Map<String, dynamic>.from(e)))
        .where((t) => t.title.isNotEmpty)
        .toList(growable: false);
  }

  /// [window] 只接受 `24h` / `7d`：24h 取最新 10 条，7d 取评分最高的 10 条。
  Future<List<AiHotItem>> fetchSelected(String window) async {
    final isWeek = window == '7d';
    final uri =
        Uri.parse(itemsEndpoint).replace(queryParameters: <String, String>{
      'mode': 'selected',
      'window': isWeek ? '7d' : '24h',
      'limit': '${isWeek ? weekFetchLimit : fetchLimit}',
    });
    final root = await _get(uri.toString());
    _requireMap(root);
    final items = root['items'];
    if (items is! List || items.isEmpty) {
      throw const AiHotException('暂时没有精选资讯');
    }
    final parsed = items
        .whereType<Map>()
        .map((e) => AiHotItem.fromJson(Map<String, dynamic>.from(e)))
        .where((item) => item.title.isNotEmpty)
        .toList(growable: false);
    if (!isWeek) return parsed;
    final ranked = List<AiHotItem>.of(parsed)
      ..sort((a, b) => (b.score ?? 0).compareTo(a.score ?? 0));
    return ranked.take(fetchLimit).toList(growable: false);
  }

  Future<dynamic> _get(String url) async {
    final http.Response resp;
    try {
      resp = await _client.get(Uri.parse(url), headers: const <String, String>{
        'Accept': 'application/json',
        'User-Agent': 'aihot-api/2.0.0',
      }).timeout(timeout);
    } on TimeoutException {
      throw const AiHotException('请求超时，请检查网络后重试');
    } catch (e) {
      throw AiHotException('网络请求失败：$e');
    }
    if (resp.statusCode != 200) {
      throw AiHotException('服务返回 HTTP ${resp.statusCode}');
    }
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const AiHotException('返回内容不是有效的 JSON');
    }
  }

  static void _requireMap(dynamic decoded) {
    if (decoded is! Map) throw const AiHotException('返回格式异常');
  }

  void dispose() => _client.close();
}
