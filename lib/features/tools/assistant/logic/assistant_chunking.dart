// 长文档分段与题目去重：纯算法，与网络/状态无关。

/// 触发分段转换的源文本长度阈值。
const int kChunkThreshold = 6000;

/// 单个分段的字符上限（留出提示词与输出预算）。
const int kChunkSize = 4000;

/// 题目去重键：题干（去空白）+ 答案，避免分段边界重复计入。
String questionKey(Map<String, dynamic> question) {
  final stem = (question['stem'] ?? '')
      .toString()
      .replaceAll(RegExp(r'\s+'), '')
      .trim();
  final answer = question['answer'];
  final text = answer is List ? answer.map((e) => '$e').join(',') : '$answer';
  return '$stem|$text';
}

/// 按行把长文档切成不超过 [max] 字符的分段，尽量在行边界断开。
List<String> splitForConversion(String text, {int max = kChunkSize}) {
  if (text.length <= max) return <String>[text];
  final chunks = <String>[];
  final buffer = StringBuffer();
  void flush() {
    final part = buffer.toString().trim();
    if (part.isNotEmpty) chunks.add(part);
    buffer.clear();
  }

  for (final line in text.split('\n')) {
    if (line.length > max) {
      flush();
      var rest = line;
      while (rest.length > max) {
        chunks.add(rest.substring(0, max));
        rest = rest.substring(max);
      }
      buffer.write(rest);
      buffer.write('\n');
      continue;
    }
    if (buffer.length + line.length + 1 > max && buffer.isNotEmpty) flush();
    buffer.write(line);
    buffer.write('\n');
  }
  flush();
  return chunks;
}
