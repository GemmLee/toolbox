import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 每日新闻（数据模型）。
class DailyNews {
  const DailyNews({
    required this.date,
    required this.news,
    this.dayOfWeek = '',
    this.lunarDate = '',
    this.tip = '',
  });

  final String date;
  final List<String> news;
  final String dayOfWeek;
  final String lunarDate;
  final String tip;

  /// 从 60sAPI 的 `data` 节点解析。
  factory DailyNews.fromPayload(Map<String, dynamic> data) {
    final rawNews = data['news'];
    final items = rawNews is List
        ? rawNews
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    return DailyNews(
      date: (data['date'] ?? '').toString(),
      news: items,
      dayOfWeek: (data['day_of_week'] ?? '').toString(),
      lunarDate: (data['lunar_date'] ?? '').toString(),
      tip: (data['tip'] ?? '').toString(),
    );
  }

  /// 用源接口的字段名输出，缓存读取时可直接交给 [DailyNews.fromPayload]。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        'news': news,
        'day_of_week': dayOfWeek,
        'lunar_date': lunarDate,
        'tip': tip,
      };
}

/// 每日新闻请求异常（消息可直接展示）。
class DailyNewsException implements Exception {
  const DailyNewsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 60sAPI 每日新闻服务。
///
/// 接口：`GET https://60s.viki.moe/v2/60s`
/// 返回 `{code:200, data:{date, news:[...], tip, day_of_week, lunar_date, ...}}`。
class DailyNewsService {
  DailyNewsService({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  static const String endpoint = 'https://60s.viki.moe/v2/60s';

  final http.Client _client;
  final Duration timeout;

  Future<DailyNews> fetch() async {
    final http.Response resp;
    try {
      resp = await _client
          .get(Uri.parse(endpoint), headers: const <String, String>{
        'Accept': 'application/json',
      }).timeout(timeout);
    } on TimeoutException {
      throw const DailyNewsException('请求超时，请检查网络后重试');
    } catch (e) {
      throw DailyNewsException('网络请求失败：$e');
    }

    if (resp.statusCode != 200) {
      throw DailyNewsException('服务返回 HTTP ${resp.statusCode}');
    }

    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const DailyNewsException('返回内容不是有效的 JSON');
    }
    if (decoded is! Map) throw const DailyNewsException('返回格式异常');

    final code = decoded['code'];
    if (code != null && code.toString() != '200') {
      throw DailyNewsException('接口提示：${decoded['message'] ?? code}');
    }

    final data = decoded['data'];
    if (data is! Map) throw const DailyNewsException('返回数据为空');

    final news = DailyNews.fromPayload(Map<String, dynamic>.from(data));
    if (news.news.isEmpty) throw const DailyNewsException('今天还没有新闻数据');
    return news;
  }

  void dispose() => _client.close();
}
