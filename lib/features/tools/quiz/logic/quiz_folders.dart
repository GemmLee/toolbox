import 'dart:convert';

import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';

/// 题库分类文件夹。
///
/// 归属、文件夹列表与折叠状态一起存在题库库的 settings 表里，
/// 随着题库备份 / 恢复整库走，无需为它改 schema。
class QuizFolder {
  const QuizFolder({
    required this.id,
    required this.name,
    this.expanded = true,
  });

  final String id;
  final String name;
  final bool expanded;

  QuizFolder copyWith({String? name, bool? expanded}) => QuizFolder(
        id: id,
        name: name ?? this.name,
        expanded: expanded ?? this.expanded,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'expanded': expanded,
      };

  static QuizFolder? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return QuizFolder(
      id: id,
      name: raw['name']?.toString() ?? '',
      expanded: raw['expanded'] != false,
    );
  }
}

class QuizFoldersData {
  const QuizFoldersData({
    this.folders = const <QuizFolder>[],
    this.assign = const <String, String>{},
    this.uncategorizedExpanded = true,
  });

  /// 文件夹（保持创建顺序）。
  final List<QuizFolder> folders;

  /// bankId → folderId。没有记录的题库归入「未分类」。
  final Map<String, String> assign;

  /// 「未分类」分组的展开状态。
  final bool uncategorizedExpanded;

  String? folderIdOf(String bankId) => assign[bankId];

  List<Bank> banksOf(String? folderId, List<Bank> banks) => banks
      .where((b) => (assign[b.id] ?? '') == (folderId ?? ''))
      .toList(growable: false);

  QuizFoldersData copyWith({
    List<QuizFolder>? folders,
    Map<String, String>? assign,
    bool? uncategorizedExpanded,
  }) =>
      QuizFoldersData(
        folders: folders ?? this.folders,
        assign: assign ?? this.assign,
        uncategorizedExpanded:
            uncategorizedExpanded ?? this.uncategorizedExpanded,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'folders': folders.map((f) => f.toJson()).toList(),
        'assign': assign,
        'uncategorizedExpanded': uncategorizedExpanded,
      };

  static QuizFoldersData fromJson(Object? raw) {
    if (raw is! Map) return const QuizFoldersData();
    final folders = <QuizFolder>[];
    if (raw['folders'] is List) {
      for (final item in (raw['folders'] as List)) {
        final f = QuizFolder.fromJson(item);
        if (f != null) folders.add(f);
      }
    }
    final assign = <String, String>{};
    if (raw['assign'] is Map) {
      (raw['assign'] as Map).forEach((key, value) {
        final bankId = key?.toString();
        final folderId = value?.toString();
        if (bankId != null && folderId != null) assign[bankId] = folderId;
      });
    }
    return QuizFoldersData(
      folders: folders,
      assign: assign,
      uncategorizedExpanded: raw['uncategorizedExpanded'] != false,
    );
  }

  static const String storeKey = 'quiz_folders';

  static Future<QuizFoldersData> load(QuizRepository repo) async {
    final raw = await repo.getSetting(storeKey);
    if (raw == null || raw.isEmpty) return const QuizFoldersData();
    try {
      return fromJson(jsonDecode(raw));
    } catch (_) {
      return const QuizFoldersData();
    }
  }

  static Future<void> save(QuizRepository repo, QuizFoldersData data) =>
      repo.setSetting(storeKey, jsonEncode(data.toJson()));
}
