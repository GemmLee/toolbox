import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../core/storage/local_store.dart';

/// 一条可下载文件内容（与 R2 的 quiz-bank/index.json 中 files[] 对应）。
///
/// 网页与 APP 共用这份索引：新增题库只改 R2 上的 index.json，两端同时生效。
class QuizRemoteFile {
  const QuizRemoteFile({
    required this.id,
    required this.title,
    required this.file,
    this.dir = 'quiz-bank',
    this.category = '题库',
    this.size = 0,
    this.questions = 0,
    this.types = const <String, int>{},
  });

  final String id;
  final String title;

  /// R2 对象名（相对 [dir]）。
  final String file;

  /// bucket 下的目录，缺省 quiz-bank。
  final String dir;
  final String category;
  final int size;
  final int questions;
  final Map<String, int> types;

  factory QuizRemoteFile.fromJson(Map<String, dynamic> json) {
    final rawTypes = json['types'];
    final types = <String, int>{};
    if (rawTypes is Map) {
      rawTypes.forEach((key, value) {
        final n = value is num ? value.toInt() : int.tryParse('$value');
        if (n != null && n > 0) types['$key'] = n;
      });
    }
    return QuizRemoteFile(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? json['file'] ?? '').toString(),
      file: (json['file'] ?? '').toString(),
      dir: (json['dir'] ?? 'quiz-bank').toString(),
      category: (json['category'] ?? '题库').toString(),
      size: json['size'] is num ? (json['size'] as num).toInt() : 0,
      questions:
          json['questions'] is num ? (json['questions'] as num).toInt() : 0,
      types: types,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'file': file,
        'dir': dir,
        'category': category,
        'size': size,
        'questions': questions,
        'types': types,
      };

  /// 题数 + 各题型数量，形如 `725 题 · 单选 477 · 多选 98 · 判断 150`。
  String get metaLabel {
    const labels = <String, String>{
      'single': '单选',
      'multiple': '多选',
      'true_false': '判断',
      'fill': '填空',
      'short': '简答',
    };
    final parts = <String>[];
    if (questions > 0) parts.add('$questions 题');
    types.forEach((key, value) {
      parts.add('${labels[key] ?? key} $value');
    });
    return parts.join(' · ');
  }

  String get sizeLabel {
    if (size <= 0) return '';
    if (size >= 1048576) return '${(size / 1048576).toStringAsFixed(1)} MB';
    return '${(size / 1024).round()} KB';
  }

  /// 完整下载地址：baseUrl / dir / file（中文文件名做百分号编码）。
  String downloadUrl(String baseUrl) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$base/${Uri.encodeComponent(dir)}/${Uri.encodeComponent(file)}';
  }
}

/// 索引拉取异常（消息可直接展示）。
class QuizIndexException implements Exception {
  const QuizIndexException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// R2 内容索引服务：拉取并解析 quiz-bank/index.json。
///
/// 默认地址指向公开的 R2 bucket 域名；baseUrl 可通过设置页覆盖（企业自建域）。
/// [client] 可注入以便测试与 DNS 兜底，超时统一为 [timeout]。
class QuizIndexService {
  QuizIndexService({
    http.Client? client,
    this.baseUrl = kDefaultQuizResourceBaseUrl,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  /// 默认资源域名：与网页 xmhome.html 的 R2_BASE 保持一致。
  static const String kDefaultQuizResourceBaseUrl =
      'https://xmonline-sgcc.r2.dev';
  static const String indexDir = 'quiz-bank';
  static const String indexFile = 'index.json';

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  String get indexUrl {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$base/$indexDir/$indexFile';
  }

  Future<List<QuizRemoteFile>> fetch() async {
    final http.Response resp;
    try {
      resp = await _client
          .get(Uri.parse(indexUrl), headers: const <String, String>{
        'Accept': 'application/json',
      }).timeout(timeout);
    } on TimeoutException {
      throw const QuizIndexException('请求超时，请检查网络后重试');
    } catch (e) {
      throw QuizIndexException('网络请求失败：$e');
    }
    if (resp.statusCode != 200) {
      throw QuizIndexException('索引服务返回 HTTP ${resp.statusCode}');
    }
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const QuizIndexException('索引不是有效的 JSON');
    }
    if (decoded is! Map) throw const QuizIndexException('索引格式异常');
    final files = decoded['files'];
    if (files is! List) throw const QuizIndexException('索引缺少 files 字段');
    final result = files
        .whereType<Map>()
        .map((e) => QuizRemoteFile.fromJson(Map<String, dynamic>.from(e)))
        .where((f) => f.file.isNotEmpty && f.title.isNotEmpty)
        .toList(growable: false);
    if (result.isEmpty) throw const QuizIndexException('索引中没有可下载文件');
    return result;
  }

  void dispose() => _client.close();
}

/// 索引离线缓存：失败时仍可展示上次拉取的列表。
class QuizIndexCache {
  QuizIndexCache({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const String storageKey = 'quiz_remote_index_cache';
  static const Duration maxAge = Duration(hours: 24);

  final DateTime Function() _now;

  Future<List<QuizRemoteFile>?> read() async {
    final map = await LocalStore.readMap(storageKey);
    if (map == null) return null;
    final ts = (map['at'] as num?)?.toInt();
    if (ts == null) return null;
    final age = _now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
    if (age < Duration.zero || age > maxAge) return null;
    final raw = map['files'];
    if (raw is! List) return null;
    return raw
        .whereType<Map>()
        .map((e) => QuizRemoteFile.fromJson(Map<String, dynamic>.from(e)))
        .where((f) => f.file.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> save(List<QuizRemoteFile> files) => LocalStore.writeMap(
        storageKey,
        <String, dynamic>{
          'at': _now().millisecondsSinceEpoch,
          'files': files.map((f) => f.toJson()).toList(),
        },
      );
}
