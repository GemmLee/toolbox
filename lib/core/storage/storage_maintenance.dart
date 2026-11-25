import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../tool_registry.dart';
import '../../features/tools/quiz/data/quiz_repository.dart';
import 'app_files.dart';

/// 一个工具的空间占用。
class ToolUsage {
  const ToolUsage({
    required this.toolId,
    required this.fileBytes,
    required this.dataBytes,
    required this.details,
    required this.hasData,
  });

  final String toolId;

  /// 存储空间里归这个工具的文件。
  final int fileBytes;

  /// 偏好设置 / 数据库里的用户数据。
  final int dataBytes;

  /// 明细文案（页面直接展示）。
  final List<String> details;

  /// 是否有可清理的用户数据。
  final bool hasData;

  int get totalBytes => fileBytes + dataBytes;
}

/// 工具级别的空间统计与清理。
///
/// 工具代码本身编译进同一个 APK，无法拆出「单个体积」，所以这里只统计
/// 用户数据（存储空间文件 + 偏好设置 + 题库数据库）；页面会明确写出
/// 「工具随应用安装，不单独占用」。
class ToolStorageService {
  ToolStorageService._();

  /// 工具 → 存储空间分类（该分类的文件视作这个工具的数据）。
  static const Map<String, AppStoreCategory> categoryOf =
      <String, AppStoreCategory>{
    'quiz': AppStoreCategory.quiz,
    'assistant': AppStoreCategory.assistant,
    'text_reader': AppStoreCategory.reader,
  };

  /// 工具 → 偏好 key 前缀。
  static const Map<String, List<String>> prefsPrefixes = <String, List<String>>{
    'salary': <String>['salary_'],
    'quiz': <String>['quiz_'],
    'assistant': <String>['assistant_', 'ai_'],
    'auto_click': <String>['auto_click'],
    'device_status': <String>['battery_', 'device_'],
    'typhoon': <String>['typhoon_'],
  };

  /// 统计某个工具的占用。
  static Future<ToolUsage> usageOf(ToolDefinition tool) async {
    final details = <String>[];
    var fileBytes = 0;
    var dataBytes = 0;

    final category = categoryOf[tool.id];
    if (category != null) {
      final files = await AppStore.listOf(category);
      fileBytes = files.fold<int>(0, (sum, f) => sum + f.size);
      if (fileBytes > 0) {
        details.add('存储空间 · ${category.label} ${files.length} 个文件');
      }
    }

    if (tool.id == 'quiz') {
      final dbBytes = await _quizDatabaseBytes();
      if (dbBytes > 0) {
        fileBytes += dbBytes;
        details.add('题库数据库');
      }
    }

    final prefs = await _prefsBytesOf(tool.id);
    dataBytes += prefs;
    if (prefs > 0) details.add('偏好设置与记录');

    return ToolUsage(
      toolId: tool.id,
      fileBytes: fileBytes,
      dataBytes: dataBytes,
      details: details,
      hasData: fileBytes > 0 || dataBytes > 0,
    );
  }

  /// 清理某个工具的用户数据。
  ///
  /// 只删「工具自己的数据」：题库工具保留题库本身，仅清掉刷题记录与备份；
  /// 工资工具清掉工资记录与房贷方案（调用方必须先二次确认）。
  static Future<int> clear(ToolDefinition tool) async {
    var freed = 0;
    final category = categoryOf[tool.id];
    if (category != null) {
      for (final file in await AppStore.listOf(category)) {
        freed += file.size;
        try {
          await AppStore.delete(file);
        } catch (_) {
          // 单个文件删不掉不影响整体清理。
        }
      }
    }
    if (tool.id == 'quiz') {
      freed += await pruneQuizSessions(keep: 0);
    }
    freed += await _removePrefs(tool.id);
    return freed;
  }

  /// 只清理可再生的临时数据（备份、已完成会话），不动用户主体内容。
  static Future<int> clearTemporary(ToolDefinition tool) async {
    var freed = 0;
    if (tool.id == 'quiz') {
      freed += await pruneQuizSessions(keep: 30);
    }
    return freed;
  }

  static Future<int> _prefsBytesOf(String toolId) async {
    final prefixes = prefsPrefixes[toolId];
    if (prefixes == null) return 0;
    final prefs = await SharedPreferences.getInstance();
    var total = 0;
    for (final key in prefs.getKeys()) {
      if (!prefixes.any(key.startsWith)) continue;
      total += _valueBytes(prefs.get(key)) + key.length * 2;
    }
    return total;
  }

  static Future<int> _removePrefs(String toolId) async {
    final prefixes = prefsPrefixes[toolId];
    if (prefixes == null) return 0;
    final prefs = await SharedPreferences.getInstance();
    var freed = 0;
    for (final key in prefs.getKeys().toList(growable: false)) {
      if (!prefixes.any(key.startsWith)) continue;
      freed += _valueBytes(prefs.get(key)) + key.length * 2;
      await prefs.remove(key);
    }
    return freed;
  }

  static int _valueBytes(Object? value) => switch (value) {
        final String v => v.length * 2,
        final List<String> v =>
          v.fold<int>(0, (sum, item) => sum + item.length * 2),
        _ => 16,
      };

  static Future<int> _quizDatabaseBytes() async {
    try {
      final path = p.join(await getDatabasesPath(), 'quiz.db');
      final file = File(path);
      return file.existsSync() ? await file.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// 删除已完成的旧会话，[keep] 为保留条数（0 表示全删），返回释放字节粗估。
  ///
  /// 刷题记录是唯一会无限增长的数据：每练一次就多一条 sessions 与其明细。
  /// 保留最近的记录足够回看，旧记录清掉能明显回收空间。
  static Future<int> pruneQuizSessions({int keep = 30}) async {
    try {
      // 用仓库的共享连接，避免重复 openDatabase 后 close 掉页面正在用的库。
      final quiz = await QuizDb.instance();
      final removed =
          await QuizRepository(quiz.db).pruneFinishedSessions(keep: keep);
      // 一条会话含题目明细，粗估 4KB；只用于给用户一个可感知的数字。
      return removed * 4096;
    } catch (_) {
      return 0;
    }
  }
}

/// 全应用的空间回收：临时目录 + 各工具缓存。
class StorageMaintenance {
  StorageMaintenance._();

  /// 清理系统临时目录里本应用的缓存文件，返回释放字节数。
  static Future<int> clearTempFiles() async {
    var freed = 0;
    try {
      final dir = await getTemporaryDirectory();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
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
  }
}
