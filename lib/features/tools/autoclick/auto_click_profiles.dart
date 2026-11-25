import 'dart:convert';

import '../../../core/storage/local_store.dart';
import 'auto_click_models.dart';

/// 一套命名的动作序列方案：给同一工具保存多份配置（如「每日签到」「刷关卡」）。
class AutoClickProfile {
  const AutoClickProfile({
    required this.id,
    required this.name,
    required this.config,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final AutoClickConfig config;

  /// 最后修改时间（毫秒），列表按它倒序展示。
  final int updatedAt;

  AutoClickProfile copyWith({
    String? id,
    String? name,
    AutoClickConfig? config,
    int? updatedAt,
  }) =>
      AutoClickProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        config: config ?? this.config,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  AutoClickProfile touched() =>
      copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'config': config.toJson(),
        'updatedAt': updatedAt,
      };

  factory AutoClickProfile.fromJson(Map<String, dynamic> json) {
    final rawConfig = json['config'];
    return AutoClickProfile(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      config: rawConfig is Map<String, dynamic>
          ? AutoClickConfig.fromJson(rawConfig)
          : (rawConfig is Map
              ? AutoClickConfig.fromJson(Map<String, dynamic>.from(rawConfig))
              : AutoClickConfig.defaults()),
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 多方案仓库。落 SharedPreferences，导出为可分享的 JSON。
///
/// 兼容旧版本：以前只有单配置 [AutoClickConfigStore.storageKey]，首次读取时
/// 把它迁移成名为「默认方案」的一套，之后都以多方案为准。
class AutoClickProfileStore {
  AutoClickProfileStore._();

  static const String profilesKey = 'auto_click_profiles';
  static const String activeKey = 'auto_click_active_profile';
  static const String defaultName = '默认方案';

  /// 读回全部方案（按修改时间倒序）。旧单配置会自动迁移成一套默认方案。
  static Future<List<AutoClickProfile>> load() async {
    final map = await LocalStore.readMap(profilesKey);
    final raw = map?['profiles'];
    final out = <AutoClickProfile>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          out.add(AutoClickProfile.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    if (out.isNotEmpty) {
      out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return out;
    }
    // 迁移旧的单配置；读不到就给一套默认方案。
    final legacy = await LocalStore.readMap(AutoClickConfigStore.storageKey);
    final config = legacy == null || legacy.isEmpty
        ? AutoClickConfig.defaults()
        : AutoClickConfig.fromJson(legacy);
    final migrated = <AutoClickProfile>[
      AutoClickProfile(
        id: _newId(),
        name: defaultName,
        config: config,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
    await save(migrated, migrated.first.id);
    return migrated;
  }

  /// 当前激活方案 id；没记录时回落到列表第一套。
  static Future<String> activeIdOf(List<AutoClickProfile> profiles) async {
    final map = await LocalStore.readMap(profilesKey);
    final saved = map?['active']?.toString() ?? '';
    if (saved.isNotEmpty && profiles.any((p) => p.id == saved)) return saved;
    return profiles.isNotEmpty ? profiles.first.id : '';
  }

  static Future<void> save(
    List<AutoClickProfile> profiles,
    String activeId,
  ) =>
      LocalStore.writeMap(profilesKey, <String, dynamic>{
        'version': 1,
        'active': activeId,
        'profiles': profiles.map((p) => p.toJson()).toList(growable: false),
      });

  static int _seq = 0;

  static String _newId([int salt = 0]) {
    _seq++;
    return 'p_${DateTime.now().microsecondsSinceEpoch}_${_seq}_$salt';
  }

  static AutoClickProfile create(String name, AutoClickConfig config) =>
      AutoClickProfile(
        id: _newId(),
        name: name.trim().isEmpty ? defaultName : name.trim(),
        config: config,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

  /// 导出为可分享的 JSON（含全部方案与激活 id）。
  static String exportJson(
    List<AutoClickProfile> profiles,
    String activeId,
  ) =>
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'app': 'xmtools-autoclick',
        'version': 1,
        'active': activeId,
        'profiles': profiles.map((p) => p.toJson()).toList(growable: false),
      });

  /// 从 JSON 文本解析方案；结构不对时抛 [FormatException] 交给 UI 提示。
  static List<AutoClickProfile> parseJson(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('不是合法的 JSON');
    }
    final map = decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{};
    final raw = map['profiles'];
    if (raw is! List || raw.isEmpty) {
      throw const FormatException('文件里没有动作方案');
    }
    final out = <AutoClickProfile>[];
    for (final item in raw) {
      if (item is Map) out.add(AutoClickProfile.fromJson(Map<String, dynamic>.from(item)));
    }
    if (out.isEmpty) throw const FormatException('文件里没有有效的动作方案');
    return out;
  }

  /// 导入方案：重新分配 id（避免与本机冲突），同名加「(导入)」后缀，
  /// 与现有列表合并后写回。返回新导入的方案 id，便于 UI 选中第一套。
  static Future<List<String>> import(
    String text, {
    List<AutoClickProfile>? current,
    String? activeId,
  }) async {
    final incoming = parseJson(text);
    final profiles = current != null
        ? List<AutoClickProfile>.from(current)
        : await load();
    final names = profiles.map((p) => p.name).toSet();
    final ids = <String>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < incoming.length; i++) {
      var name = incoming[i].name;
      var suffix = 1;
      while (names.contains(name)) {
        name = '${incoming[i].name}（导入${suffix > 1 ? suffix : ''}）';
        suffix++;
      }
      names.add(name);
      final profile = incoming[i].copyWith(
        id: _newId(i),
        name: name,
        updatedAt: now + i,
      );
      profiles.add(profile);
      ids.add(profile.id);
    }
    await save(
      profiles,
      activeId ?? (profiles.isEmpty ? '' : profiles.first.id),
    );
    return ids;
  }
}
