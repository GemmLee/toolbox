import '../../../core/storage/local_store.dart';
import 'aihot_api.dart';
import 'news_api.dart';

/// 一份 AI 速递缓存：热点榜 + 各时间窗的精选列表。
class AiNewsSnapshot {
  const AiNewsSnapshot({
    required this.hot,
    required this.itemsByWindow,
  });

  final List<AiHotTopic>? hot;
  final Map<String, List<AiHotItem>> itemsByWindow;

  List<AiHotItem>? itemsFor(String window) => itemsByWindow[window];
}

/// 每日新闻 / AI速递的离线缓存。
///
/// 两个版面各自记时间，超过 [maxAge] 即视为过期；手动刷新会覆盖缓存并
/// 重置时间。数据结构与接口原字段一致，缓存损坏时按无缓存处理。
class NewsCache {
  NewsCache({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const String storageKey = 'daily_news_offline_cache';
  static const Duration maxAge = Duration(hours: 24);

  final DateTime Function() _now;

  Future<Map<String, dynamic>> _read() async =>
      await LocalStore.readMap(storageKey) ?? <String, dynamic>{};

  Future<void> _write(Map<String, dynamic> map) =>
      LocalStore.writeMap(storageKey, map);

  bool _fresh(Map<String, dynamic> map, String timeKey) {
    final ts = (map[timeKey] as num?)?.toInt();
    if (ts == null) return false;
    final age = _now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
    return age >= Duration.zero && age < maxAge;
  }

  Future<DailyNews?> readDaily() async {
    final map = await _read();
    if (!_fresh(map, 'dailyAt')) return null;
    final raw = map['daily'];
    if (raw is! Map) return null;
    try {
      return DailyNews.fromPayload(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveDaily(DailyNews news) async {
    final map = await _read();
    map['daily'] = news.toJson();
    map['dailyAt'] = _now().millisecondsSinceEpoch;
    await _write(map);
  }

  Future<AiNewsSnapshot?> readAi() async {
    final map = await _read();
    if (!_fresh(map, 'aiAt')) return null;

    List<AiHotTopic>? hot;
    final rawHot = map['hot'];
    if (rawHot is List) {
      final parsed = rawHot
          .whereType<Map>()
          .map((e) => AiHotTopic.fromJson(Map<String, dynamic>.from(e)))
          .where((t) => t.title.isNotEmpty)
          .toList(growable: false);
      if (parsed.isNotEmpty) hot = parsed;
    }

    final items = <String, List<AiHotItem>>{};
    final rawItems = map['items'];
    if (rawItems is Map) {
      for (final entry in rawItems.entries) {
        if (entry.value is! List) continue;
        final parsed = (entry.value as List)
            .whereType<Map>()
            .map((e) => AiHotItem.fromJson(Map<String, dynamic>.from(e)))
            .where((i) => i.title.isNotEmpty)
            .toList(growable: false);
        if (parsed.isNotEmpty) items[entry.key.toString()] = parsed;
      }
    }

    if (hot == null && items.isEmpty) return null;
    return AiNewsSnapshot(hot: hot, itemsByWindow: items);
  }

  Future<List<AiHotItem>?> readAiItems(String window) async {
    final snapshot = await readAi();
    return snapshot?.itemsByWindow[window];
  }

  Future<void> saveAiHot(List<AiHotTopic> hot) async {
    final map = await _read();
    map['hot'] = hot.map((e) => e.toJson()).toList(growable: false);
    map['aiAt'] = _now().millisecondsSinceEpoch;
    await _write(map);
  }

  Future<void> saveAiItems(String window, List<AiHotItem> items) async {
    final map = await _read();
    final all = <String, dynamic>{};
    final raw = map['items'];
    if (raw is Map) {
      raw.forEach((key, value) => all[key.toString()] = value);
    }
    all[window] = items.map((e) => e.toJson()).toList(growable: false);
    map['items'] = all;
    map['aiAt'] = _now().millisecondsSinceEpoch;
    await _write(map);
  }

  Future<void> clear() => LocalStore.remove(storageKey);
}
