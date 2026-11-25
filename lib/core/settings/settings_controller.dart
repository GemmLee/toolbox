import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_background.dart';
import 'assistant_profile.dart';
import 'default_open_tools.dart';
import 'theme_palette.dart';
import 'tool_texts.dart';
import 'assistant_platforms.dart';
import '../storage/local_store.dart';

/// 应用语言选项（system = 跟随系统）。
enum AppLanguage {
  system('system', '跟随系统'),
  simplifiedChinese('zh', '简体中文'),
  traditionalChinese('zh_TW', '繁體中文'),
  english('en', 'English');

  const AppLanguage(this.code, this.nativeName);

  final String code;
  final String nativeName;

  static AppLanguage fromCode(String? code) {
    for (final lang in values) {
      if (lang.code == code) return lang;
    }
    return system;
  }
}

/// 全局设置：外观模式 / 主题色 / 语言，变更即时持久化并通知重建。
class SettingsController extends ChangeNotifier {
  SettingsController._();

  static final SettingsController instance = SettingsController._();

  static const String _storeKey = 'app_settings';

  ThemeMode themeMode = ThemeMode.system;
  String themeColorId = ThemePalette.defaultId;
  AppLanguage language = AppLanguage.system;

  /// 全局文字缩放（1.0 = 系统默认）。
  double fontScale = 1.0;

  /// 背景设置。
  BackgroundKind backgroundKind = BackgroundKind.none;
  String backgroundColorId = AppBackgrounds.colors.first.id;
  String backgroundGradientId = AppBackgrounds.gradients.first.id;
  String? backgroundImagePath;

  /// 自定义背景图的平均亮度（0~1，线性亮度）。用于决定叠在图片上的
  /// 标题、状态栏图标与裸露文字该用白字还是深字；老版本没有此值时为 null，
  /// 按主题默认前景色处理。
  double? backgroundImageLuminance;

  /// 「默认打开工具」：按格式组 id 存动作 key，未设置的用该格式默认值。
  Map<String, String> defaultOpenTools = <String, String>{};

  /// 在线题库资源域名覆盖：留空表示使用内置 R2 域名（quiz_remote_index 中的常量）。
  /// 换域名/自建域时在此覆盖，网页端 xmhome.html 的 R2_BASE 需同步。
  String quizResourceBaseUrl = '';

  // —— AI 配置（多配置管理） ——

  /// 所有 AI 配置；`activeAssistantProfileId` 指向当前使用的配置。
  /// API Key 仅保存在本机，不内置任何默认值。
  List<AssistantProfile> assistantProfiles = <AssistantProfile>[];
  String activeAssistantProfileId = '';

  /// 用户自定义的 OpenAI 兼容平台（不在主流预设列表内的厂商）。
  /// 保存在本机，供所有 AI 配置复用。
  List<AssistantPlatform> customAssistantPlatforms = <AssistantPlatform>[];

  AssistantProfile? get activeAssistantProfile {
    for (final p in assistantProfiles) {
      if (p.id == activeAssistantProfileId) return p;
    }
    return assistantProfiles.isEmpty ? null : assistantProfiles.first;
  }

  /// 兼容视图：读取当前激活配置的连接信息。
  String get assistantApiKey => activeAssistantProfile?.apiKey ?? '';
  String get assistantBaseUrl =>
      activeAssistantProfile?.baseUrl ?? kDefaultAssistantBaseUrl;
  String get assistantModel =>
      activeAssistantProfile?.model ?? kDefaultAssistantModel;

  /// 累计 token 用量（来自接口 usage 字段）。
  int assistantTokensIn = 0;
  int assistantTokensOut = 0;

  bool get assistantConfigured =>
      assistantApiKey.isNotEmpty && assistantModel.isNotEmpty;

  /// 是否启用过多配置管理（一次性迁移标记）。
  bool _profilesMigrated = false;

  static const double minFontScale = 0.85;
  static const double maxFontScale = 1.35;

  bool _loaded = false;
  bool get loaded => _loaded;

  /// 测试专用：清空内存状态，使下一次 load() 重新读取。
  @visibleForTesting
  void resetForTest() {
    themeMode = ThemeMode.system;
    themeColorId = ThemePalette.defaultId;
    language = AppLanguage.system;
    fontScale = 1.0;
    backgroundKind = BackgroundKind.none;
    backgroundColorId = AppBackgrounds.colors.first.id;
    backgroundGradientId = AppBackgrounds.gradients.first.id;
    backgroundImagePath = null;
    backgroundImageLuminance = null;
    assistantProfiles = <AssistantProfile>[];
    activeAssistantProfileId = '';
    customAssistantPlatforms = <AssistantPlatform>[];
    _profilesMigrated = false;
    assistantTokensIn = 0;
    assistantTokensOut = 0;
    defaultOpenTools = <String, String>{};
    quizResourceBaseUrl = '';
    _loaded = false;
  }

  ThemePaletteEntry get themeColor => ThemePalette.byId(themeColorId);

  /// 「跟随系统」时按平台 locale 解析出的实际语言。
  AppLanguage get effectiveLanguage {
    final selected = language;
    if (selected != AppLanguage.system) return selected;
    final locale = PlatformDispatcher.instance.locale;
    if (locale.languageCode == 'zh') {
      return locale.scriptCode == 'Hant'
          ? AppLanguage.traditionalChinese
          : AppLanguage.simplifiedChinese;
    }
    if (locale.languageCode == 'en') return AppLanguage.english;
    return AppLanguage.simplifiedChinese;
  }

  /// 跟随系统时返回 null，交给 MaterialApp 按 supportedLocales 解析。
  Locale? get locale => switch (language) {
        AppLanguage.traditionalChinese =>
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        AppLanguage.english => const Locale('en'),
        AppLanguage.simplifiedChinese => const Locale('zh'),
        AppLanguage.system => null,
      };

  Future<void> load() async {
    if (_loaded) return;
    final map = await LocalStore.readMap(_storeKey);
    if (map != null) {
      themeMode = switch (map['themeMode']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      themeColorId = ThemePalette.byId(map['themeColor'] as String?).id;
      language = AppLanguage.fromCode(map['language'] as String?);
      final scale = map['fontScale'];
      if (scale is num) {
        fontScale = scale.toDouble().clamp(minFontScale, maxFontScale);
      }
      backgroundKind = switch (map['backgroundKind']) {
        'color' => BackgroundKind.color,
        'gradient' => BackgroundKind.gradient,
        'image' => BackgroundKind.image,
        _ => BackgroundKind.none,
      };
      backgroundColorId =
          AppBackgrounds.colorById(map['backgroundColor'] as String?)?.id ??
              AppBackgrounds.colors.first.id;
      backgroundGradientId =
          AppBackgrounds.gradientById(map['backgroundGradient'] as String?)
                  ?.id ??
              AppBackgrounds.gradients.first.id;
      backgroundImagePath = map['backgroundImage'] as String?;
      final imageLuminance = map['backgroundImageLuminance'];
      backgroundImageLuminance = imageLuminance is num
          ? imageLuminance.toDouble().clamp(0.0, 1.0)
          : null;
      // 多配置迁移：首次升级时把旧的单配置转成 profile，
      // 并按需求清除已存储的 API Key（不迁移密钥）。
      final rawProfiles = map['assistantProfiles'];
      if (rawProfiles is List) {
        assistantProfiles = rawProfiles
            .whereType<Map>()
            .map((m) => AssistantProfile.fromJson(Map<String, dynamic>.from(m)))
            .toList();
        _profilesMigrated = true;
      }
      activeAssistantProfileId =
          map['activeAssistantProfileId'] as String? ?? '';
      if (assistantProfiles.isEmpty && !_profilesMigrated) {
        final legacyBase =
            map['assistantBaseUrl'] as String? ?? kDefaultAssistantBaseUrl;
        final legacyModel =
            map['assistantModel'] as String? ?? kDefaultAssistantModel;
        final migrated = AssistantProfile(
          id: AssistantProfile.newId(),
          name: '默认',
          baseUrl: legacyBase,
          model: legacyModel,
          apiKey: '', // 旧密钥一并清除，需要用户重新输入
        );
        assistantProfiles = <AssistantProfile>[migrated];
        activeAssistantProfileId = migrated.id;
      }
      if (activeAssistantProfileId.isEmpty && assistantProfiles.isNotEmpty) {
        activeAssistantProfileId = assistantProfiles.first.id;
      }
      assistantTokensIn = map['assistantTokensIn'] as int? ?? 0;
      assistantTokensOut = map['assistantTokensOut'] as int? ?? 0;
      final storedOpenTools = map['defaultOpenTools'];
      defaultOpenTools = storedOpenTools is Map
          ? storedOpenTools.map(
              (key, value) => MapEntry<String, String>('$key', '$value'),
            )
          : <String, String>{};
      quizResourceBaseUrl =
          (map['quizResourceBaseUrl'] as String? ?? '').trim();
      final rawCustom = map['customAssistantPlatforms'];
      customAssistantPlatforms = rawCustom is List
          ? rawCustom
              .whereType<Map>()
              .map((m) =>
                  AssistantPlatform.fromJson(Map<String, dynamic>.from(m)))
              .where((p) => p.name.isNotEmpty && p.baseUrl.isNotEmpty)
              .toList()
          : <AssistantPlatform>[];
    } else {
      _ensureDefaultProfile();
    }
    _loaded = true;
  }

  void _ensureDefaultProfile() {
    if (assistantProfiles.isNotEmpty) return;
    final profile = AssistantProfile(
      id: AssistantProfile.newId(),
      name: '默认',
      baseUrl: kDefaultAssistantBaseUrl,
      model: kDefaultAssistantModel,
    );
    assistantProfiles = <AssistantProfile>[profile];
    activeAssistantProfileId = profile.id;
  }

  /// 某种外部导入格式默认交给哪个工具处理。
  DefaultOpenAction defaultOpenActionFor(String fileName) {
    final rule = ruleForFileName(fileName);
    if (rule == null) return DefaultOpenAction.reader;
    final saved = actionFromKey(defaultOpenTools[rule.id]);
    if (saved != null && rule.actions.contains(saved)) return saved;
    return rule.defaultAction;
  }

  Future<void> setQuizResourceBaseUrl(String value) async {
    final trimmed = value.trim();
    if (quizResourceBaseUrl == trimmed) return;
    quizResourceBaseUrl = trimmed;
    await _persist();
  }

  Future<void> setDefaultOpenTool(
    String ruleId,
    DefaultOpenAction action,
  ) async {
    if (defaultOpenTools[ruleId] == actionKey(action)) return;
    defaultOpenTools = <String, String>{
      ...defaultOpenTools,
      ruleId: actionKey(action),
    };
    await _persist();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (themeMode == mode) return;
    themeMode = mode;
    await _persist();
  }

  Future<void> setThemeColor(String id) async {
    if (themeColorId == id) return;
    themeColorId = id;
    await _persist();
  }

  Future<void> setFontScale(double value) async {
    final clamped = value.clamp(minFontScale, maxFontScale);
    if ((fontScale - clamped).abs() < 0.001) return;
    fontScale = clamped;
    await _persist();
  }

  Future<void> setLanguage(AppLanguage value) async {
    if (language == value) return;
    language = value;
    await _persist();
  }

  Future<void> setBackgroundKind(BackgroundKind value) async {
    if (backgroundKind == value) return;
    backgroundKind = value;
    await _persist();
  }

  Future<void> setBackgroundColor(String id) async {
    if (backgroundColorId == id && backgroundKind == BackgroundKind.color) {
      return;
    }
    backgroundColorId = id;
    backgroundKind = BackgroundKind.color;
    await _persist();
  }

  Future<void> setBackgroundGradient(String id) async {
    if (backgroundGradientId == id &&
        backgroundKind == BackgroundKind.gradient) {
      return;
    }
    backgroundGradientId = id;
    backgroundKind = BackgroundKind.gradient;
    await _persist();
  }

  Future<void> setBackgroundImage(String? path, {double? luminance}) async {
    backgroundImagePath = path;
    backgroundImageLuminance = path == null ? null : luminance;
    backgroundKind = path == null || path.isEmpty
        ? BackgroundKind.none
        : BackgroundKind.image;
    await _persist();
  }

  /// 新建配置；第一个配置自动设为激活。
  Future<AssistantProfile> addAssistantProfile({
    required String name,
    required String baseUrl,
    required String model,
    String apiKey = '',
  }) async {
    final profile = AssistantProfile(
      id: AssistantProfile.newId(),
      name: name.trim().isEmpty ? tr('配置') : name.trim(),
      baseUrl: baseUrl.trim(),
      model: model.trim(),
      apiKey: apiKey.trim(),
    );
    assistantProfiles.add(profile);
    // 首个配置、或当前配置还没有 Key 而新配置带了 Key 时，自动切到新配置，
    // 避免「新建完却仍在用空配置」的错觉。
    final active = activeAssistantProfile;
    if (assistantProfiles.length == 1 ||
        active == null ||
        (active.apiKey.isEmpty && profile.apiKey.isNotEmpty)) {
      activeAssistantProfileId = profile.id;
    }
    await _persist();
    return profile;
  }

  /// 更新配置；任一参数为 null 时保留原值。
  Future<void> updateAssistantProfile(
    String id, {
    String? name,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) async {
    final index = assistantProfiles.indexWhere((p) => p.id == id);
    if (index < 0) return;
    assistantProfiles[index] = assistantProfiles[index].copyWith(
      name: name == null ? null : (name.trim().isEmpty ? null : name.trim()),
      baseUrl: baseUrl?.trim(),
      model: model?.trim(),
      apiKey: apiKey?.trim(),
    );
    await _persist();
  }

  /// 删除配置；删除激活配置时顺延激活第一个。
  Future<void> removeAssistantProfile(String id) async {
    assistantProfiles.removeWhere((p) => p.id == id);
    if (activeAssistantProfileId == id) {
      activeAssistantProfileId =
          assistantProfiles.isEmpty ? '' : assistantProfiles.first.id;
    }
    await _persist();
  }

  /// 切换当前使用的配置。
  Future<void> setActiveAssistantProfile(String id) async {
    if (activeAssistantProfileId == id) return;
    if (!assistantProfiles.any((p) => p.id == id)) return;
    activeAssistantProfileId = id;
    await _persist();
  }

  /// 累计 token 用量。
  Future<void> addAssistantUsage(int promptTokens, int completionTokens) async {
    if (promptTokens <= 0 && completionTokens <= 0) return;
    assistantTokensIn += promptTokens < 0 ? 0 : promptTokens;
    assistantTokensOut += completionTokens < 0 ? 0 : completionTokens;
    await _persist();
  }

  /// 清零累计 token 用量。
  Future<void> resetAssistantUsage() async {
    if (assistantTokensIn == 0 && assistantTokensOut == 0) return;
    assistantTokensIn = 0;
    assistantTokensOut = 0;
    await _persist();
  }

  // —— 自定义 AI 平台（预设之外的厂商，可复用） ——

  /// 新增自定义平台；名称/地址校验由 UI 层完成。
  Future<AssistantPlatform> addCustomAssistantPlatform({
    required String name,
    required String baseUrl,
    required List<String> models,
  }) async {
    final platform = AssistantPlatform(
      id: AssistantProfile.newId(),
      name: name.trim(),
      baseUrl: baseUrl.trim(),
      models: models,
      isCustom: true,
    );
    customAssistantPlatforms = <AssistantPlatform>[
      ...customAssistantPlatforms,
      platform,
    ];
    await _persist();
    return platform;
  }

  Future<void> updateCustomAssistantPlatform(
    String id, {
    required String name,
    required String baseUrl,
    required List<String> models,
  }) async {
    final index = customAssistantPlatforms.indexWhere((p) => p.id == id);
    if (index < 0) return;
    customAssistantPlatforms[index] = AssistantPlatform(
      id: id,
      name: name.trim(),
      baseUrl: baseUrl.trim(),
      models: models,
      isCustom: true,
    );
    await _persist();
  }

  Future<void> removeCustomAssistantPlatform(String id) async {
    customAssistantPlatforms.removeWhere((p) => p.id == id);
    await _persist();
  }

  Future<void> _persist() async {
    notifyListeners();
    await LocalStore.writeMap(_storeKey, <String, dynamic>{
      'themeMode': switch (themeMode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      },
      'themeColor': themeColorId,
      'language': language.code,
      'fontScale': fontScale,
      'backgroundKind': switch (backgroundKind) {
        BackgroundKind.color => 'color',
        BackgroundKind.gradient => 'gradient',
        BackgroundKind.image => 'image',
        BackgroundKind.none => 'none',
      },
      'backgroundColor': backgroundColorId,
      'backgroundGradient': backgroundGradientId,
      'backgroundImage': backgroundImagePath,
      'backgroundImageLuminance': backgroundImageLuminance,
      // 多配置管理；不再持久化旧的单配置字段（旧 API Key 已随迁移清除）。
      'assistantProfiles': assistantProfiles.map((p) => p.toJson()).toList(),
      'activeAssistantProfileId': activeAssistantProfileId,
      'customAssistantPlatforms':
          customAssistantPlatforms.map((p) => p.toJson()).toList(),
      'assistantTokensIn': assistantTokensIn,
      'assistantTokensOut': assistantTokensOut,
      'defaultOpenTools': defaultOpenTools,
      'quizResourceBaseUrl': quizResourceBaseUrl,
    });
  }
}
