import 'dart:async';
import 'dart:convert';

import '../../../../core/settings/settings_controller.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../assistant/data/assistant_api.dart';
import '../../assistant/data/skills.dart';
import '../../assistant/logic/assistant_chunking.dart';
import '../../assistant/logic/quiz_result.dart';

/// 转换进度：整体进度 0~1 + 当前状态文案。
class QuizConvertProgress {
  const QuizConvertProgress({
    required this.fraction,
    required this.label,
    required this.done,
    required this.total,
  });

  final double fraction;
  final String label;
  final int done;
  final int total;
}

/// 转换结果：可直接交给 [QuizImporter] 解析的题库 JSON。
class QuizConvertResult {
  const QuizConvertResult({
    required this.rawJson,
    required this.bankName,
    required this.count,
    this.warning,
  });

  final String rawJson;
  final String bankName;
  final int count;

  /// 部分段落转换失败时的提示（其余题目仍可用）。
  final String? warning;
}

/// 转换失败（message 可直接展示）。
class QuizConvertException implements Exception {
  const QuizConvertException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 题库 AI 转换服务：把文档正文交给内置「题库转换」技能，产出题库 JSON。
///
/// 与智能助手里点「题库转换」技能走同一套提示词与分段策略：
/// 长文档按行切段、逐段流式请求、解析成功即合并去重，全程回报进度，
/// 供刷题工具的「AI 导入」显示进度条。
class QuizAiConverter {
  QuizAiConverter({OpenAiCompatClient? client, SettingsController? settings})
      : _client = client ?? OpenAiCompatClient(),
        settings = settings ?? SettingsController.instance;

  final OpenAiCompatClient _client;
  final SettingsController settings;

  /// 单段最多重试次数。
  static const int _attempts = 3;

  bool get configured => settings.assistantConfigured;

  /// 转换失败时用于没有解析出 JSON 的提示。
  static const String _noJson = '该段没有解析出题库 JSON';

  /// 内置「题库转换」技能的系统提示词（与助手技能共用，避免两套规则漂移）。
  String get _systemPrompt {
    for (final s in SkillStore.builtIns) {
      if (s.id == SkillStore.quizSkillId) return s.prompt;
    }
    return kDefaultSystemPrompt;
  }

  /// 转换整份文档。
  ///
  /// [onProgress] 在每段开始与流式接收过程中回调；[cancelled] 返回 true 时
  /// 尽快中止并抛出 [QuizConvertException]。
  Future<QuizConvertResult> convert(
    String text, {
    void Function(QuizConvertProgress progress)? onProgress,
    bool Function()? cancelled,
  }) async {
    if (!configured) {
      throw const QuizConvertException(
          '未配置 AI，请先在「用户 → AI 配置」填写 API Key');
    }
    final source = text.trim();
    if (source.isEmpty) {
      throw const QuizConvertException('文件内容为空，没有可转换的题目');
    }

    final chunks = splitForConversion(source);
    final questions = <Map<String, dynamic>>[];
    final seen = <String>{};
    String? bankName;
    String? firstError;
    var failed = 0;
    var usageIn = 0;
    var usageOut = 0;

    for (var i = 0; i < chunks.length; i++) {
      if (cancelled?.call() ?? false) {
        throw const QuizConvertException('已取消转换');
      }
      final label = chunks.length == 1
          ? tr('正在转换题库')
          : trf('正在转换第 {i}/{n} 段', {'i': i + 1, 'n': chunks.length});
      onProgress?.call(QuizConvertProgress(
        fraction: i / chunks.length,
        label: label,
        done: i,
        total: chunks.length,
      ));

      final part = await _convertChunk(
        chunks[i],
        label: label,
        index: i,
        total: chunks.length,
        onProgress: onProgress,
        cancelled: cancelled,
        usage: (i2, o2) {
          usageIn += i2;
          usageOut += o2;
        },
      );
      if (part.questions == null) {
        failed++;
        firstError ??= part.error;
        continue;
      }
      if (bankName == null &&
          part.bankName != null &&
          part.bankName != tr('未命名题库')) {
        bankName = part.bankName;
      }
      for (final q in part.questions!) {
        if (!seen.add(questionKey(q))) continue;
        questions.add(q);
      }
    }

    if (usageIn > 0 || usageOut > 0) {
      await settings.addAssistantUsage(usageIn, usageOut);
    }
    if (questions.isEmpty) {
      throw QuizConvertException(
          trf('转换失败：{msg}', {'msg': firstError ?? tr('未获得结果')}));
    }
    final warning = failed > 0
        ? trf('有 {n} 段未能转换，已保留其余题目', {'n': failed})
        : null;

    final merged = <String, dynamic>{
      'version': 1,
      'bankName': bankName ?? _bankNameFromFile(text),
      'questions': <Map<String, dynamic>>[
        for (var i = 0; i < questions.length; i++)
          <String, dynamic>{
            ...questions[i],
            'id': 'q-${(i + 1).toString().padLeft(3, '0')}',
          },
      ],
    };
    onProgress?.call(QuizConvertProgress(
      fraction: 1,
      label: tr('转换完成'),
      done: chunks.length,
      total: chunks.length,
    ));
    return QuizConvertResult(
      rawJson: const JsonEncoder.withIndent('  ').convert(merged),
      bankName: merged['bankName'] as String,
      count: questions.length,
      warning: warning,
    );
  }

  /// 没有题库名时用正文首行兜底，避免落到「未命名题库」。
  String _bankNameFromFile(String text) {
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.length >= 2 && trimmed.length <= 40) return trimmed;
    }
    return tr('未命名题库');
  }

  /// 转换一段；失败自动重试，仍失败则对半拆开再转（深度一层）。
  Future<_ChunkPart> _convertChunk(
    String text, {
    required String label,
    required int index,
    required int total,
    void Function(QuizConvertProgress)? onProgress,
    bool Function()? cancelled,
    void Function(int input, int output)? usage,
    int depth = 0,
  }) async {
    String? error;
    for (var attempt = 1; attempt <= _attempts; attempt++) {
      if (cancelled?.call() ?? false) {
        return const _ChunkPart(error: '已取消转换');
      }
      final buffer = StringBuffer();
      var notified = 0;
      try {
        await for (final delta in _client.streamChat(
          baseUrl: settings.assistantBaseUrl,
          apiKey: settings.assistantApiKey,
          model: settings.assistantModel,
          messages: <ChatMessage>[
            ChatMessage(role: 'system', content: _systemPrompt),
            ChatMessage.user(total == 1 ? text : '$label\n$text'),
          ],
          onUsage: (u) => usage?.call(u.promptTokens, u.completionTokens),
        )) {
          if (cancelled?.call() ?? false) {
            return const _ChunkPart(error: '已取消转换');
          }
          buffer.write(delta);
          if (buffer.length - notified >= 200) {
            notified = buffer.length;
            onProgress?.call(QuizConvertProgress(
              fraction: _fractionOf(index, total, buffer.length, text.length),
              label: trf('{label} · 已接收 {n} 字符',
                  {'label': label, 'n': buffer.length}),
              done: index,
              total: total,
            ));
          }
        }
        final extract = extractQuizBankJson(buffer.toString());
        final parsed = extract == null ? null : _questionsOf(extract.raw);
        if (parsed != null && parsed.isNotEmpty) {
          return _ChunkPart(questions: parsed, bankName: extract!.bankName);
        }
        error = tr(_noJson);
      } catch (e) {
        error = describeNetworkError(e);
      }
      if (attempt < _attempts) {
        onProgress?.call(QuizConvertProgress(
          fraction: index / total,
          label: trf('{label} · 连接中断，正在重试（{i}/{n}）',
              {'label': label, 'i': attempt, 'n': _attempts - 1}),
          done: index,
          total: total,
        ));
        await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
      }
    }
    // 整段仍失败：对半拆开各转一次，避免整段内容白丢。
    if (depth == 0 && text.length > 1200) {
      final halves = _splitHalf(text);
      final merged = <Map<String, dynamic>>[];
      String? name;
      for (final half in halves) {
        final part = await _convertChunk(
          half,
          label: label,
          index: index,
          total: total,
          onProgress: onProgress,
          cancelled: cancelled,
          usage: usage,
          depth: 1,
        );
        final questions = part.questions;
        if (questions == null) return _ChunkPart(error: part.error ?? error);
        name ??= part.bankName;
        merged.addAll(questions);
      }
      return _ChunkPart(questions: merged, bankName: name);
    }
    return _ChunkPart(error: error);
  }

  /// 段内进度：接收字符数相对本段长度的估算（最多占该段的 95%）。
  double _fractionOf(int index, int total, int received, int sourceLen) {
    final ratio = sourceLen <= 0 ? 0.0 : (received / (sourceLen * 0.9)).clamp(0.0, 0.95);
    return ((index + ratio) / total).clamp(0.0, 1.0);
  }

  List<String> _splitHalf(String text) {
    final mid = text.length ~/ 2;
    var cut = text.lastIndexOf('\n', mid);
    if (cut < mid ~/ 2) cut = mid;
    return <String>[text.substring(0, cut), text.substring(cut)];
  }

  List<Map<String, dynamic>>? _questionsOf(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final list = decoded is Map ? decoded['questions'] : null;
      if (list is! List) return null;
      return <Map<String, dynamic>>[
        for (final item in list)
          if (item is Map) Map<String, dynamic>.from(item),
      ];
    } on FormatException {
      return null;
    }
  }
}

class _ChunkPart {
  const _ChunkPart({this.questions, this.bankName, this.error});

  final List<Map<String, dynamic>>? questions;
  final String? bankName;
  final String? error;
}
