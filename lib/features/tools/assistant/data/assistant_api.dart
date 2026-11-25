import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../../../../core/settings/assistant_profile.dart';
import '../../../../core/settings/assistant_platforms.dart';
import 'robust_http.dart';

/// 单次回复的最大输出 token 数。
///
/// 不显式传 `max_tokens` 时，各平台默认值普遍只有 1-4K，题库 JSON 这类
/// 长输出会被截断在半路；8K 覆盖大多数兼容实现的上限，被拒时会自动降级。
const int kMaxOutputTokens = 8192;

/// 一条对话消息。
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.error = false,
    this.display,
  });

  ChatMessage.user(this.content, {this.display})
      : role = 'user',
        promptTokens = 0,
        completionTokens = 0,
        error = false;

  ChatMessage.assistant(this.content)
      : role = 'assistant',
        promptTokens = 0,
        completionTokens = 0,
        error = false,
        display = null;

  final String role;
  final String content;

  /// 用户消息的展示文本（带附件时与 content 不同；null 显示 content）。
  final String? display;

  /// 本条消息关联的 token 用量（接口 usage 汇总到 assistant 消息上）。
  final int promptTokens;
  final int completionTokens;

  /// 请求失败时展示为错误气泡。
  final bool error;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': role,
        'content': content,
        'display': display,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'error': error,
      };

  static ChatMessage fromJson(Map<String, dynamic> json) => ChatMessage(
        role: json['role'] as String? ?? 'user',
        content: json['content'] as String? ?? '',
        display: json['display'] as String?,
        promptTokens: json['promptTokens'] as int? ?? 0,
        completionTokens: json['completionTokens'] as int? ?? 0,
        error: json['error'] as bool? ?? false,
      );
}

/// 接口异常（message 尽量带服务端错误描述）。
class AssistantApiException implements Exception {
  const AssistantApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : '[$statusCode] $message';
}

/// token 用量。
class TokenUsage {
  const TokenUsage({required this.promptTokens, required this.completionTokens});

  final int promptTokens;
  final int completionTokens;
}

/// OpenAI 兼容 chat/completions 客户端（SSE 流式）。
class OpenAiCompatClient {
  OpenAiCompatClient({http.Client? client, this.timeout = defaultTimeout})
      : _client = client ?? createRobustHttpClient();

  static const Duration defaultTimeout = Duration(minutes: 5);

  final http.Client _client;
  final Duration timeout;

  Uri _uri(String baseUrl) {
    var url = baseUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    return Uri.parse('$url/chat/completions');
  }

  Map<String, String> _headers(String apiKey) => <String, String>{
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      };

  Map<String, dynamic> _body({
    required String model,
    required List<ChatMessage> messages,
    required bool stream,
    bool includeUsage = true,
    int? maxTokens,
  }) =>
      <String, dynamic>{
        'model': model,
        'messages': messages
            .map((m) => <String, String>{'role': m.role, 'content': m.content})
            .toList(),
        'stream': stream,
        if (maxTokens != null) 'max_tokens': maxTokens,
        if (stream && includeUsage) 'stream_options': <String, Object?>{
          'include_usage': true,
        },
      };

  /// 流式对话：逐段回调增量文本；结束时通过 [onUsage] 上报 token 用量。
  ///
  /// 默认会带上 `max_tokens`：不传时部分平台默认只有 1-4K，
  /// 题库 JSON 这类长输出会被直接截断。若服务端不接受该字段（400），
  /// 会去掉它并同时去掉 stream_options 再试一次。
  Stream<String> streamChat({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<ChatMessage> messages,
    void Function(TokenUsage usage)? onUsage,
  }) async* {
    http.StreamedResponse response;
    try {
      response = await _openStream(baseUrl, apiKey, model, messages,
          includeUsage: true, maxTokens: kMaxOutputTokens);
    } on AssistantApiException catch (e) {
      if (e.statusCode != 400) rethrow;
      response = await _openStream(baseUrl, apiKey, model, messages,
          includeUsage: false, maxTokens: null);
    }
    yield* _readSse(response, onUsage);
  }

  Future<http.StreamedResponse> _openStream(
    String baseUrl,
    String apiKey,
    String model,
    List<ChatMessage> messages, {
    required bool includeUsage,
    int? maxTokens,
  }) async {
    final request = http.Request('POST', _uri(baseUrl))
      ..headers.addAll(_headers(apiKey))
      ..body = jsonEncode(_body(
        model: _modelFor(baseUrl, model),
        messages: messages,
        stream: true,
        includeUsage: includeUsage,
        maxTokens: maxTokens,
      ));
    try {
      final response = await _client.send(request).timeout(timeout);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw AssistantApiException(
            _errorMessage(body, response.statusCode),
            statusCode: response.statusCode);
      }
      return response;
    } on TimeoutException {
      throw const AssistantApiException('请求超时，请检查网络或稍后再试');
    } on AssistantApiException {
      rethrow;
    } on SocketException catch (e) {
      throw AssistantApiException(_socketMessageOf(e));
    } catch (e) {
      throw AssistantApiException(describeNetworkError(e));
    }
  }

  Stream<String> _readSse(
    http.StreamedResponse response,
    void Function(TokenUsage usage)? onUsage,
  ) async* {
    // SSE 解析：data: {...} 行，[DONE] 结束。
    var buffer = '';
    await for (final chunk in response.stream) {
      buffer += utf8.decode(chunk, allowMalformed: true);
      while (true) {
        final idx = buffer.indexOf('\n');
        if (idx < 0) break;
        final line = buffer.substring(0, idx).trim();
        buffer = buffer.substring(idx + 1);
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty || payload == '[DONE]') continue;
        Object? decoded;
        try {
          decoded = jsonDecode(payload);
        } on FormatException {
          continue;
        }
        if (decoded is! Map) continue;
        final usage = decoded['usage'];
        if (usage is Map && onUsage != null) {
          onUsage(TokenUsage(
            promptTokens: _intOf(usage['prompt_tokens']),
            completionTokens: _intOf(usage['completion_tokens']),
          ));
        }
        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty) {
          final delta = choices.first;
          if (delta is Map) {
            final content = delta['delta'];
            final text =
                content is Map ? content['content'] : delta['content'];
            if (text is String && text.isNotEmpty) yield text;
          }
        }
      }
    }
  }

  /// 非流式对话（测试连接 / 简单调用）。
  /// 规范化模型名：为空时回退到平台默认模型，避免发出无效请求。
  String _modelFor(String baseUrl, String model) {
    final trimmed = model.trim();
    if (trimmed.isNotEmpty) return trimmed;
    return AssistantPlatform.match(baseUrl)?.models.first ??
        kDefaultAssistantModel;
  }

  /// 解码响应体：响应头没写 charset 时 package:http 的 `.body` 会按 latin1
  /// 解码，中文错误信息会变成乱码；这里强制按 UTF-8 解码。
  String _decodeBody(http.Response response) =>
      utf8.decode(response.bodyBytes, allowMalformed: true);

  Future<String> chat({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<ChatMessage> messages,
  }) async {
    http.Response response;
    try {
      response = await _client
          .post(_uri(baseUrl),
              headers: _headers(apiKey),
              body: jsonEncode(_body(
                  model: _modelFor(baseUrl, model),
                  messages: messages,
                  stream: false)))
          .timeout(timeout);
    } on AssistantApiException {
      rethrow;
    } catch (e) {
      throw AssistantApiException(describeNetworkError(e));
    }
    final body = _decodeBody(response);
    if (response.statusCode != 200) {
      throw AssistantApiException(_errorMessage(body, response.statusCode),
          statusCode: response.statusCode);
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const AssistantApiException('响应格式错误');
    }
    final choices = decoded['choices'];
    final content = choices is List && choices.isNotEmpty && choices.first is Map
        ? (choices.first as Map)['message']
        : null;
    final text = content is Map ? content['content'] : null;
    return text is String ? text : '';
  }

  /// 查询 API Key 的剩余额度；平台不支持时返回 null。
  Future<String?> queryBalance({
    required String baseUrl,
    required String apiKey,
  }) async {
    final platform = AssistantPlatform.match(baseUrl);
    final kind = platform?.balanceKind ?? BalanceKind.none;
    if (kind == BalanceKind.none) return null;

    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final Uri uri = switch (kind) {
      // DeepSeek 官方余额接口挂在根路径（不带 /v1）。
      BalanceKind.deepseek =>
        Uri.parse('${base.replaceAll(RegExp(r'/v1$'), '')}/user/balance'),
      BalanceKind.moonshot => Uri.parse('$base/users/me/balance'),
      BalanceKind.siliconflow => Uri.parse('$base/user/info'),
      BalanceKind.none => throw StateError('unreachable'),
    };

    final response = await _client.get(uri, headers: _headers(apiKey)).timeout(timeout);
    final body = _decodeBody(response);
    if (response.statusCode != 200) {
      throw AssistantApiException(_errorMessage(body, response.statusCode),
          statusCode: response.statusCode);
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;

    return switch (kind) {
      BalanceKind.deepseek => _deepseekBalance(decoded),
      BalanceKind.moonshot => _moonshotBalance(decoded),
      BalanceKind.siliconflow => _siliconflowBalance(decoded),
      BalanceKind.none => null,
    };
  }

  static String? _deepseekBalance(Map data) {
    final infos = data['balance_infos'];
    if (infos is List && infos.isNotEmpty && infos.first is Map) {
      final info = infos.first as Map;
      final amount = info['total_balance'];
      final currency = info['currency'] ?? '';
      if (amount != null) return '$amount ${currency is String ? currency : ''}'.trim();
    }
    return null;
  }

  static String? _moonshotBalance(Map data) {
    final d = data['data'];
    if (d is! Map) return null;
    final available = d['available_balance'];
    if (available != null) return '$available CNY';
    return null;
  }

  static String? _siliconflowBalance(Map data) {
    final d = data['data'];
    if (d is! Map) return null;
    final total = d['totalBalance'];
    if (total != null) return '$total CNY';
    final balance = d['balance'];
    if (balance != null) return '$balance CNY';
    return null;
  }

  /// 从错误响应里尽量提取可读信息。
  static String _errorMessage(String body, int statusCode) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        final message = error is Map ? error['message'] : decoded['message'];
        if (message is String && message.isNotEmpty) {
          // 带上服务端错误码（如 GLM 1211=模型不存在），便于定位。
          final code = error is Map ? error['code'] : decoded['code'];
          final codePart = code == null || '$code'.isEmpty ? '' : '（code $code）';
          final text = '$message$codePart';
          return text.length > 300 ? '${text.substring(0, 300)}…' : text;
        }
      }
    } on FormatException {
      // fallthrough
    }
    final text = body.trim();
    if (text.isEmpty) return '请求失败（HTTP $statusCode）';
    return text.length > 300 ? 'HTTP $statusCode：${text.substring(0, 300)}…' : 'HTTP $statusCode：$text';
  }

  static int _intOf(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }
}

/// 把网络层异常翻译成用户能看懂的提示（对话页与分段转换共用）。
String describeNetworkError(Object error) {
  if (error is AssistantApiException) return error.message;
  if (error is TimeoutException) return '请求超时，请检查网络或稍后再试';
  if (error is SocketException) return _socketMessageOf(error);
  final text = error.toString();
  final lower = text.toLowerCase();
  // ClientException 只是包装，真正原因在这段文本里。
  if (lower.contains('software caused connection abort') ||
      lower.contains('connection reset') ||
      lower.contains('connection closed') ||
      lower.contains('broken pipe')) {
    return '连接被中断（网络切换或服务端主动断开），请检查网络后重试';
  }
  if (lower.contains('failed host lookup') ||
      lower.contains('nodename nor servname') ||
      lower.contains('no address associated')) {
    return '无法解析服务器域名（已尝试备用 DNS 解析），请到「AI 配置 → 网络诊断」查看细节';
  }
  if (lower.contains('connection refused')) {
    return '服务器拒绝连接，请检查接口地址与端口';
  }
  if (lower.contains('network is unreachable')) {
    return '网络不可用，请检查手机网络连接';
  }
  if (lower.contains('timeout')) return '请求超时，请检查网络或稍后再试';
  return '网络错误：$text';
}

String _socketMessageOf(SocketException e) {
  final msg = e.message.toLowerCase();
  final code = e.osError?.errorCode;
  if (msg.contains('failed host lookup') ||
      msg.contains('no address associated') ||
      code == 7) {
    return '无法解析服务器域名（已尝试备用 DNS 解析），请到「AI 配置 → 网络诊断」查看细节';
  }
  if (msg.contains('connection refused')) {
    return '服务器拒绝连接，请检查接口地址与端口';
  }
  if (msg.contains('network is unreachable') || msg.contains('timed out')) {
    return '网络不可用，请检查手机网络连接';
  }
  return '网络错误：${e.message}';
}
