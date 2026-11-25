import 'package:flutter/material.dart';

import 'storage/local_store.dart';

/// 工具注册项。
///
/// 扩展方式：新建一个工具页面，然后在 `lib/features/tools/builtin_tools.dart` 中
/// `ToolRegistry.register(...)` 一行即可，工具总览会自动出现入口。
class ToolDefinition {
  const ToolDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.category,
    required this.builder,
    this.accent,
    this.keywords = const <String>[],
  });

  /// 稳定标识，用于埋点/收藏等后续能力，不要随意修改。
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final String category;
  final WidgetBuilder builder;
  final Color? accent;
  final List<String> keywords;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        description.toLowerCase().contains(q) ||
        category.toLowerCase().contains(q) ||
        keywords.any((k) => k.toLowerCase().contains(q));
  }
}

/// 全局工具注册表（进程内单例）。
///
/// 展示顺序 = 注册顺序，用户可以自定义并持久化（改动写进 SharedPreferences
/// 的 `tool_order`），也可以一键恢复默认顺序。
class ToolRegistry {
  ToolRegistry._();

  static const String orderKey = 'tool_order';

  /// 收进「折叠工具栏」的工具 id（与顺序分开存，互不影响）。
  static const String foldedKey = 'tool_folded';

  /// 首次进入时收进折叠栏的工具：使用频度较低或偏专业。
  /// 只记 id，未注册的工具会被自动忽略；用户一旦自己调过就以偏好为准。
  static const Set<String> defaultFoldedIds = <String>{
    'id_photo',
    'crypto',
    'chess',
    'typhoon',
    'qrcode',
    'news',
    'measure',
  };

  /// 迁移标记：旧版本曾把水印默认折叠，升级后一次性把它从折叠栏放出。
  static const String _watermarkFoldMigratedKey =
      'tool_folded_watermark_migrated';

  /// 迁移标记：测量工具改为默认折叠，老用户已有偏好时一次性把它收进去。
  static const String _measureFoldMigratedKey = 'tool_folded_measure_migrated';

  static final List<ToolDefinition> _tools = <ToolDefinition>[];

  /// 注册时的原始顺序，用于「重置顺序」。
  static final List<ToolDefinition> _registered = <ToolDefinition>[];

  static final Set<String> _folded = <String>{};

  static List<ToolDefinition> get tools =>
      List<ToolDefinition>.unmodifiable(_tools);

  /// 收进折叠栏的工具，顺序跟随 [tools]。
  static List<ToolDefinition> get foldedTools =>
      _tools.where((tool) => _folded.contains(tool.id)).toList(growable: false);

  /// 留在总览网格里的工具，顺序跟随 [tools]。
  static List<ToolDefinition> get pinnedTools => _tools
      .where((tool) => !_folded.contains(tool.id))
      .toList(growable: false);

  static bool isFolded(String id) => _folded.contains(id);

  /// 默认（注册）顺序。
  static List<ToolDefinition> get defaultOrder =>
      List<ToolDefinition>.unmodifiable(_registered);

  static bool get isDefaultOrder {
    if (_tools.length != _registered.length) return false;
    for (var i = 0; i < _tools.length; i++) {
      if (_tools[i].id != _registered[i].id) return false;
    }
    return true;
  }

  static void register(ToolDefinition tool) {
    if (_tools.any((t) => t.id == tool.id)) {
      throw StateError('工具 id 重复注册：${tool.id}');
    }
    _tools.add(tool);
    _registered.add(tool);
  }

  static void registerAll(Iterable<ToolDefinition> tools) {
    for (final tool in tools) {
      register(tool);
    }
  }

  static List<ToolDefinition> search(String query) =>
      tools.where((t) => t.matches(query)).toList(growable: false);

  /// 按 id 顺序重排；未列出的工具保持原有相对顺序排在最后。
  static void applyOrder(List<String> ids) {
    final byId = <String, ToolDefinition>{
      for (final tool in _tools) tool.id: tool,
    };
    final ordered = <ToolDefinition>[];
    for (final id in ids) {
      final tool = byId.remove(id);
      if (tool != null) ordered.add(tool);
    }
    ordered.addAll(byId.values);
    _tools
      ..clear()
      ..addAll(ordered);
  }

  /// 保存用户自定义顺序。
  static Future<void> saveOrder(List<String> ids) async {
    applyOrder(ids);
    await LocalStore.writeMap(orderKey, <String, dynamic>{
      'ids': _tools.map((tool) => tool.id).toList(growable: false),
    });
  }

  /// 恢复注册顺序并清掉持久化记录（折叠状态一并回到默认）。
  static Future<void> resetOrder() async {
    _tools
      ..clear()
      ..addAll(_registered);
    final known = _tools.map((tool) => tool.id).toSet();
    _folded
      ..clear()
      ..addAll(defaultFoldedIds.where(known.contains));
    await LocalStore.remove(orderKey);
    await LocalStore.remove(foldedKey);
  }

  /// 设置某个工具是否收进折叠栏并立即持久化。
  static Future<void> setFolded(String id, bool folded) async {
    if (folded == _folded.contains(id)) return;
    if (folded) {
      _folded.add(id);
    } else {
      _folded.remove(id);
    }
    await _writeFolded();
  }

  /// 用一组 id 覆盖折叠集合（拖进 / 拖出折叠栏后调用）。
  static Future<void> saveFolded(Iterable<String> ids) async {
    final known = _tools.map((tool) => tool.id).toSet();
    final next = ids.where(known.contains).toSet();
    if (next.length == _folded.length && next.containsAll(_folded)) return;
    _folded
      ..clear()
      ..addAll(next);
    await _writeFolded();
  }

  static Future<void> _writeFolded() => LocalStore.writeMap(foldedKey, {
        'ids': _tools
            .where((tool) => _folded.contains(tool.id))
            .map((tool) => tool.id)
            .toList(growable: false),
      });

  /// 启动时读取折叠栏；没有记录（首次进入）时套用默认折叠名单。
  /// 用户存下的空列表代表「主动全部平铺」，不能被默认名单覆盖。
  static Future<void> loadFolded() async {
    try {
      final json = await LocalStore.readMap(foldedKey);
      final raw = json?['ids'];
      final ids = raw == null
          ? defaultFoldedIds
          : (raw as List<dynamic>).whereType<String>();
      final known = _tools.map((tool) => tool.id).toSet();
      _folded
        ..clear()
        ..addAll(ids.where(known.contains));

      // 一次性迁移：旧默认折叠过水印的老用户升级后也把它放出折叠栏。
      final migrated = await LocalStore.readMap(_watermarkFoldMigratedKey);
      if (migrated?['done'] != true && _folded.remove('watermark')) {
        await _writeFolded();
      }
      if (migrated?['done'] != true) {
        await LocalStore.writeMap(_watermarkFoldMigratedKey, {'done': true});
      }

      // 一次性迁移：老用户的偏好记录里没有 measure，升级后收进折叠栏。
      final measureMigrated = await LocalStore.readMap(_measureFoldMigratedKey);
      if (measureMigrated?['done'] != true && known.contains('measure')) {
        if (_folded.add('measure')) await _writeFolded();
        await LocalStore.writeMap(_measureFoldMigratedKey, {'done': true});
      }
    } catch (_) {
      // 读取失败按「全部平铺」处理。
    }
  }

  /// 启动时读取用户自定义顺序。
  static Future<void> loadOrder() async {
    try {
      final json = await LocalStore.readMap(orderKey);
      final ids = (json?['ids'] as List<dynamic>?)
              ?.whereType<String>()
              .toList(growable: false) ??
          const <String>[];
      if (ids.isNotEmpty) applyOrder(ids);
    } catch (_) {
      // 读取失败按默认顺序展示。
    }
  }

  /// 测试用：清空注册表。
  static void resetForTest() {
    _tools.clear();
    _registered.clear();
    _folded.clear();
  }
}
