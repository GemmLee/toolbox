import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用存储空间的分类。
///
/// [profile] 归在「个人信息」下，其余归在「存储文件」下：工具产生的文件
/// （题库 JSON、备份、AI 生成内容）都会自动落到各自的工具目录，用户可以在
/// 「用户 → 存储空间」里统一查看、分享、导出、重命名或删除。
enum AppStoreCategory {
  profile('profile', '个人信息', '个人信息数据、背景图等', Icons.person_outline),
  quiz('quiz', '刷题助手', '题库文件与刷题备份', Icons.quiz_outlined),
  assistant('assistant', 'AI 助手', 'AI 生成的文件', Icons.auto_awesome_outlined),
  reader('reader', '文字阅读器', '从微信 / QQ 等导入的文档', Icons.article_outlined),
  other('other', '其他', '手动添加的其他文件', Icons.folder_open_outlined);

  const AppStoreCategory(this.id, this.label, this.hint, this.icon);

  /// 磁盘目录名（同时用于持久化，不随文案变化）。
  final String id;
  final String label;
  final String hint;
  final IconData icon;

  /// 是否属于「个人信息」分组。
  bool get isProfile => this == AppStoreCategory.profile;

  /// 分组名。
  String get group => isProfile ? '个人信息' : '存储文件';
}

/// 存储空间里的一个文件。
class StoredFile {
  const StoredFile({
    required this.category,
    required this.file,
    required this.size,
    required this.modified,
  });

  final AppStoreCategory category;
  final File file;
  final int size;
  final DateTime modified;

  String get path => file.path;

  String get name => p.basename(file.path);

  String get extension {
    final ext = p.extension(name).toLowerCase();
    return ext.startsWith('.') ? ext.substring(1) : ext;
  }

  bool get isImage => const <String>{
        'png',
        'jpg',
        'jpeg',
        'webp',
        'gif',
        'bmp',
      }.contains(extension);

  bool get isText => const <String>{
        'json',
        'md',
        'txt',
        'csv',
        'tsv',
        'yaml',
        'yml',
        'xml',
        'log',
      }.contains(extension);
}

/// 应用内文件仓库：统一负责目录、命名、读写与统计。
///
/// 根目录：`<ApplicationDocuments>/app_storage/<category>/`。
class AppStore {
  AppStore._();

  static Directory? _rootOverride;

  /// 测试用：把根目录指到临时目录，避免依赖 path_provider。
  static void useRootForTest(Directory? dir) => _rootOverride = dir;

  static Future<Directory> root() async {
    final override = _rootOverride;
    if (override != null) {
      if (!override.existsSync()) await override.create(recursive: true);
      return override;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'app_storage'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> dirOf(AppStoreCategory category) async {
    final dir = Directory(p.join((await root()).path, category.id));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// 列出文件（按修改时间倒序）；[category] 为空时列出全部分类。
  static Future<List<StoredFile>> list([AppStoreCategory? category]) async {
    final categories = category == null
        ? AppStoreCategory.values
        : <AppStoreCategory>[category];
    final out = <StoredFile>[];
    for (final c in categories) {
      final dir = await dirOf(c);
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        out.add(StoredFile(
          category: c,
          file: entity,
          size: stat.size,
          modified: stat.modified,
        ));
      }
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  static Future<List<StoredFile>> listOf(AppStoreCategory category) =>
      list(category);

  /// 保存字节内容；同名时自动加 `(2)` 后缀。
  static Future<StoredFile> saveBytes({
    required AppStoreCategory category,
    required String name,
    required List<int> bytes,
    bool overwrite = false,
  }) async {
    final dir = await dirOf(category);
    final safeName = sanitizeName(name);
    final fileName = overwrite ? safeName : await _uniqueName(dir, safeName);
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return _stored(category, file);
  }

  static Future<StoredFile> saveText({
    required AppStoreCategory category,
    required String name,
    required String content,
    bool overwrite = false,
  }) =>
      saveBytes(
        category: category,
        name: name,
        bytes: utf8.encode(content),
        overwrite: overwrite,
      );

  /// 把一个已存在的文件复制进存储空间（导入时归档）。
  static Future<StoredFile> adopt({
    required AppStoreCategory category,
    required File source,
    String? name,
  }) async {
    final dir = await dirOf(category);
    final fileName = await _uniqueName(
      dir,
      sanitizeName(name ?? p.basename(source.path)),
    );
    final target = File(p.join(dir.path, fileName));
    await source.copy(target.path);
    return _stored(category, target);
  }

  /// 读取文本文件。
  ///
  /// [maxBytes] 用于给超大文件兜底：只读前一段并允许半个 UTF-8 字符，
  /// 避免把几十 MB 的日志一次性读进内存导致 OOM。
  static Future<String> readText(StoredFile file, {int? maxBytes}) async {
    if (maxBytes == null) return file.file.readAsString();
    final handle = await file.file.open();
    try {
      final length = await handle.length();
      final take = length > maxBytes ? maxBytes : length;
      final bytes = await handle.read(take);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await handle.close();
    }
  }

  static Future<void> delete(StoredFile file) async {
    if (file.file.existsSync()) await file.file.delete();
  }

  static Future<StoredFile> rename(StoredFile file, String newName) async {
    final dir = file.file.parent;
    final desired = sanitizeName(newName);
    if (desired.isEmpty) {
      throw const FileSystemException('文件名不能为空');
    }
    final target = File(p.join(dir.path, desired));
    if (target.path == file.file.path) return file;
    if (target.existsSync()) {
      throw FileSystemException('同名文件已存在', desired);
    }
    final moved = await file.file.rename(target.path);
    return _stored(file.category, moved);
  }

  static Future<int> usedBytes([AppStoreCategory? category]) async {
    final files = await list(category);
    return files.fold<int>(0, (sum, f) => sum + f.size);
  }

  static Future<Map<AppStoreCategory, int>> bytesByCategory() async {
    final out = <AppStoreCategory, int>{
      for (final c in AppStoreCategory.values) c: 0,
    };
    for (final f in await list()) {
      out[f.category] = (out[f.category] ?? 0) + f.size;
    }
    return out;
  }

  /// 去掉路径分隔符等非法字符，保留扩展名。
  static String sanitizeName(String raw) {
    final base = p.basename(raw.trim());
    final cleaned = base.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    return cleaned.trim().isEmpty ? '文件' : cleaned;
  }

  static Future<String> _uniqueName(Directory dir, String name) async {
    if (!File(p.join(dir.path, name)).existsSync()) return name;
    final ext = p.extension(name);
    final stem =
        ext.isEmpty ? name : name.substring(0, name.length - ext.length);
    var i = 2;
    while (File(p.join(dir.path, '$stem($i)$ext')).existsSync()) {
      i++;
    }
    return '$stem($i)$ext';
  }

  static Future<StoredFile> _stored(
      AppStoreCategory category, File file) async {
    final stat = await file.stat();
    return StoredFile(
      category: category,
      file: file,
      size: stat.size,
      modified: stat.modified,
    );
  }
}
