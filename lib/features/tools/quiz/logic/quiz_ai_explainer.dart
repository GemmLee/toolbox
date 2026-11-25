import 'dart:async';

import '../../../../core/settings/settings_controller.dart';
import '../../../../core/storage/local_store.dart';
import '../../assistant/data/assistant_api.dart';
import '../data/quiz_models.dart';

/// AI 解析的系统提示：只要考点，不要寒暄与长文。
const String kQuizAiSystemPrompt = '你是一位经验丰富的应试辅导老师。'
    '你的回答必须简短、准确、直接：先用一句话给出结论，再说明核心考点或易错点。'
    '不使用 Markdown 标题和加粗，不分点罗列，不使用客套话，总字数控制在 200 字以内。';

String _typeName(QuestionType type) => switch (type) {
      QuestionType.single => '单选题',
      QuestionType.multiple => '多选题',
      QuestionType.trueFalse => '判断题',
      QuestionType.fill => '填空题',
      QuestionType.short => '简答题',
    };

/// 构造解析提示词：把题面、选项、正确答案与用户作答一起交给模型。
String buildQuizExplainPrompt(Question q, {String? myAnswer}) {
  final buffer = StringBuffer()
    ..writeln('请解析下面这道题。')
    ..writeln()
    ..writeln('题型：${_typeName(q.type)}')
    ..writeln('题干：${q.stem.trim()}');

  if (q.options.isNotEmpty) {
    buffer.writeln('选项：');
    for (final o in q.options) {
      final mark = q.answer.contains(o.key) ? '（正确答案）' : '';
      buffer.writeln('${optionLabelOf(q, o)}$mark');
    }
  }

  if (q.answer.isNotEmpty) {
    final kind = q.type.hasOptions ? '正确答案' : '参考答案';
    buffer.writeln('题目给出的$kind：${answerLabelOf(q)}');
  }

  final mine = myAnswer?.trim() ?? '';
  if (mine.isNotEmpty) {
    final right = q.answer.any((a) => a.trim() == mine);
    final mineText = q.type == QuestionType.trueFalse
        ? (normalizeJudgeAnswer(mine) == 'true' ? '正确' : '错误')
        : mine;
    buffer.writeln('我的作答：$mineText（${right ? '对' : '错'}）');
  }

  if (q.hasAnalysis) {
    buffer.writeln('题目自带的解析（可参考，可纠正）：${q.analysis!.trim()}');
  }

  buffer
    ..writeln()
    ..writeln('要求：')
    ..writeln('1. 第一句直接给出答案结论与判断依据；')
    ..writeln('2. 用 2-3 句讲清关键考点'
        '${q.options.length > 1 ? '，并说明干扰项为什么错' : ''}；');
  if (mine.isNotEmpty && q.answer.any((a) => a.trim() != mine)) {
    buffer.writeln('3. 指出我的作答错在哪里（如有）；');
  }
  buffer.writeln('若题目或给出的答案本身有误，请直接说明「题目可能有误」及理由。');

  return buffer.toString().trim();
}

/// 轻量清洗模型输出：去掉 Markdown 记号，避免在纯文本区域显示 `**`。
String cleanAiAnalysis(String raw) {
  var text = raw.replaceAll('**', '').replaceAll('__', '');
  text = text.replaceAllMapped(
    RegExp(r'^[ \t]{0,3}#{1,6}[ \t]*', multiLine: true),
    (_) => '',
  );
  text = text.replaceAllMapped(
    RegExp(r'^[ \t]{0,3}[*-][ \t]+', multiLine: true),
    (_) => '· ',
  );
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

/// 题目 AI 解析：流式请求 + 本地缓存（同一道题只消耗一次 token）。
class QuizAiService {
  QuizAiService({OpenAiCompatClient? client, SettingsController? settings})
      : _client = client ?? OpenAiCompatClient(),
        _settings = settings ?? SettingsController.instance;

  /// 可被测试替换。
  static QuizAiService instance = QuizAiService();

  static const String cacheStoreKey = 'quiz_ai_analysis';
  static const int cacheLimit = 300;

  final OpenAiCompatClient _client;
  final SettingsController _settings;

  bool get configured => _settings.assistantConfigured;

  /// 未配置时的提示文案（UI 直接展示）。
  String get unconfiguredHint {
    final profile = _settings.activeAssistantProfile;
    if (profile == null || profile.apiKey.isEmpty) {
      return '请先在「用户 → AI 配置」中填写 API Key';
    }
    return '请先在「用户 → AI 配置」中补全模型或接口地址';
  }

  /// 缓存键带上内容指纹：题目被重新导入/编辑后不会命中旧解析。
  String cacheKeyOf(Question q) => '${q.bankId}/${q.id}/${q.contentHash}';

  Future<String?> cached(Question q) async {
    final map = await LocalStore.readMap(cacheStoreKey);
    final raw = map?[cacheKeyOf(q)];
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    return text;
  }

  Future<void> saveCache(Question q, String text) async {
    final trimmed = cleanAiAnalysis(text);
    if (trimmed.isEmpty) return;
    final map = await LocalStore.readMap(cacheStoreKey) ?? <String, dynamic>{};
    map[cacheKeyOf(q)] = <String, dynamic>{
      'text': trimmed,
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    if (map.length > cacheLimit) {
      final entries = map.entries.toList()
        ..sort((a, b) => _timeOf(a.value).compareTo(_timeOf(b.value)));
      for (final e in entries.take(map.length - cacheLimit)) {
        map.remove(e.key);
      }
    }
    await LocalStore.writeMap(cacheStoreKey, map);
  }

  Future<void> clearCache(Question q) async {
    final map = await LocalStore.readMap(cacheStoreKey);
    if (map == null || !map.containsKey(cacheKeyOf(q))) return;
    map.remove(cacheKeyOf(q));
    await LocalStore.writeMap(cacheStoreKey, map);
  }

  /// 流式生成解析。成功结束后自动写缓存并累计 token 用量。
  Stream<String> explain(Question q, {String? myAnswer}) async* {
    if (!configured) throw AssistantApiException(unconfiguredHint);

    final buffer = StringBuffer();
    var usageIn = 0;
    var usageOut = 0;

    await for (final delta in _client.streamChat(
      baseUrl: _settings.assistantBaseUrl,
      apiKey: _settings.assistantApiKey,
      model: _settings.assistantModel,
      messages: <ChatMessage>[
        const ChatMessage(role: 'system', content: kQuizAiSystemPrompt),
        ChatMessage.user(buildQuizExplainPrompt(q, myAnswer: myAnswer)),
      ],
      onUsage: (usage) {
        usageIn += usage.promptTokens;
        usageOut += usage.completionTokens;
      },
    )) {
      buffer.write(delta);
      yield delta;
    }

    final text = cleanAiAnalysis(buffer.toString());
    if (text.isNotEmpty) await saveCache(q, text);
    await _settings.addAssistantUsage(usageIn, usageOut);
  }

  static int _timeOf(Object? value) =>
      value is Map && value['at'] is int ? value['at'] as int : 0;
}
