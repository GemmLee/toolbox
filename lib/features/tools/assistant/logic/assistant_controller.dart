import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/settings/settings_controller.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/storage/local_store.dart';
import '../data/assistant_api.dart';
import '../data/skills.dart';
import 'assistant_chunking.dart';
import 'assistant_session.dart';
import 'quiz_result.dart';

/// 一条待发送的附件（已提取为文本）。
class AssistantAttachment {
  const AssistantAttachment({required this.name, required this.text});

  final String name;
  final String text;
}

/// 智能助手会话状态：多会话持久化、流式输出、技能与附件。
///
/// 控制器是全局长生命周期的 [instance]：离开对话页不会中断正在生成的请求，
/// 再进入时直接接着看结果。
class AssistantController extends ChangeNotifier {
  AssistantController({OpenAiCompatClient? client, SettingsController? settings})
      : _client = client ?? OpenAiCompatClient(),
        settings = settings ?? SettingsController.instance {
    // 设置（配置列表 / 激活配置 / API Key）变化时刷新对话界面，
    // 避免在「AI 配置」里改完配置回到对话页后仍显示旧的未配置状态。
    this.settings.addListener(_onSettingsChanged);
  }

  /// 全局单例：页面销毁不影响生成中的请求。
  static final AssistantController instance = AssistantController();

  static const String _sessionsKey = 'assistant_sessions';

  /// 旧版单会话历史，首次加载时迁移成一个对话。
  static const String _legacyHistoryKey = 'assistant_chat';

  static const int _maxHistoryMessages = 200;
  static const int _maxContextMessages = 30;

  /// 超过该长度的题目文档自动分段转换：单次请求不可能稳定输出无限长的 JSON。
  static const int chunkThreshold = kChunkThreshold;

  /// 每段的最大字符数（按行切分，尽量不切断题目）。
  static const int chunkSize = kChunkSize;

  final OpenAiCompatClient _client;
  final SettingsController settings;

  /// 全部对话（左侧栏内容），最近活跃的排前面。
  List<AssistantSession> sessions = <AssistantSession>[];
  String activeSessionId = '';

  bool streaming = false;
  String partial = '';
  String? lastError;

  AssistantSkill? activeSkill;
  List<AssistantSkill> skills = const <AssistantSkill>[];
  List<AssistantAttachment> attachments = const <AssistantAttachment>[];

  StreamSubscription<String>? _sub;

  /// 生成过程中定期把已收到的内容落盘，进程被杀也能留下半成品。
  Timer? _draftTimer;

  /// 正在生成的那段对话；切换会话后结果仍然写回它。
  String? _streamingSessionId;
  String? get streamingSessionId => _streamingSessionId;

  bool _loaded = false;

  bool get configured => settings.assistantConfigured;

  AssistantSession? get activeSession {
    for (final s in sessions) {
      if (s.id == activeSessionId) return s;
    }
    return sessions.isEmpty ? null : sessions.first;
  }

  /// 当前对话的消息（切会话即切换这一份）。
  List<ChatMessage> get messages => activeSession?.messages ?? const <ChatMessage>[];

  /// 某段对话是否正在生成中（左侧栏用来显示小圆点）。
  bool isGenerating(String sessionId) =>
      streaming && _streamingSessionId == sessionId;

  void _onSettingsChanged() {
    notifyListeners();
  }

  /// 初始化：读取对话列表与技能列表。
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) {
      skills = await SkillStore.all();
      _syncSkillFromSession();
      notifyListeners();
      return;
    }
    final map = await LocalStore.readMap(_sessionsKey);
    final raw = map?['sessions'];
    if (raw is List) {
      sessions = raw
          .whereType<Map>()
          .map((e) => AssistantSession.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      activeSessionId = map?['activeId'] as String? ?? '';
    }

    if (sessions.isEmpty) {
      // 旧版只有一段对话：迁移成一个名为「历史对话」的会话。
      final legacy = await LocalStore.readMap(_legacyHistoryKey);
      final legacyRaw = legacy?['messages'];
      final migrated = <ChatMessage>[];
      if (legacyRaw is List) {
        migrated.addAll(legacyRaw
            .whereType<Map>()
            .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e))));
      }
      final session = AssistantSession(
        id: AssistantSession.newId(),
        title: tr('新对话'),
      )..messages.addAll(migrated);
      if (migrated.isNotEmpty) {
        session.title = AssistantSession.titleFrom(_firstUserText(migrated));
      }
      sessions = <AssistantSession>[session];
      activeSessionId = session.id;
      if (migrated.isNotEmpty) await LocalStore.remove(_legacyHistoryKey);
    }

    if (!sessions.any((s) => s.id == activeSessionId)) {
      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      activeSessionId = sessions.first.id;
    }

    // 上次生成被中断（进程被杀）：已收到的内容转成一条消息，不白跑。
    var restored = false;
    for (final session in sessions) {
      if (session.draft.trim().isEmpty) continue;
      session.messages.add(ChatMessage(
        role: 'assistant',
        content: session.draft,
      ));
      session.draft = '';
      restored = true;
    }
    if (restored) await _persist();

    skills = await SkillStore.all();
    _syncSkillFromSession();
    _loaded = true;
    notifyListeners();
  }

  /// 测试专用：清空内存状态，使下一次 load() 重新读盘。
  @visibleForTesting
  void resetForTest() {
    sessions = <AssistantSession>[];
    activeSessionId = '';
    streaming = false;
    partial = '';
    lastError = null;
    activeSkill = null;
    attachments = const <AssistantAttachment>[];
    _streamingSessionId = null;
    _loaded = false;
  }

  Future<void> refreshSkills() async {
    skills = await SkillStore.all();
    _syncSkillFromSession();
    notifyListeners();
  }

  /// 选择技能：技能属于某一段对话，选择结果写进该会话并落盘，
  /// 重新进入 / 切换回来时自动恢复，不会被重置成「自由对话」。
  Future<void> selectSkill(AssistantSkill? skill) async {
    activeSkill = skill;
    final session = activeSession;
    if (session != null) {
      session.skillId = skill?.id ?? '';
      await _persist();
    }
    notifyListeners();
  }

  /// 从当前会话恢复技能选择（加载 / 切换 / 删除对话后调用）。
  void _syncSkillFromSession() {
    final id = activeSession?.skillId ?? '';
    if (id.isEmpty) {
      activeSkill = null;
      return;
    }
    for (final skill in skills) {
      if (skill.id == id) {
        activeSkill = skill;
        return;
      }
    }
    // 技能文件已被删除：清掉会话里的失效引用，回到自由对话。
    activeSkill = null;
    activeSession?.skillId = '';
  }

  // —— 会话管理 ——

  /// 新建对话并切换过去（空的默认对话会复用，避免点一次多一条）。
  Future<AssistantSession> newSession() async {
    final current = activeSession;
    final untouched = current != null &&
        current.messages.isEmpty &&
        (current.title.isEmpty || current.title == tr('新对话'));
    if (untouched) {
      attachments = const <AssistantAttachment>[];
      lastError = null;
      notifyListeners();
      return current;
    }
    final session = AssistantSession(
      id: AssistantSession.newId(),
      title: tr('新对话'),
    );
    // 新对话沿用当前技能，避免每开一段都要重新选一次。
    session.skillId = activeSkill?.id ?? '';
    sessions.insert(0, session);
    activeSessionId = session.id;
    attachments = const <AssistantAttachment>[];
    lastError = null;
    await _persist();
    notifyListeners();
    return session;
  }

  Future<void> selectSession(String id) async {
    if (activeSessionId == id) return;
    if (!sessions.any((s) => s.id == id)) return;
    activeSessionId = id;
    activeSkill = null;
    _syncSkillFromSession();
    attachments = const <AssistantAttachment>[];
    lastError = null;
    await _persist();
    notifyListeners();
  }

  Future<void> renameSession(String id, String title) async {
    final index = sessions.indexWhere((s) => s.id == id);
    if (index < 0) return;
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    sessions[index].title = trimmed;
    await _persist();
    notifyListeners();
  }

  Future<void> deleteSession(String id) async {
    sessions.removeWhere((s) => s.id == id);
    if (sessions.isEmpty) {
      await newSession();
      return;
    }
    if (activeSessionId == id) {
      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      activeSessionId = sessions.first.id;
      _syncSkillFromSession();
    }
    await _persist();
    notifyListeners();
  }

  // —— 消息 ——

  void addAttachment(AssistantAttachment attachment) {
    attachments = [...attachments, attachment];
    notifyListeners();
  }

  void removeAttachment(AssistantAttachment attachment) {
    attachments = attachments.where((a) => a != attachment).toList();
    notifyListeners();
  }

  Future<void> send(String text) async {
    final content = text.trim();
    if (content.isEmpty && attachments.isEmpty) return;
    if (streaming) return;
    if (!configured) {
      final p = settings.activeAssistantProfile;
      lastError = p == null || p.apiKey.isEmpty
          ? '请先在「用户 → AI 配置」里为当前使用的配置填写 API Key'
          : '请先在「用户 → AI 配置」里补全当前配置的模型或接口地址';
      notifyListeners();
      return;
    }
    lastError = null;

    final session = activeSession ?? await newSession();
    // 本次请求的结果固定写回这一段对话，切走也不会串到别的会话。
    _streamingSessionId = session.id;

    // 组装消息：正文 + 附件内容。
    final buffer = StringBuffer();
    if (content.isNotEmpty) buffer.write(content);
    for (final a in attachments) {
      buffer
        ..writeln()
        ..writeln()
        ..writeln('【附件：${a.name}】')
        ..writeln(a.text);
    }
    final composed = buffer.toString().trim();
    final display = attachments.isEmpty
        ? null
        : content.isEmpty
            ? attachments.map((a) => '📎 ${a.name}').join('、')
            : '$content\n${attachments.map((a) => '📎 ${a.name}').join('、')}';

    attachments = const <AssistantAttachment>[];
    _append(ChatMessage.user(composed, display: display));
    await _persist();
    notifyListeners();

    // 题库转换遇到长文档：自动分段多次请求，再把结果合并成一个题库，
    // 避免单次输出超过模型长度上限被截断。
    if (_isQuizSkill && composed.length > chunkThreshold) {
      // 技能快照：转换途中切到别的对话，也不会把系统提示换掉。
      await _convertInChunks(composed, activeSkill);
      return;
    }

    await _request();
  }

  bool get _isQuizSkill => activeSkill?.id == SkillStore.quizSkillId;

  Future<void> _request() async {
    final system = activeSkill?.prompt ?? kDefaultSystemPrompt;
    final session = _targetSession;
    final context = <ChatMessage>[
      ChatMessage(role: 'system', content: system),
      ...(session?.messages ?? const <ChatMessage>[])
          .where((m) => !m.error)
          .toList()
          .reversed
          .take(_maxContextMessages)
          .toList()
          .reversed,
    ];

    streaming = true;
    partial = '';
    _startDraftTimer();
    notifyListeners();

    var usageIn = 0;
    var usageOut = 0;
    final completer = Completer<void>();
    _sub = _client
        .streamChat(
      baseUrl: settings.assistantBaseUrl,
      apiKey: settings.assistantApiKey,
      model: settings.assistantModel,
      messages: context,
      onUsage: (usage) {
        usageIn += usage.promptTokens;
        usageOut += usage.completionTokens;
      },
    )
        .listen(
      (delta) {
        partial += delta;
        notifyListeners();
      },
      onError: (Object e) {
        streaming = false;
        _append(ChatMessage(
          role: 'assistant',
          content: e is AssistantApiException ? e.message : '请求失败：$e',
          error: true,
        ));
        _finishStream(usageIn, usageOut);
        completer.complete();
      },
      onDone: () async {
        streaming = false;
        if (partial.isNotEmpty) {
          _append(ChatMessage(
            role: 'assistant',
            content: partial,
            promptTokens: usageIn,
            completionTokens: usageOut,
          ));
        } else if (usageIn == 0 && usageOut == 0) {
          _append(const ChatMessage(
            role: 'assistant',
            content: '（模型没有返回内容）',
            error: true,
          ));
        }
        partial = '';
        await _finishStream(usageIn, usageOut);
        completer.complete();
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  /// 分段转换长文档：逐段请求 → 合并题目 → 输出单个题库 JSON 消息。
  ///
  /// 每段都用**流式**请求：非流式的长请求在服务端或运营商链路上很容易被
  /// 判成空闲连接而中断（`Software caused connection abort`），流式会持续
  /// 有字节下行，还能显示「已接收 N 字符」。失败按退避重试；仍失败就把该段
  /// 对半拆开再转，避免整段内容白丢。
  Future<void> _convertInChunks(String source, AssistantSkill? skill) async {
    final chunks = splitForConversion(source);
    final questions = <Map<String, dynamic>>[];
    final seen = <String>{};
    String? bankName;
    var failed = 0;
    String? firstError;

    streaming = true;
    partial = '';
    _startDraftTimer();
    notifyListeners();

    for (var i = 0; i < chunks.length; i++) {
      final label = trf('正在转换第 {i}/{n} 段（本段 {len} 字符）',
          {'i': i + 1, 'n': chunks.length, 'len': chunks[i].length});
      partial = label;
      notifyListeners();

      final result = await _convertChunk(chunks[i],
          label: label, systemPrompt: _chunkSystemPrompt(skill));
      final parsed = result.questions;
      if (parsed == null) {
        failed++;
        firstError ??= result.error ?? tr('该段没有解析出题库 JSON');
        continue;
      }
      if (bankName == null &&
          result.bankName != null &&
          result.bankName != tr('未命名题库')) {
        bankName = result.bankName;
      }
      for (final question in parsed) {
        if (!seen.add(questionKey(question))) continue;
        questions.add(question);
      }
    }

    streaming = false;
    partial = '';
    _stopDraftTimer();
    if (questions.isEmpty) {
      _append(ChatMessage(
        role: 'assistant',
        content: trf('分段转换失败：{msg}', {'msg': firstError ?? tr('未获得结果')}),
        error: true,
      ));
    } else {
      final merged = <String, dynamic>{
        'version': 1,
        'bankName': bankName ?? tr('未命名题库'),
        'questions': <Map<String, dynamic>>[
          for (var i = 0; i < questions.length; i++)
            <String, dynamic>{
              ...questions[i],
              'id': 'q-${(i + 1).toString().padLeft(3, '0')}',
            },
        ],
      };
      _append(ChatMessage.assistant(jsonEncode(merged)));
      if (failed > 0) {
        _append(ChatMessage(
          role: 'assistant',
          content: trf('有 {n} 段未能转换（{msg}），已保留其余 {k} 题',
              {'n': failed, 'msg': firstError ?? '-', 'k': questions.length}),
        ));
      }
    }
    _streamingSessionId = null;
    await _persist();
    notifyListeners();
  }

  static const int _chunkAttempts = 3;

  /// 分段的系统提示：只转换当前这一段。
  String _chunkSystemPrompt(AssistantSkill? skill) =>
      '${skill?.prompt ?? kDefaultSystemPrompt}\n'
      '用户会把同一份题目文档分成几次发给你，每次只包含其中一段。'
      '只转换本次给出的这一段，仍然只输出一个 JSON 对象。';

  /// 转换一段；失败自动重试，重试后仍失败则对半拆开再转。
  Future<_ChunkResult> _convertChunk(
    String text, {
    required String label,
    required String systemPrompt,
    int depth = 0,
  }) async {
    String? error;
    for (var attempt = 1; attempt <= _chunkAttempts; attempt++) {
      final buffer = StringBuffer();
      var notified = 0;
      try {
        await for (final delta in _client.streamChat(
          baseUrl: settings.assistantBaseUrl,
          apiKey: settings.assistantApiKey,
          model: settings.assistantModel,
          messages: <ChatMessage>[
            ChatMessage(role: 'system', content: systemPrompt),
            ChatMessage.user('$label\n$text'),
          ],
        )) {
          buffer.write(delta);
          if (buffer.length - notified >= 200) {
            notified = buffer.length;
            partial = trf('{label} · 已接收 {n} 字符',
                {'label': label, 'n': buffer.length});
            notifyListeners();
          }
        }
        final extract = extractQuizBankJson(buffer.toString());
        final parsed = extract == null ? null : _questionsOf(extract.raw);
        if (parsed != null) {
          return _ChunkResult(questions: parsed, bankName: extract!.bankName);
        }
        error ??= tr('该段没有解析出题库 JSON');
      } catch (e) {
        error = describeNetworkError(e);
      }
      if (attempt < _chunkAttempts) {
        partial = trf('{label} · 连接中断，正在重试（{i}/{n}）',
            {'label': label, 'i': attempt, 'n': _chunkAttempts - 1});
        notifyListeners();
        await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
      }
    }
    // 整段重试仍失败：对半拆开，每半走一次正常流程（深度只放一层）。
    if (depth == 0 && text.length > 1200) {
      final halves = _splitHalf(text);
      final merged = <Map<String, dynamic>>[];
      String? name;
      for (final half in halves) {
        final part = await _convertChunk(half,
            label: label, systemPrompt: systemPrompt, depth: 1);
        final questions = part.questions;
        if (questions == null) {
          return _ChunkResult(error: part.error ?? error);
        }
        name ??= part.bankName;
        merged.addAll(questions);
      }
      return _ChunkResult(questions: merged, bankName: name);
    }
    return _ChunkResult(error: error);
  }

  /// 在中间位置就近的换行处切成两半，避免把一道题切成两截。
  List<String> _splitHalf(String text) {
    final mid = text.length ~/ 2;
    var cut = text.lastIndexOf('\n', mid);
    if (cut < mid ~/ 2) cut = mid;
    return <String>[text.substring(0, cut), text.substring(cut)];
  }

  /// 从题库 JSON 里取出题目列表（解析失败返回 null）。
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

  Future<void> _finishStream(int usageIn, int usageOut) async {
    _stopDraftTimer();
    partial = '';
    _streamingSessionId = null;
    await _persist();
    if (usageIn > 0 || usageOut > 0) {
      await settings.addAssistantUsage(usageIn, usageOut);
    }
    notifyListeners();
  }

  void _startDraftTimer() {
    _draftTimer?.cancel();
    _draftTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      final session = _targetSession;
      if (session == null || partial.isEmpty) return;
      session.draft = partial;
      _persist();
    });
  }

  /// 结束时清掉草稿：内容已经落成正式消息，避免下次误当成中断残留。
  void _stopDraftTimer() {
    _draftTimer?.cancel();
    _draftTimer = null;
    _targetSession?.draft = '';
  }

  /// 停止本次生成：已收到的内容保留为助手消息。
  Future<void> stop() async {
    if (!streaming) return;
    await _sub?.cancel();
    _sub = null;
    streaming = false;
    if (partial.isNotEmpty) {
      _append(ChatMessage(role: 'assistant', content: partial));
    }
    _stopDraftTimer();
    partial = '';
    _streamingSessionId = null;
    await _persist();
    notifyListeners();
  }

  /// 清空当前对话的消息（保留这个对话本身）。
  Future<void> clearHistory() async {
    final session = activeSession;
    if (session == null) return;
    session.messages.clear();
    session.updatedAt = DateTime.now();
    lastError = null;
    await _persist();
    notifyListeners();
  }

  /// 清空指定对话的消息（左侧列表菜单用，不必先切换过去）。
  Future<void> clearSession(String id) async {
    final index = sessions.indexWhere((s) => s.id == id);
    if (index < 0) return;
    final session = sessions[index];
    session.messages.clear();
    session.updatedAt = DateTime.now();
    if (activeSessionId == id) lastError = null;
    await _persist();
    notifyListeners();
  }

  // —— 内部 ——

  /// 消息归属的对话：优先正在生成的那段，否则当前选中的对话。
  AssistantSession? get _targetSession {
    final id = _streamingSessionId ?? activeSessionId;
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return activeSession;
  }

  void _append(ChatMessage message) {
    final session = _targetSession;
    if (session == null) return;
    session.messages.add(message);
    if (session.messages.length > _maxHistoryMessages) {
      session.messages
          .removeRange(0, session.messages.length - _maxHistoryMessages);
    }
    session.updatedAt = DateTime.now();
    if (message.role == 'user' &&
        (session.title.isEmpty || session.title == tr('新对话'))) {
      final title =
          AssistantSession.titleFrom(message.display ?? message.content);
      if (title.isNotEmpty) session.title = title;
    }
  }

  String _firstUserText(List<ChatMessage> list) {
    for (final m in list) {
      if (m.role == 'user') return m.display ?? m.content;
    }
    return '';
  }

  Future<void> _persist() async {
    await LocalStore.writeMap(_sessionsKey, <String, dynamic>{
      'activeId': activeSessionId,
      'sessions': <Map<String, dynamic>>[
        for (final s in sessions) s.toJson(),
      ],
    });
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    settings.removeListener(_onSettingsChanged);
    _sub?.cancel();
    super.dispose();
  }
}

/// 单段转换结果：题目列表 + 题库名 + 失败原因（互斥）。
class _ChunkResult {
  const _ChunkResult({this.questions, this.bankName, this.error});

  final List<Map<String, dynamic>>? questions;
  final String? bankName;
  final String? error;
}
