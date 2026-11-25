import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';

/// 拍照搜题的一次匹配结果。
class PhotoMatch {
  const PhotoMatch({
    required this.question,
    required this.bankName,
    required this.score,
  });

  final Question question;
  final String bankName;

  /// 相似度 0~1，只用于挑最高分，不展示给用户。
  final double score;
}

/// 归一化：只保留字母、数字与汉字，去掉空白与标点。
///
/// OCR 出来的文字经常带换行、全角空格、题号顿号，不归一化会大幅拉低相似度。
String normalizeForMatch(String raw) =>
    raw.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

Set<String> _bigrams(String text) {
  if (text.isEmpty) return <String>{};
  if (text.length == 1) return <String>{text};
  final out = <String>{};
  for (var i = 0; i + 1 < text.length; i++) {
    out.add(text.substring(i, i + 2));
  }
  return out;
}

/// 两组二元组的 Dice 系数。
double _diceOf(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final small = a.length <= b.length ? a : b;
  final big = a.length <= b.length ? b : a;
  var inter = 0;
  for (final gram in small) {
    if (big.contains(gram)) inter++;
  }
  return 2 * inter / (a.length + b.length);
}

/// 两段文字的相似度（0~1）：中文按二元组 Dice 系数，再用包含关系兜底。
///
/// 不做分词，避免引入词典依赖；题目文字通常几十个字，二元组已经足够区分。
double similarityOf(String a, String b) {
  final na = normalizeForMatch(a);
  final nb = normalizeForMatch(b);
  return _similarityNormalized(na, nb);
}

double _similarityNormalized(String na, String nb) {
  if (na.isEmpty || nb.isEmpty) return 0;
  if (na == nb) return 1;
  // OCR 正段把题干整句包进去，几乎可以确定是同一题。
  if (na.length >= 6 && nb.contains(na)) return 0.98;
  if (nb.length >= 6 && na.contains(nb)) return 0.95;
  return _diceOf(_bigrams(na), _bigrams(nb));
}

/// OCR 文本里解析出来的题干与各个选项。
class ParsedOcr {
  const ParsedOcr({required this.stem, required this.options});

  final String stem;
  final List<String> options;
}

/// 选项标记：`A.` / `A、` / `A．` / `A)` / `A）` / `A:`，前面不能紧跟字母。
///
/// OCR 有时把多个选项挤在同一行，所以按标记切，而不是按行切。
final RegExp _optionMark =
    RegExp(r'(?<![A-Za-z])([A-Ha-hＡ-Ｈａ-ｈ])\s*[.．、)）:：]\s*');

/// 全角字母转半角：中文 OCR 常把 `A.` 识成 `Ａ．`。
String _halfWidthLetter(String raw) {
  final code = raw.codeUnitAt(0);
  if (code >= 0xFF21 && code <= 0xFF3A) {
    return String.fromCharCode(code - 0xFEE0);
  }
  if (code >= 0xFF41 && code <= 0xFF5A) {
    return String.fromCharCode(code - 0xFEE0);
  }
  return raw;
}

/// 从 OCR 整段文本里拆出题干与选项。
///
/// 认不出两个以上选项时返回整段作为题干、选项为空，调用方退回「只比题干」的口径。
ParsedOcr parseOcrStructured(String raw) {
  final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final marks = <RegExpMatch>[];
  final seen = <String>{};
  for (final m in _optionMark.allMatches(text)) {
    final letter = _halfWidthLetter(m.group(1)!).toUpperCase();
    // 同一个字母只认第一次，防止题干里的括号把 A/B 重复算进去。
    if (!seen.add(letter)) continue;
    marks.add(m);
  }
  if (marks.length < 2) {
    return ParsedOcr(stem: text, options: const <String>[]);
  }
  final options = <String>[];
  for (var i = 0; i < marks.length; i++) {
    final start = marks[i].end;
    final end = i + 1 < marks.length ? marks[i + 1].start : text.length;
    if (end <= start) continue;
    final body = text.substring(start, end).trim();
    if (body.isNotEmpty) options.add(body);
  }
  if (options.length < 2) {
    return ParsedOcr(stem: text, options: const <String>[]);
  }
  return ParsedOcr(stem: text.substring(0, marks.first.start).trim(), options: options);
}

/// 「题干 + 选项」口径的两道门槛：两边都要过线才算同一道题。
const double _structStemMin = 0.42;
const double _structOptionMin = 0.40;

/// 每个识别出的选项与题库选项逐个比，取各自最高分再平均。
///
/// 逐项取最大值意味着**选项顺序无关**：OCR 把 A/B 顺序读反、或漏掉一个字母，
/// 都不影响结果。
double _optionScoreOf(
  List<Set<String>> queryOptions,
  List<OptionItem> itemOptions,
) {
  if (queryOptions.isEmpty || itemOptions.isEmpty) return 0;
  final itemGrams = <Set<String>>[];
  for (final o in itemOptions) {
    final grams = _bigrams(normalizeForMatch(o.text));
    if (grams.isNotEmpty) itemGrams.add(grams);
  }
  if (itemGrams.isEmpty) return 0;
  var sum = 0.0;
  for (final q in queryOptions) {
    var best = 0.0;
    for (final o in itemGrams) {
      final d = _diceOf(q, o);
      if (d > best) best = d;
    }
    sum += best;
  }
  return sum / queryOptions.length;
}

/// 查询的二元组被某道题覆盖的比例：衡量「框到的字有多少是这条的内容」。
double _coverageOf(String query, String target) {
  if (query.isEmpty || target.isEmpty) return 0;
  if (query.length == 1) return target.contains(query) ? 1 : 0;
  final q = _bigrams(query);
  final t = _bigrams(target);
  if (q.isEmpty || t.isEmpty) return 0;
  var hit = 0;
  for (final gram in q) {
    if (t.contains(gram)) hit++;
  }
  return hit / q.length;
}

/// 在全部题目里找与 [ocrText] 最接近的一道。
///
/// **框到「题干 + 多个选项」时**（能从文本里解析出两个以上选项标记）：
/// 题干与选项各自算分，两边都要过线才算匹配，最终分取均值。这样只有题干像、
/// 选项完全对不上的题不会被当成答案；选项按内容逐项比对，与顺序无关。
///
/// **只框到题干、或只框到选项时**：题干、题干+选项、仅选项三路取最高。
///
/// 低于 [minScore] 视为没匹配到，返回 null。
///
/// [bankIds] 非空时只在这些题库里找（便捷搜题限定范围时用）。
Future<PhotoMatch?> bestMatchForText(
  QuizRepository repo,
  String ocrText, {
  double minScore = 0.30,
  String? bankId,
  Set<String>? bankIds,
}) async {
  final normalized = normalizeForMatch(ocrText);
  if (normalized.length < 2) return null;
  final candidates = await repo.allQuestionsWithBank(
    bankId: bankId,
    bankIds: bankIds,
  );

  final parsed = parseOcrStructured(ocrText);
  final stemNorm = normalizeForMatch(parsed.stem);
  // 题干太短（比如只框到「下列说法正确的是」）就不拿来当约束。
  final structured = parsed.options.length >= 2 && stemNorm.length >= 6;
  if (structured) {
    final stemGrams = _bigrams(stemNorm);
    final queryOptions = <Set<String>>[];
    for (final o in parsed.options) {
      final grams = _bigrams(normalizeForMatch(o));
      if (grams.isNotEmpty) queryOptions.add(grams);
    }
    if (stemGrams.isEmpty || queryOptions.length < 2) {
      return _bestByEvidence(candidates, normalized, minScore);
    }
    PhotoMatch? best;
    for (final item in candidates) {
      final question = item.question;
      final stemScore = _diceOf(stemGrams, _bigrams(normalizeForMatch(question.stem)));
      if (stemScore < _structStemMin) continue;
      final optionScore = _optionScoreOf(queryOptions, question.options);
      if (optionScore < _structOptionMin) continue;
      // 两边都过线才排高低；用均值，避免只看单边。
      final score = (stemScore + optionScore) / 2;
      if (score <= minScore) continue;
      if (best == null || score > best.score) {
        best = PhotoMatch(
          question: question,
          bankName: item.bankName,
          score: score,
        );
      }
    }
    // 解析出选项就以此为准：没对上就是没对上，不退回去只比题干。
    return best;
  }

  return _bestByEvidence(candidates, normalized, minScore);
}

/// 题库 + 来源题库名（与仓库里的 record 类型一致）。
typedef _QuestionWithBank = ({Question question, String bankName});

/// 只有一侧证据时：题干、题干+选项、仅选项三路取最高。
PhotoMatch? _bestByEvidence(
  List<_QuestionWithBank> candidates,
  String normalized,
  double minScore,
) {
  // 太短的 OCR 文本（比如只认出一个选项）不参与选项口径，避免乱配。
  final optionsUsable = normalized.length >= 8;
  PhotoMatch? best;
  for (final item in candidates) {
    final question = item.question;
    final stem = normalizeForMatch(question.stem);
    final optionsText = normalizeForMatch(
      question.options.map((o) => o.text).join(''),
    );
    final whole = stem + optionsText;

    var base = _similarityNormalized(normalized, stem);
    if (optionsUsable && optionsText.isNotEmpty) {
      final wholeScore = _similarityNormalized(normalized, whole) * 0.97;
      if (wholeScore > base) base = wholeScore;
      final optionScore = _similarityNormalized(normalized, optionsText) * 0.88;
      if (optionScore > base) base = optionScore;
    }
    if (base <= 0) continue;

    final score = base * (0.92 + 0.08 * _coverageOf(normalized, whole));
    if (score <= minScore) continue;
    if (best == null || score > best.score) {
      best = PhotoMatch(
        question: question,
        bankName: item.bankName,
        score: score,
      );
    }
  }
  return best;
}
