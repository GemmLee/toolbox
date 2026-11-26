import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../core/storage/local_store.dart';

/// 一条可下载文件（与 quiz-bank/index.json 的 files[] 对应）。
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

  /// 题数与各题型数量。
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

  /// 完整下载地址，中文文件名做百分号编码。
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

/// 题库索引服务：拉取并解析 index.json。
class QuizIndexService {
  QuizIndexService({
    http.Client? client,
    this.baseUrl = kDefaultQuizResourceBaseUrl,
    this.fallbackBaseUrl = '',
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  static const String kDefaultQuizResourceBaseUrl =
      'https://xmonline-sgcc.r2.dev';
  static const String kPagesResourceBaseUrl = 'https://xmhome.ljm123aaa.workers.dev/';
  static const String indexDir = 'quiz-bank';
  static const String indexFile = 'index.json';

  final http.Client _client;
  final String baseUrl;
  final String fallbackBaseUrl;
  final Duration timeout;

  String _usedBaseUrl = '';

  /// 实际拉取成功的域名，用于拼接同站点下载直链。
  String get usedBaseUrl => _usedBaseUrl.isEmpty ? baseUrl : _usedBaseUrl;

  String _indexUrlFor(String base) {
    final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$root/$indexDir/$indexFile';
  }

  String get indexUrl => _indexUrlFor(baseUrl);

  Future<List<QuizRemoteFile>> fetch() async {
    try {
      final files = await _fetchFrom(baseUrl);
      _usedBaseUrl = baseUrl;
      return files;
    } catch (_) {
      if (fallbackBaseUrl.isEmpty || fallbackBaseUrl == baseUrl) rethrow;
      final files = await _fetchFrom(fallbackBaseUrl);
      _usedBaseUrl = fallbackBaseUrl;
      return files;
    }
  }

  Future<List<QuizRemoteFile>> _fetchFrom(String base) async {
    final http.Response resp;
    try {
      resp = await _client
          .get(Uri.parse(_indexUrlFor(base)), headers: const <String, String>{
        'Accept': 'application/json',
      }).timeout(timeout);
    } on TimeoutException {
      throw const QuizIndexException('请求超时，请稍后重试');
    } catch (_) {
      throw const QuizIndexException('网络请求失败，请稍后重试');
    }
    if (resp.statusCode != 200) {
      throw const QuizIndexException('资源加载失败，请稍后重试');
    }
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const QuizIndexException('资源格式异常');
    }
    if (decoded is! Map) throw const QuizIndexException('资源格式异常');
    final files = decoded['files'];
    if (files is! List) throw const QuizIndexException('暂无可下载资源');
    final result = files
        .whereType<Map>()
        .map((e) => QuizRemoteFile.fromJson(Map<String, dynamic>.from(e)))
        .where((f) => f.file.isNotEmpty && f.title.isNotEmpty)
        .toList(growable: false);
    if (result.isEmpty) throw const QuizIndexException('暂无可下载资源');
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
