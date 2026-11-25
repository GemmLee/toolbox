import '../data/quiz_models.dart';

/// 关键词搜索：把用户输入切成若干「词项」。
///
/// 中文没有天然的词边界，按空格 / 逗号 / 顿号 / 分号等显式分隔符切分；
/// 英文按整体词匹配（见 [containsExactTerm]），不做编辑距离模糊匹配。
/// 重复词项会去重，顺序保持不变。
List<String> splitKeywords(String query) {
  final parts = query.toLowerCase().split(RegExp(r'[\s,，、;；/\\|]+'));
  final out = <String>[];
  final seen = <String>{};
  for (final raw in parts) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'^["“”「」『』]+'), '')
        .replaceAll(RegExp(r'["“”「」『』]+$'), '');
    if (cleaned.isEmpty || cleaned.length > 64) continue;
    if (seen.add(cleaned)) out.add(cleaned);
  }
  return out;
}

/// 把词项转成 SQL LIKE 模式，转义 `%` `_` `\`，避免标点被当成通配符。
///
/// 配合 `ESCAPE '\'` 使用，见 [kKeywordLikeClause]。
String likePatternOf(String keyword) =>
    '%${keyword.replaceAll('\\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';

/// 每个词项的候选 SQL：题干 / 选项 / 解析 / 标签任一命中即入选。
///
/// 这里只是「粗筛」，最终是否命中与排序交给 [relevanceOf] 精确判定。
const String kKeywordLikeClause = "(q.stem LIKE ? ESCAPE '\\' "
    "OR q.optionsJson LIKE ? ESCAPE '\\' "
    "OR IFNULL(q.analysis, '') LIKE ? ESCAPE '\\' "
    "OR q.tagsJson LIKE ? ESCAPE '\\')";

bool _isAsciiWord(int unit) =>
    (unit >= 48 && unit <= 57) ||
    (unit >= 65 && unit <= 90) ||
    (unit >= 97 && unit <= 122);

/// 词项精确等同匹配：中文按连续子串命中；英文 / 数字要求前后不是字母数字，
/// 这样搜 `cat` 不会命中 `category`，搜 `1+1` 这类带符号的词仍按子串命中。
bool containsExactTerm(String haystack, String term) {
  if (term.isEmpty || haystack.isEmpty) return false;
  final text = haystack.toLowerCase();
  final asciiOnly = term.codeUnits.every(_isAsciiWord);
  var start = text.indexOf(term);
  while (start >= 0) {
    if (!asciiOnly) return true;
    final before = start == 0 ? null : text.codeUnitAt(start - 1);
    final after = start + term.length >= text.length
        ? null
        : text.codeUnitAt(start + term.length);
    if ((before == null || !_isAsciiWord(before)) &&
        (after == null || !_isAsciiWord(after))) {
      return true;
    }
    start = text.indexOf(term, start + 1);
  }
  return false;
}

/// 题干 / 选项 / 解析 / 标签的相关度权重。
const double kStemWeight = 3.0;
const double kOptionsWeight = 1.2;
const double kAnalysisWeight = 0.6;
const double kTagsWeight = 1.5;

/// 内部相关度：0 表示完全不命中，越大越相关。
///
/// 只用于结果排序，**不展示给用户**。命中词项数与命中位置共同决定分数：
/// 题干 > 标签 > 选项 > 解析；全部词项都命中的题目额外加权；字段内容
/// 与词项完全相同时再加成。分数归一到 (0, 1]。
double relevanceOf(Question question, List<String> keywords) {
  if (keywords.isEmpty) return 0;
  final fields = <(String text, double weight)>[
    (question.stem, kStemWeight),
    (question.options.map((o) => o.text).join(' '), kOptionsWeight),
    (question.analysis ?? '', kAnalysisWeight),
    (question.tags.join(' '), kTagsWeight),
  ];
  double score = 0;
  var matched = 0;
  for (final keyword in keywords) {
    var hit = false;
    for (final field in fields) {
      if (field.$1.isEmpty) continue;
      if (!containsExactTerm(field.$1, keyword)) continue;
      hit = true;
      score += field.$2;
      if (field.$1.trim().toLowerCase() == keyword) {
        score += field.$2 * 0.5;
      }
    }
    if (hit) matched++;
  }
  if (matched == 0) return 0;
  final coverage = matched / keywords.length;
  score = score * (0.6 + 0.4 * coverage) + 4.0 * coverage;
  final maxScore = keywords.length * 9.45 + 4.0;
  return (score / maxScore).clamp(0.0, 1.0);
}
