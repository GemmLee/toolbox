import '../../../../core/platform/pinyin.dart';

/// 首字母搜索的公共逻辑：查询串归一 + 题干首字母缓存。
///
/// 首字母来自原生 ICU（见 [PinyinBridge]），一次批量转换比逐题往返便宜得多，
/// 所以按「文本 → 首字母串」缓存在内存里：题库里反复出现的题干、选项共用同一份。
class QuizInitials {
  QuizInitials._();

  /// 缓存上限；题库特别大时简单丢弃重建，不做 LRU。
  static const int _maxCache = 12000;

  static final Map<String, String> _cache = <String, String>{};

  /// 最近一次转换是否得到系统支持：null 表示还没试过。
  static bool? _supported;

  /// 测试注入：替换原生通道，返回 `(supported, initials)`。
  static Future<({bool supported, List<String> initials})?> Function(
    List<String> texts,
  )? debugConverter;

  static bool? get supported => _supported;

  static void resetForTest() {
    _cache.clear();
    _supported = null;
    debugConverter = null;
  }

  /// 查询串归一：只保留英文字母并转小写。
  ///
  /// `AQ`、`a q`、`a-q` 都归一成 `aq`；输入纯汉字时得到空串，调用方应提示
  /// 首字母模式只能输字母。
  static String normalizeQuery(String raw) =>
      raw.toLowerCase().replaceAll(RegExp('[^a-z]'), '');

  /// 空格 / 常见标点分隔出多个首字母片段，逐段归一、去重、限长。
  ///
  /// 与便捷搜题原生侧的 `splitTerms` 同一口径：`zgdd sh` 得到
  /// `['zgdd', 'sh']`，而不是被拼成 `zgddsh` 一整串后无处可搜。
  static List<String> splitQuery(String raw) {
    final terms = <String>[];
    final seen = <String>{};
    for (final part in raw.toLowerCase().split(RegExp(r'[\s,，、;；/\\|]+'))) {
      final term = normalizeQuery(part);
      if (term.isEmpty || term.length > 64 || !seen.add(term)) continue;
      terms.add(term);
    }
    return terms;
  }

  /// 批量取首字母串，顺序与 [texts] 一致；系统不支持时统一返回空串。
  static Future<List<String>> initialsOf(List<String> texts) async {
    if (texts.isEmpty) return const <String>[];
    final missing = <String>{};
    for (final text in texts) {
      if (!_cache.containsKey(text)) missing.add(text);
    }
    if (missing.isNotEmpty) {
      final result = await (debugConverter ?? PinyinBridge.initialsOf)(
        missing.toList(),
      );
      if (result == null || !result.supported) {
        _supported = false;
        return List<String>.filled(texts.length, '');
      }
      _supported = true;
      final keys = missing.toList(growable: false);
      for (var i = 0; i < keys.length && i < result.initials.length; i++) {
        _cache[keys[i]] = result.initials[i];
      }
      if (_cache.length > _maxCache) _cache.clear();
    }
    return <String>[for (final text in texts) _cache[text] ?? ''];
  }
}
