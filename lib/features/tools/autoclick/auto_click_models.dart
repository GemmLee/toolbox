import '../../../core/storage/local_store.dart';

/// 自动点击支持的动作。坐标一律按屏幕宽高的百分比（0~100），换设备不用重填。
enum AutoClickActionType {
  tap('tap'),
  swipe('swipe'),
  back('back'),
  wait('wait');

  const AutoClickActionType(this.id);

  final String id;

  static AutoClickActionType fromId(String? id) => switch (id) {
        'swipe' => AutoClickActionType.swipe,
        'back' => AutoClickActionType.back,
        'wait' => AutoClickActionType.wait,
        _ => AutoClickActionType.tap,
      };
}

/// 动作展示名（简体中文源文案，页面统一过 tr()）。
String autoClickActionLabel(AutoClickActionType type) => switch (type) {
      AutoClickActionType.tap => '点击',
      AutoClickActionType.swipe => '滑动',
      AutoClickActionType.back => '返回',
      AutoClickActionType.wait => '等待',
    };

class AutoClickAction {
  const AutoClickAction({
    required this.id,
    this.type = AutoClickActionType.tap,
    this.x = 50,
    this.y = 50,
    this.x2 = 50,
    this.y2 = 50,
    this.durationMs = 100,
  });

  final String id;
  final AutoClickActionType type;
  final double x;
  final double y;
  final double x2;
  final double y2;
  final int durationMs;

  /// 该动作需要填写哪些坐标。
  bool get needsPoint =>
      type == AutoClickActionType.tap || type == AutoClickActionType.swipe;

  bool get needsEndPoint => type == AutoClickActionType.swipe;

  /// 该动作的时长含义：点击/滑动是手势时长，等待是暂停时长。
  bool get needsDuration => type != AutoClickActionType.back;

  AutoClickAction copyWith({
    AutoClickActionType? type,
    double? x,
    double? y,
    double? x2,
    double? y2,
    int? durationMs,
  }) =>
      AutoClickAction(
        id: id,
        type: type ?? this.type,
        x: x ?? this.x,
        y: y ?? this.y,
        x2: x2 ?? this.x2,
        y2: y2 ?? this.y2,
        durationMs: durationMs ?? this.durationMs,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type.id,
        'x': x,
        'y': y,
        'x2': x2,
        'y2': y2,
        'durationMs': durationMs,
      };

  factory AutoClickAction.fromJson(Map<String, dynamic> json) =>
      AutoClickAction(
        id: (json['id'] ?? '').toString(),
        type: AutoClickActionType.fromId(json['type']?.toString()),
        x: _double(json['x'], 50, 0, 100),
        y: _double(json['y'], 50, 0, 100),
        x2: _double(json['x2'], 50, 0, 100),
        y2: _double(json['y2'], 50, 0, 100),
        durationMs: _int(json['durationMs'], 100, 10, 60000),
      );
}

/// 一整套操作配置。[repeat] = 0 表示无限循环。
class AutoClickConfig {
  const AutoClickConfig({
    this.actions = const <AutoClickAction>[],
    this.intervalMs = 500,
    this.randomDelayMs = 0,
    this.repeat = 0,
  });

  final List<AutoClickAction> actions;
  final int intervalMs;
  final int randomDelayMs;
  final int repeat;

  static AutoClickConfig defaults() => const AutoClickConfig(
        actions: <AutoClickAction>[
          AutoClickAction(
            id: 'sample',
            type: AutoClickActionType.tap,
            x: 50,
            y: 50,
            durationMs: 80,
          ),
        ],
      );

  AutoClickConfig copyWith({
    List<AutoClickAction>? actions,
    int? intervalMs,
    int? randomDelayMs,
    int? repeat,
  }) =>
      AutoClickConfig(
        actions: actions ?? this.actions,
        intervalMs: _int(intervalMs, this.intervalMs, 50, 60000),
        randomDelayMs: _int(randomDelayMs, this.randomDelayMs, 0, 60000),
        repeat: _int(repeat, this.repeat, 0, 9999),
      );

  /// 传给原生通道；全部是 num / String，避免 Kotlin 侧再做类型转换。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'actions': actions.map((e) => e.toJson()).toList(growable: false),
        'intervalMs': intervalMs,
        'randomDelayMs': randomDelayMs,
        'repeat': repeat,
      };

  factory AutoClickConfig.fromJson(Map<String, dynamic> json) {
    final raw = json['actions'];
    final actions = <AutoClickAction>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          actions.add(
            AutoClickAction.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return AutoClickConfig(
      actions: actions,
      intervalMs: _int(json['intervalMs'], 500, 50, 60000),
      randomDelayMs: _int(json['randomDelayMs'], 0, 0, 60000),
      repeat: _int(json['repeat'], 0, 0, 9999),
    );
  }
}

/// 本机保存配置（不写进存储空间，方便下次直接接着用）。
class AutoClickConfigStore {
  AutoClickConfigStore._();

  static const String storageKey = 'auto_click_config';

  static Future<AutoClickConfig> load() async {
    final json = await LocalStore.readMap(storageKey);
    if (json == null || json.isEmpty) return AutoClickConfig.defaults();
    return AutoClickConfig.fromJson(json);
  }

  static Future<void> save(AutoClickConfig config) =>
      LocalStore.writeMap(storageKey, config.toJson());
}

double _double(Object? value, double fallback, double lo, double hi) {
  final n = value is num ? value.toDouble() : fallback;
  if (!n.isFinite) return fallback;
  return n.clamp(lo, hi).toDouble();
}

int _int(Object? value, int fallback, int lo, int hi) {
  final n = value is num ? value.toInt() : fallback;
  return n.clamp(lo, hi);
}
