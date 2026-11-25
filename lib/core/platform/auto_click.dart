import 'package:flutter/services.dart';

/// 自动点击的原生桥（Android）。
///
/// 真正的手势由无障碍服务 `dispatchGesture` 发出，悬浮控制面板由前台 Service
/// 管理；Dart 只负责权限引导、把配置下发给原生、以及启停。
class AutoClickBridge {
  AutoClickBridge._();

  static const MethodChannel _channel = MethodChannel('toolbox/auto_click');

  /// 悬浮面板「取点」回调：坐标是屏幕宽高的百分比（0~100）。
  static void Function(double x, double y)? _pointListener;

  static Future<bool> _bool(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> canDrawOverlay() => _bool('canDraw');

  static Future<bool> requestOverlayPermission() => _bool('requestPermission');

  static Future<bool> isAccessibilityEnabled() => _bool('accessibilityEnabled');

  static Future<bool> openAccessibilitySettings() =>
      _bool('openAccessibilitySettings');

  /// [config] 结构见 AutoClickConfig.toJson()。权限不全或系统版本过低返回 false。
  static Future<bool> start(Map<String, dynamic> config) => _bool(
        'start',
        Map<String, Object?>.from(config),
      );

  /// 面板已经挂在屏幕上时热更新动作序列（不改变正在运行的状态）。
  static Future<bool> updateConfig(Map<String, dynamic> config) => _bool(
        'update',
        Map<String, Object?>.from(config),
      );

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  static Future<bool> isRunning() => _bool('isRunning');

  /// 注册 / 取消「取点」回调；传 null 表示停止监听。
  static void listenPoints(void Function(double x, double y)? listener) {
    _pointListener = listener;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPointPicked') {
        final args = call.arguments;
        if (args is Map) {
          final x = args['x'];
          final y = args['y'];
          if (x is num && y is num) {
            _pointListener?.call(x.toDouble(), y.toDouble());
          }
        }
      }
      return null;
    });
  }
}

/// 可注入包装：widget 测试不碰原生通道。
class AutoClickHost {
  const AutoClickHost({
    this.canDraw = _canDraw,
    this.requestOverlay = _requestOverlay,
    this.accessibility = _accessibility,
    this.openSettings = _openSettings,
    this.start = _start,
    this.stop = _stop,
    this.isRunning = _isRunning,
    this.updateConfig = _updateConfig,
    this.listenPoints = _listenPoints,
  });

  final Future<bool> Function() canDraw;
  final Future<bool> Function() requestOverlay;
  final Future<bool> Function() accessibility;
  final Future<bool> Function() openSettings;
  final Future<bool> Function(Map<String, dynamic> config) start;
  final Future<void> Function() stop;
  final Future<bool> Function() isRunning;

  /// 面板在屏时同步配置；测试可传 null 关掉热更新。
  final Future<bool> Function(Map<String, dynamic> config)? updateConfig;

  /// 注册取点回调；传 null 表示这次会话不支持取点。
  final void Function(void Function(double x, double y)? listener)? listenPoints;

  static Future<bool> _canDraw() => AutoClickBridge.canDrawOverlay();
  static Future<bool> _requestOverlay() =>
      AutoClickBridge.requestOverlayPermission();
  static Future<bool> _accessibility() =>
      AutoClickBridge.isAccessibilityEnabled();
  static Future<bool> _openSettings() =>
      AutoClickBridge.openAccessibilitySettings();
  static Future<bool> _start(Map<String, dynamic> config) =>
      AutoClickBridge.start(config);
  static Future<void> _stop() => AutoClickBridge.stop();
  static Future<bool> _isRunning() => AutoClickBridge.isRunning();
  static Future<bool> _updateConfig(Map<String, dynamic> config) =>
      AutoClickBridge.updateConfig(config);
  static void _listenPoints(void Function(double x, double y)? listener) =>
      AutoClickBridge.listenPoints(listener);
}
