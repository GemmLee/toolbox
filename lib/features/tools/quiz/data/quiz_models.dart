import 'dart:convert';
import 'dart:math';

import '../../../../core/settings/tool_texts.dart';

/// 选项在界面上的文本。
///
/// 判断题的 key 是判分用的 `true` / `false`，不是题面标号，不能像
/// 单选那样拼成「true. 正确」；只显示「正确 / 错误」。其余题型保留 A./B. 标号。
String optionLabelOf(Question q, OptionItem o) =>
    q.type == QuestionType.trueFalse
        ? (o.key == 'false' ? tr('错误') : tr('正确'))
        : '${o.key}. ${o.text}';

/// 答案在界面上的文本。
///
/// 判断题把内部 `true` / `false` 翻译成中文，不把标识符暴露给用户；
/// 简答用中文分号，其余用顿号。
String answerLabelOf(Question q) {
  if (q.type == QuestionType.trueFalse) {
    return q.answer.map((a) => a == 'true' ? tr('正确') : tr('错误')).join('、');
  }
  return q.answer.join(q.type == QuestionType.short ? '；' : '、');
}

/// 把 AI / 源文档里常见的判断题标识符归一成判分用的 `true` / `false`。
/// 无法识别时返回 null，由调用方按原值处理。
String? normalizeJudgeAnswer(String raw) {
  final v = raw.trim().toLowerCase();
  const yes = <String>{
    'true',
    't',
    'yes',
    'y',
    '1',
    'a',
    '√',
    '✓',
    '对',
    '正确',
    '是'
  };
  const no = <String>{
    'false',
    'f',
    'no',
    'n',
    '0',
    'b',
    '×',
    'x',
    '✗',
    '错',
    '错误',
    '否'
  };
  if (yes.contains(v)) return 'true';
  if (no.contains(v)) return 'false';
  return null;
}

/// 判断题的固定选项：key 参与判分，文本只作兜底（界面按 key 取「正确 / 错误」）。
///
/// 导入、编辑、读库三条路径都必须落这两个选项——答题页的选项列表直接来自
/// `question.options`，缺了就只剩一个空白的判断题。
const List<OptionItem> kJudgeOptions = <OptionItem>[
  OptionItem(key: 'true', text: '正确'),
  OptionItem(key: 'false', text: '错误'),
];

/// 稳定标识生成（UUID v4 形状，本地生成，不依赖第三方包）。
String newId() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// FNV-1a 32 位哈希：题目内容指纹，用于导入去重提示。
String contentHashOf(String text) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(text)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// 题型。
enum QuestionType { single, multiple, trueFalse, fill, short }

extension QuestionTypeExt on QuestionType {
  String get key => switch (this) {
        QuestionType.single => 'single',
        QuestionType.multiple => 'multiple',
        QuestionType.trueFalse => 'true_false',
        QuestionType.fill => 'fill',
        QuestionType.short => 'short',
      };

  /// 客观题（可自动判分）。
  bool get autoGradable => this != QuestionType.short;

  /// 选项题（单选/多选/判断）。
  bool get hasOptions =>
      this == QuestionType.single ||
      this == QuestionType.multiple ||
      this == QuestionType.trueFalse;

  static QuestionType? fromKey(String? value) => switch (value) {
        'single' => QuestionType.single,
        'multiple' => QuestionType.multiple,
        'true_false' || 'trueFalse' || 'boolean' => QuestionType.trueFalse,
        'fill' || 'fill_blank' || 'blank' => QuestionType.fill,
        'short' || 'short_answer' || 'essay' => QuestionType.short,
        _ => null,
      };
}

/// 全部题型（固定顺序，UI 与统计复用）。
const List<QuestionType> allQuestionTypes = <QuestionType>[
  QuestionType.single,
  QuestionType.multiple,
  QuestionType.trueFalse,
  QuestionType.fill,
  QuestionType.short,
];

/// 选项。
class OptionItem {
  const OptionItem({required this.key, required this.text});

  final String key;
  final String text;

  Map<String, dynamic> toJson() => <String, dynamic>{'key': key, 'text': text};

  static OptionItem? fromJson(Object? raw) {
    if (raw is Map) {
      final key = raw['key']?.toString();
      final text = raw['text']?.toString();
      if (key != null && text != null) return OptionItem(key: key, text: text);
      return null;
    }
    if (raw is String) return OptionItem(key: raw, text: raw);
    return null;
  }

  @override
  String toString() => '$key. $text';
}

/// 题目。
class Question {
  const Question({
    required this.id,
    required this.bankId,
    required this.type,
    required this.stem,
    this.importId,
    this.options = const <OptionItem>[],
    this.answer = const <String>[],
    this.analysis,
    this.tags = const <String>[],
    this.difficulty,
    this.score,
    this.contentHash = '',
    this.orderNo = 0,
  });

  final String id;

  /// 所属题库。
  final String bankId;

  /// 导入文件中的 id（同题库内唯一，用于重复导入提示）。
  final String? importId;

  final QuestionType type;
  final String stem;

  /// 选项（单选/多选/判断）。
  final List<OptionItem> options;

  /// 正确答案：选项 key 数组，或填空的可接受答案数组。
  final List<String> answer;

  /// 解析，为空时 UI 显示「暂无解析」。
  final String? analysis;
  final List<String> tags;

  /// 难度 1-5。
  final int? difficulty;

  /// 单题分值（优先于题型分值、全局分值）。
  final double? score;
  final String contentHash;

  /// 题库内排序。
  final int orderNo;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'bankId': bankId,
        'importId': importId,
        'type': type.key,
        'stem': stem,
        'options': options.map((o) => o.toJson()).toList(),
        'answer': answer,
        'analysis': analysis,
        'tags': tags,
        'difficulty': difficulty,
        'score': score,
        'contentHash': contentHash,
        'orderNo': orderNo,
      };

  static Question fromRow(Map<String, Object?> row) {
    final type =
        QuestionTypeExt.fromKey(row['type'] as String?) ?? QuestionType.single;
    final options = _options(row['optionsJson'] as String?);
    return Question(
      id: row['id'] as String,
      bankId: row['bankId'] as String,
      importId: row['importId'] as String?,
      type: type,
      stem: row['stem'] as String? ?? '',
      // 旧数据里判断题的 options 可能被编辑页清空过，读回时补齐固定两项，
      // 否则答题页 / 详情页都没有「正确 / 错误」可选。
      options: type == QuestionType.trueFalse && options.isEmpty
          ? kJudgeOptions
          : options,
      answer: _strings(row['answerJson'] as String?),
      analysis: (row['analysis'] as String?)?.isEmpty ?? true
          ? null
          : row['analysis'] as String?,
      tags: _strings(row['tagsJson'] as String?),
      difficulty: row['difficulty'] as int?,
      score: (row['score'] as num?)?.toDouble(),
      contentHash: row['contentHash'] as String? ?? '',
      orderNo: row['orderNo'] as int? ?? 0,
    );
  }

  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'bankId': bankId,
        'importId': importId,
        'type': type.key,
        'stem': stem,
        'optionsJson': jsonEncode(options.map((o) => o.toJson()).toList()),
        'answerJson': jsonEncode(answer),
        'analysis': analysis,
        'tagsJson': jsonEncode(tags),
        'difficulty': difficulty,
        'score': score,
        'contentHash': contentHash,
        'orderNo': orderNo,
      };

  Question copyWith({String? bankId, String? importId}) => Question(
        id: id,
        bankId: bankId ?? this.bankId,
        importId: importId ?? this.importId,
        type: type,
        stem: stem,
        options: options,
        answer: answer,
        analysis: analysis,
        tags: tags,
        difficulty: difficulty,
        score: score,
        contentHash: contentHash,
        orderNo: orderNo,
      );

  /// 编辑题目内容（题干 / 选项 / 答案 / 解析）后生成新对象。
  /// contentHash 必须与导入时的口径一致，否则重复导入去重会失真。
  Question withContent({
    required String stem,
    required List<OptionItem> options,
    required List<String> answer,
    String? analysis,
  }) {
    final hash = contentHashOf('${type.key}|$stem|'
        '${options.map((o) => '${o.key}:${o.text}').join('|')}|'
        '${answer.join('|')}');
    return Question(
      id: id,
      bankId: bankId,
      importId: importId,
      type: type,
      stem: stem,
      options: options,
      answer: answer,
      analysis: analysis,
      tags: tags,
      difficulty: difficulty,
      score: score,
      contentHash: hash,
      orderNo: orderNo,
    );
  }

  /// 是否已有解析。
  bool get hasAnalysis => analysis != null && analysis!.trim().isNotEmpty;

  static List<OptionItem> _options(String? raw) {
    if (raw == null || raw.isEmpty) return const <OptionItem>[];
    final list = jsonDecode(raw);
    if (list is! List) return const <OptionItem>[];
    return list
        .map(OptionItem.fromJson)
        .whereType<OptionItem>()
        .toList(growable: false);
  }

  static List<String> _strings(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    final list = jsonDecode(raw);
    if (list is! List) return const <String>[];
    return list.map((e) => e.toString()).toList(growable: false);
  }
}

/// 题库。
class Bank {
  const Bank({
    required this.id,
    required this.name,
    this.importId,
    this.description,
    this.createdAt = 0,
    this.questionCount = 0,
    this.wrongCount = 0,
    this.favoriteCount = 0,
  });

  final String id;
  final String name;

  /// 导入文件中的题库 id（可为空）。
  final String? importId;
  final String? description;
  final int createdAt;

  /// 题目数（列表展示用，由查询填充）。
  final int questionCount;

  /// 该题库自己的错题数 / 收藏数（各题库互不相通）。
  final int wrongCount;
  final int favoriteCount;

  Bank copyWith({String? name, String? description, int? questionCount}) =>
      Bank(
        id: id,
        name: name ?? this.name,
        importId: importId,
        description: description ?? this.description,
        createdAt: createdAt,
        questionCount: questionCount ?? this.questionCount,
        wrongCount: wrongCount,
        favoriteCount: favoriteCount,
      );

  static Bank fromRow(Map<String, Object?> row) => Bank(
        id: row['id'] as String,
        name: row['name'] as String? ?? '',
        importId: row['importId'] as String?,
        description: row['description'] as String?,
        createdAt: row['createdAt'] as int? ?? 0,
        questionCount: row['questionCount'] as int? ?? 0,
        wrongCount: row['wrongCount'] as int? ?? 0,
        favoriteCount: row['favoriteCount'] as int? ?? 0,
      );

  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'name': name,
        'importId': importId,
        'description': description,
        'createdAt': createdAt,
      };
}

/// 练习 / 考试模式。
enum QuizMode { all, random, wrong, favorite, exam }

extension QuizModeExt on QuizMode {
  String get key => switch (this) {
        QuizMode.all => 'all',
        QuizMode.random => 'random',
        QuizMode.wrong => 'wrong',
        QuizMode.favorite => 'favorite',
        QuizMode.exam => 'exam',
      };

  /// 错题练习：答对自动移出错题本。
  bool get isWrongDrill => this == QuizMode.wrong;

  /// 考试：答题中不显示答案与解析，交卷后统一判分。
  bool get isExam => this == QuizMode.exam;

  static QuizMode? fromKey(String? value) => switch (value) {
        'all' => QuizMode.all,
        'random' => QuizMode.random,
        'wrong' => QuizMode.wrong,
        'favorite' => QuizMode.favorite,
        'exam' => QuizMode.exam,
        _ => null,
      };
}

/// 会话状态。
enum SessionStatus { active, submitted }

extension SessionStatusExt on SessionStatus {
  String get key => this == SessionStatus.active ? 'active' : 'submitted';
  static SessionStatus fromKey(String? value) =>
      value == 'submitted' ? SessionStatus.submitted : SessionStatus.active;
}

/// 考试 / 练习配置（存 sessions.configJson）。
class QuizConfig {
  const QuizConfig({
    this.typeCounts = const <QuestionType, int>{},
    this.scoreEnabled = false,
    this.globalScore,
    this.typeScores = const <QuestionType, double>{},
    this.durationSec,
    this.shuffleOptions = true,
    this.shuffleQuestions = true,
    this.onlyUnseen = false,
    this.lockAfterConfirm = false,
    this.autoNextOnCorrect = false,
    this.wrongRemoveThreshold = 1,
    this.simpleMode = false,
    this.studyMode = false,
  });

  /// 随机 / 考试模式下各题型抽题数量。
  final Map<QuestionType, int> typeCounts;

  /// 计分模式开关（关闭则为对错模式）。
  final bool scoreEnabled;

  /// 全局每题分值。
  final double? globalScore;

  /// 题型分值（优先级低于单题分值）。
  final Map<QuestionType, double> typeScores;

  /// 时长（秒），null 为不限时。
  final int? durationSec;

  final bool shuffleOptions;
  final bool shuffleQuestions;

  /// 只抽「没做过」的题：跳过历史会话里已经作答过的题目。
  /// 抽到但没作答的题仍算没做过；练习、随机、考试、错题、收藏都可用。
  final bool onlyUnseen;

  /// 确认答案后锁定本题，不能再改选项（默认关）。
  final bool lockAfterConfirm;

  /// 确认后答对自动切到下一题（默认关）。
  final bool autoNextOnCorrect;

  /// 错题练习里累计答对多少次才把该题移出错题本，默认 1 次。
  final int wrongRemoveThreshold;

  /// 简易刷题（默认关）：单选 / 判断选完即自动确认，且去掉上一题 / 下一题
  /// 按钮，只靠左右滑动翻页，减少一次点击。
  final bool simpleMode;

  /// 背题模式（默认关）：进入即显示正确答案与解析，只翻看不作答、不计分、
  /// 不写入练习记录 / 错题本。会话由 [QuizSessionController.startStudy] 建立。
  final bool studyMode;

  bool get timed => durationSec != null && durationSec! > 0;

  QuizConfig copyWith({
    Map<QuestionType, int>? typeCounts,
    bool? scoreEnabled,
    double? globalScore,
    Map<QuestionType, double>? typeScores,
    int? durationSec,
    bool? shuffleOptions,
    bool? shuffleQuestions,
    bool? onlyUnseen,
    bool? lockAfterConfirm,
    bool? autoNextOnCorrect,
    int? wrongRemoveThreshold,
    bool? simpleMode,
    bool? studyMode,
  }) =>
      QuizConfig(
        typeCounts: typeCounts ?? this.typeCounts,
        scoreEnabled: scoreEnabled ?? this.scoreEnabled,
        globalScore: globalScore ?? this.globalScore,
        typeScores: typeScores ?? this.typeScores,
        durationSec: durationSec ?? this.durationSec,
        shuffleOptions: shuffleOptions ?? this.shuffleOptions,
        shuffleQuestions: shuffleQuestions ?? this.shuffleQuestions,
        onlyUnseen: onlyUnseen ?? this.onlyUnseen,
        lockAfterConfirm: lockAfterConfirm ?? this.lockAfterConfirm,
        autoNextOnCorrect: autoNextOnCorrect ?? this.autoNextOnCorrect,
        wrongRemoveThreshold: wrongRemoveThreshold ?? this.wrongRemoveThreshold,
        simpleMode: simpleMode ?? this.simpleMode,
        studyMode: studyMode ?? this.studyMode,
      );

  /// 分值优先级：单题 score > 题型分值 > 全局分值。
  double scoreOf(Question q) =>
      q.score ?? typeScores[q.type] ?? globalScore ?? 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'typeCounts': typeCounts.map((k, v) => MapEntry(k.key, v)),
        'scoreEnabled': scoreEnabled,
        'globalScore': globalScore,
        'typeScores': typeScores.map((k, v) => MapEntry(k.key, v)),
        'durationSec': durationSec,
        'shuffleOptions': shuffleOptions,
        'shuffleQuestions': shuffleQuestions,
        'onlyUnseen': onlyUnseen,
        'lockAfterConfirm': lockAfterConfirm,
        'autoNextOnCorrect': autoNextOnCorrect,
        'wrongRemoveThreshold': wrongRemoveThreshold,
        'simpleMode': simpleMode,
        'studyMode': studyMode,
      };

  static QuizConfig fromJson(Object? raw) {
    if (raw is! Map) return const QuizConfig();
    final counts = <QuestionType, int>{};
    final rawCounts = raw['typeCounts'];
    if (rawCounts is Map) {
      rawCounts.forEach((key, value) {
        final type = QuestionTypeExt.fromKey(key?.toString());
        final n = value is num ? value.toInt() : int.tryParse('$value');
        if (type != null && n != null && n > 0) counts[type] = n;
      });
    }
    final scores = <QuestionType, double>{};
    final rawScores = raw['typeScores'];
    if (rawScores is Map) {
      rawScores.forEach((key, value) {
        final type = QuestionTypeExt.fromKey(key?.toString());
        final n = value is num
            ? value.toDouble()
            : double.tryParse(value?.toString() ?? '');
        if (type != null && n != null) scores[type] = n;
      });
    }
    final global = raw['globalScore'];
    final dur = raw['durationSec'];
    return QuizConfig(
      typeCounts: counts,
      scoreEnabled: raw['scoreEnabled'] == true,
      globalScore: global is num
          ? global.toDouble()
          : double.tryParse(global?.toString() ?? ''),
      typeScores: scores,
      durationSec:
          dur is num ? dur.toInt() : int.tryParse(dur?.toString() ?? ''),
      shuffleOptions: raw['shuffleOptions'] != false,
      shuffleQuestions: raw['shuffleQuestions'] != false,
      onlyUnseen: raw['onlyUnseen'] == true,
      lockAfterConfirm: raw['lockAfterConfirm'] == true,
      autoNextOnCorrect: raw['autoNextOnCorrect'] == true,
      wrongRemoveThreshold: (raw['wrongRemoveThreshold'] is num
              ? (raw['wrongRemoveThreshold'] as num).toInt()
              : int.tryParse('${raw['wrongRemoveThreshold'] ?? ''}') ?? 1)
          .clamp(1, 99),
      simpleMode: raw['simpleMode'] == true,
      studyMode: raw['studyMode'] == true,
    );
  }
}

/// 练习 / 考试会话。
class QuizSession {
  const QuizSession({
    required this.id,
    required this.mode,
    required this.status,
    required this.startedAt,
    this.bankId,
    this.config = const QuizConfig(),
    this.elapsedMs = 0,
    this.durationSec,
    this.scoreEnabled = false,
    this.totalScore = 0,
    this.maxScore = 0,
    this.finishedAt,
    this.lastIndex = 0,
    this.activeAt = 0,
  });

  final String id;
  final String? bankId;
  final QuizMode mode;
  final QuizConfig config;
  final SessionStatus status;
  final int startedAt;

  /// 已用时（毫秒），断点续答依赖它。
  final int elapsedMs;

  /// 考试时长（秒），null 为不限时。
  final int? durationSec;
  final bool scoreEnabled;
  final double totalScore;
  final double maxScore;
  final int? finishedAt;

  /// 上次刷到的题号（0 基），断点续答时据此回到原位置。
  final int lastIndex;

  /// 最近一次动过的时刻（毫秒）。首页「继续上次」按它排序：
  /// 同时有多套没刷完时，要回到刚放下的那套，而不是创建时间最晚的那套。
  final int activeAt;

  /// 兼容旧数据：v4 之前的会话没有 activeAt，退回创建时间。
  int get lastActiveAt => activeAt > 0 ? activeAt : startedAt;

  bool get isExam => mode.isExam;
  bool get timed => durationSec != null && durationSec! > 0;

  /// 剩余毫秒（不限时为 null）。
  int get remainMs => timed ? durationSec! * 1000 - elapsedMs : -1; // -1：不限时

  bool get expired => timed && remainMs <= 0;

  QuizSession copyWith({
    QuizConfig? config,
    SessionStatus? status,
    int? elapsedMs,
    double? totalScore,
    double? maxScore,
    int? finishedAt,
    int? lastIndex,
    int? activeAt,
  }) =>
      QuizSession(
        id: id,
        bankId: bankId,
        mode: mode,
        config: config ?? this.config,
        status: status ?? this.status,
        startedAt: startedAt,
        elapsedMs: elapsedMs ?? this.elapsedMs,
        durationSec: durationSec,
        scoreEnabled: scoreEnabled,
        totalScore: totalScore ?? this.totalScore,
        maxScore: maxScore ?? this.maxScore,
        finishedAt: finishedAt ?? this.finishedAt,
        lastIndex: lastIndex ?? this.lastIndex,
        activeAt: activeAt ?? this.activeAt,
      );

  static QuizSession fromRow(Map<String, Object?> row) => QuizSession(
        id: row['id'] as String,
        bankId: row['bankId'] as String?,
        mode: QuizModeExt.fromKey(row['mode'] as String?) ?? QuizMode.all,
        config: QuizConfig.fromJson(_decode(row['configJson'] as String?)),
        status: SessionStatusExt.fromKey(row['status'] as String?),
        startedAt: row['startedAt'] as int? ?? 0,
        elapsedMs: row['elapsedMs'] as int? ?? 0,
        durationSec: row['durationSec'] as int?,
        scoreEnabled: (row['scoreEnabled'] as int? ?? 0) == 1,
        totalScore: (row['totalScore'] as num?)?.toDouble() ?? 0,
        maxScore: (row['maxScore'] as num?)?.toDouble() ?? 0,
        finishedAt: row['finishedAt'] as int?,
        lastIndex: row['lastIndex'] as int? ?? 0,
        activeAt: row['activeAt'] as int? ?? 0,
      );

  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'bankId': bankId,
        'mode': mode.key,
        'configJson': jsonEncode(config.toJson()),
        'status': status.key,
        'startedAt': startedAt,
        'elapsedMs': elapsedMs,
        'durationSec': durationSec,
        'scoreEnabled': scoreEnabled ? 1 : 0,
        'totalScore': totalScore,
        'maxScore': maxScore,
        'finishedAt': finishedAt,
        'lastIndex': lastIndex,
        'activeAt': lastActiveAt,
      };

  static Object? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
}

/// 会话中的一道题与作答。
class SessionQuestion {
  const SessionQuestion({
    required this.sessionId,
    required this.questionId,
    required this.orderNo,
    this.userAnswer = const <String>[],
    this.isCorrect,
    this.selfJudged = false,
    this.optionOrder = const <String>[],
    this.answeredAt,
  });

  final String sessionId;
  final String questionId;
  final int orderNo;

  /// 用户作答（选项 key 数组 / 填空文本 / 简答文本）。
  final List<String> userAnswer;

  /// null = 未答或未判分。
  final bool? isCorrect;

  /// 简答是否已自评。
  final bool selfJudged;
  final List<String> optionOrder;
  final int? answeredAt;

  bool get answered => userAnswer.isNotEmpty;

  SessionQuestion copyWith({
    List<String>? userAnswer,
    bool? isCorrect,
    bool? selfJudged,
    int? answeredAt,
  }) =>
      SessionQuestion(
        sessionId: sessionId,
        questionId: questionId,
        orderNo: orderNo,
        userAnswer: userAnswer ?? this.userAnswer,
        isCorrect: isCorrect,
        selfJudged: selfJudged ?? this.selfJudged,
        optionOrder: optionOrder,
        answeredAt: answeredAt ?? this.answeredAt,
      );

  static SessionQuestion fromRow(Map<String, Object?> row) => SessionQuestion(
        sessionId: row['sessionId'] as String,
        questionId: row['questionId'] as String,
        orderNo: row['orderNo'] as int? ?? 0,
        userAnswer: _strings(row['userAnswerJson'] as String?),
        isCorrect:
            row['isCorrect'] == null ? null : (row['isCorrect'] as int) == 1,
        selfJudged: (row['selfJudged'] as int? ?? 0) == 1,
        optionOrder: _strings(row['optionOrderJson'] as String?),
        answeredAt: row['answeredAt'] as int?,
      );

  Map<String, Object?> toRow() => <String, Object?>{
        'sessionId': sessionId,
        'questionId': questionId,
        'orderNo': orderNo,
        'userAnswerJson': jsonEncode(userAnswer),
        'isCorrect': isCorrect == null ? null : (isCorrect! ? 1 : 0),
        'selfJudged': selfJudged ? 1 : 0,
        'optionOrderJson': jsonEncode(optionOrder),
        'answeredAt': answeredAt,
      };

  static List<String> _strings(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    final list = jsonDecode(raw);
    if (list is! List) return const <String>[];
    return list.map((e) => e.toString()).toList(growable: false);
  }
}

/// 作答状态（用于答题卡与统计）。
enum AnswerState { unanswered, correct, wrong, pending }

/// 学习数据（统计页）。
class QuizStats {
  const QuizStats({
    this.bankCount = 0,
    this.questionCount = 0,
    this.wrongCount = 0,
    this.favoriteCount = 0,
    this.answeredCount = 0,
    this.correctCount = 0,
    this.sessionCount = 0,
    this.seenCount = 0,
  });

  final int bankCount;
  final int questionCount;
  final int wrongCount;
  final int favoriteCount;

  /// 历史作答次数（跨全部会话）。
  final int answeredCount;
  final int correctCount;
  final int sessionCount;

  /// 至少作答过一次的题目数（同一题刷多次只算一次）。
  final int seenCount;

  int get unseenCount =>
      questionCount > seenCount ? questionCount - seenCount : 0;

  double get seenPercent =>
      questionCount == 0 ? 0 : seenCount / questionCount * 100;

  double get accuracy =>
      answeredCount == 0 ? 0 : correctCount / answeredCount * 100;
}

/// 一条题库笔记：按题库隔离，内容由用户逐条记录。
class QuizNote {
  const QuizNote({
    required this.id,
    required this.bankId,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String bankId;
  final String content;
  final int createdAt;
  final int updatedAt;

  QuizNote copyWith({String? content, int? updatedAt}) => QuizNote(
        id: id,
        bankId: bankId,
        content: content ?? this.content,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'bankId': bankId,
        'content': content,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory QuizNote.fromRow(Map<String, Object?> row) => QuizNote(
        id: row['id'] as String? ?? '',
        bankId: row['bankId'] as String? ?? '',
        content: row['content'] as String? ?? '',
        createdAt: row['createdAt'] as int? ?? 0,
        updatedAt: row['updatedAt'] as int? ?? 0,
      );
}
