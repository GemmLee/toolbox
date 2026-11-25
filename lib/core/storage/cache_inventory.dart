import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/tool_texts.dart';
import '../../features/tools/quiz/data/quiz_repository.dart';
import '../../features/tools/quiz/logic/quiz_ai_explainer.dart';
import 'storage_maintenance.dart';

/// 一条可单独清理的缓存。
///
/// [tool] 是可翻译的工具名 key；[name] 与 [detail] 是具体缓存项说明。
enum CacheKind { runtime, imports, temp, quizRecords, quizAi }

class CacheEntry {
  const CacheEntry({
    required this.id,
    required this.tool,
    required this.name,
    required this.detail,
    required this.bytes,
    required this.kind,
    this.key = '',
  });

  final String id;
  final String tool;
  final String name;
  final String detail;
  final int bytes;
  final CacheKind kind;
  final String key;
}

/// 缓存明细：按工具/来源列出可以安全清理的数据，从大到小排序。
///
/// 原生缓存目录只展开一层，附带扩展名统计，让用户大致看出缓存的是什么；
/// Dart 侧再补上导入临时副本、旧刷题记录与 AI 解析缓存。
class CacheInventory {
  CacheInventory._();

  static const MethodChannel _channel = MethodChannel('toolbox/device_status');

  static Future<List<CacheEntry>> load({
    Future<List<Map<String, Object?>>> Function()? nativeLoader,
    Future<Directory> Function()? tempDirLoader,
    Future<SharedPreferences> Function()? prefsLoader,
    Future<int> Function()? sessionCountLoader,
  }) async {
    final out = <CacheEntry>[];

    // 1. 原生：应用缓存目录 / 外部缓存目录 / 导入临时目录。
    for (final row in await _nativeRows(nativeLoader)) {
      final key = row['key']?.toString() ?? '';
      final name = row['name']?.toString() ?? '';
      final size = (row['size'] as num?)?.toInt() ?? 0;
      if (key.isEmpty || size <= 0) continue;
      final imports = row['tag']?.toString() == 'imports';
      final count = (row['count'] as num?)?.toInt() ?? 0;
      final types = row['types']?.toString() ?? '';
      out.add(CacheEntry(
        id: key,
        key: key,
        tool: imports ? '文字阅读器' : '系统',
        name: imports ? '导入临时副本' : '运行时缓存',
        detail: <String>[
          name,
          trf('{n} 个文件', {'n': '$count'}),
          if (types.isNotEmpty) trf('多为 {v}', {'v': types}),
        ].join(' · '),
        bytes: size,
        kind: imports ? CacheKind.imports : CacheKind.runtime,
      ));
    }

    // 2. 系统临时目录里本应用的导入副本（xmt_ 前缀）。
    try {
      final dir = await (tempDirLoader ?? _systemTemp)();
      var tempBytes = 0;
      var tempCount = 0;
      final types = <String, int>{};
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final base = pBasename(entity.path);
        if (!base.startsWith('xmt_')) continue;
        try {
          final size = await entity.length();
          tempBytes += size;
          tempCount++;
          final ext = entity.path.contains('.')
              ? '.${entity.path.split('.').last.toLowerCase()}'
              : '其他';
          types[ext] = (types[ext] ?? 0) + size;
        } catch (_) {
          // 单个文件读不到就跳过。
        }
      }
      if (tempBytes > 0) {
        final top = types.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        out.add(CacheEntry(
          id: 'temp',
          tool: '文字阅读器',
          name: '导入临时文件',
          detail: <String>[
            trf('{n} 个文件', {'n': '$tempCount'}),
            if (top.isNotEmpty) trf('多为 {v}', {'v': top.first.key}),
          ].join(' · '),
          bytes: tempBytes,
          kind: CacheKind.temp,
        ));
      }
    } catch (_) {
      // 临时目录不可枚举时跳过这一项。
    }

    // 3. 刷题 AI 解析缓存（SharedPreferences 中的 JSON map）。
    try {
      final prefs = await (prefsLoader ?? SharedPreferences.getInstance)();
      final raw = prefs.getString(QuizAiService.cacheStoreKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          out.add(CacheEntry(
            id: 'quiz-ai',
            tool: '刷题助手',
            name: 'AI 解析缓存',
            detail: '${trf('{n} 条解析', {'n': '${decoded.length}'})} · .json',
            bytes: raw.length * 2,
            kind: CacheKind.quizAi,
          ));
        }
      }
    } catch (_) {
      // 偏好不可用或内容损坏时跳过。
    }

    // 4. 已交卷的旧刷题记录（每条约 4KB，粗估值）。
    try {
      final count = await (sessionCountLoader ?? _sessionCount)();
      if (count > 0) {
        out.add(CacheEntry(
          id: 'quiz-sessions',
          tool: '刷题助手',
          name: '旧刷题记录',
          detail: trf('{n} 条已交卷记录', {'n': '$count'}),
          bytes: count * 4096,
          kind: CacheKind.quizRecords,
        ));
      }
    } catch (_) {
      // 题库还没初始化时跳过。
    }

    out.sort((a, b) => b.bytes.compareTo(a.bytes));
    return out;
  }

  /// 清理一条缓存，返回释放字节数。
  static Future<int> clean(
    CacheEntry entry, {
    Future<int> Function(String key)? nativeCleaner,
    Future<Directory> Function()? tempDirLoader,
    Future<SharedPreferences> Function()? prefsLoader,
  }) async {
    switch (entry.kind) {
      case CacheKind.runtime:
      case CacheKind.imports:
        if (entry.key.isEmpty) return 0;
        if (nativeCleaner != null) return nativeCleaner(entry.key);
        try {
          return (await _channel.invokeMethod<num>(
                    'clearCacheItem',
                    <String, Object?>{'key': entry.key},
                  ) ??
                  0)
              .toInt();
        } catch (_) {
          return 0;
        }
      case CacheKind.temp:
        var freed = 0;
        try {
          final dir = await (tempDirLoader ?? _systemTemp)();
          await for (final entity in dir.list(followLinks: false)) {
            if (entity is! File || !pBasename(entity.path).startsWith('xmt_')) {
              continue;
            }
            try {
              freed += await entity.length();
              await entity.delete();
            } catch (_) {
              // 占用中的文件跳过。
            }
          }
        } catch (_) {
          // 临时目录不可用时按 0 处理。
        }
        return freed;
      case CacheKind.quizAi:
        try {
          final prefs = await (prefsLoader ?? SharedPreferences.getInstance)();
          final raw = prefs.getString(QuizAiService.cacheStoreKey);
          if (raw == null) return 0;
          await prefs.remove(QuizAiService.cacheStoreKey);
          return raw.length * 2;
        } catch (_) {
          return 0;
        }
      case CacheKind.quizRecords:
        // 保留最近 50 条已交卷记录，旧记录才清掉。
        return ToolStorageService.pruneQuizSessions(keep: 50);
    }
  }

  static Future<List<Map<String, Object?>>> _nativeRows(
    Future<List<Map<String, Object?>>> Function()? loader,
  ) async {
    if (loader != null) {
      try {
        return await loader();
      } catch (_) {
        return const <Map<String, Object?>>[];
      }
    }
    try {
      final raw = await _channel.invokeListMethod<dynamic>('cacheItems');
      return (raw ?? const <dynamic>[])
          .whereType<Map<dynamic, dynamic>>()
          .map<Map<String, Object?>>(
            (m) => m.map<String, Object?>(
              (key, value) => MapEntry<String, Object?>(key.toString(), value),
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const <Map<String, Object?>>[];
    }
  }

  static String pBasename(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? path : parts.last;
  }
}

/// 统一成可注入的异步工厂，测试里可以指向临时目录。
Future<Directory> _systemTemp() async => Directory.systemTemp;

Future<int> _sessionCount() async {
  final quiz = await QuizDb.instance();
  return QuizRepository(quiz.db).finishedSessionCount();
}
