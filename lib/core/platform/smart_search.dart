import 'package:flutter/services.dart';

/// 智能搜题的原生桥（Android）。
///
/// 与便捷搜题不同，这里需要两样系统能力：
/// - 「显示在其他应用上层」——结果窗与框选窗都是系统悬浮窗；
/// - 「无障碍服务」——只能靠它截屏取字（Android 11+ 直接 takeScreenshot，
///   不用每次弹录屏授权）。
///
/// 弹窗与 OCR 全在原生侧完成，Dart 只负责权限引导和启停。
class SmartSearchBridge {
  SmartSearchBridge._();

  static const MethodChannel _channel = MethodChannel('toolbox/smart_search');

  /// 是否已获得「显示在其他应用上层」权限。
  static Future<bool> canDrawOverlay() async {
    try {
      return await _channel.invokeMethod<bool>('canDraw') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 跳系统悬浮窗授权页；返回 false 说明这台 ROM 没有该设置页。
  static Future<bool> requestOverlayPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 无障碍服务是否已开启。
  static Future<bool> isAccessibilityEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('accessibilityEnabled') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 跳系统「无障碍」设置页。
  static Future<bool> openAccessibilitySettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAccessibilitySettings') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 启动悬浮窗；权限被拒或被 ROM 拦截都返回 false。
  ///
  /// [maxResults] 是一次最多显示几道候选（相关度从高到低）。
  static Future<bool> show({
    required String indexPath,
    int maxResults = 3,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('show', <String, Object?>{
            'indexPath': indexPath,
            'maxResults': maxResults,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 设置背景色偏好并实时刷新已开启的悬浮窗。
  static Future<void> setTheme(String theme) async {
    try {
      await _channel
          .invokeMethod<void>('setTheme', <String, Object?>{'theme': theme});
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  static Future<String?> currentTheme() async {
    try {
      return await _channel.invokeMethod<String>('getTheme');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<void> hide() async {
    try {
      await _channel.invokeMethod<void>('hide');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  static Future<bool> isShowing() async {
    try {
      return await _channel.invokeMethod<bool>('isShowing') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// 智能搜题能力包装：把通道收成可注入对象，widget 测试不碰原生。
class SmartSearchHost {
  const SmartSearchHost({
    this.canDraw = _canDraw,
    this.requestOverlay = _requestOverlay,
    this.accessibility = _accessibility,
    this.openSettings = _openSettings,
    this.show = _show,
    this.hide = _hide,
    this.setTheme = _setTheme,
    this.currentTheme = _currentTheme,
  });

  final Future<bool> Function() canDraw;
  final Future<bool> Function() requestOverlay;
  final Future<bool> Function() accessibility;
  final Future<bool> Function() openSettings;
  final Future<bool> Function(String indexPath, int maxResults) show;
  final Future<void> Function() hide;
  final Future<void> Function(String theme) setTheme;
  final Future<String?> Function() currentTheme;

  static Future<bool> _canDraw() => SmartSearchBridge.canDrawOverlay();
  static Future<bool> _requestOverlay() =>
      SmartSearchBridge.requestOverlayPermission();
  static Future<bool> _accessibility() =>
      SmartSearchBridge.isAccessibilityEnabled();
  static Future<bool> _openSettings() =>
      SmartSearchBridge.openAccessibilitySettings();
  static Future<bool> _show(String indexPath, int maxResults) =>
      SmartSearchBridge.show(indexPath: indexPath, maxResults: maxResults);
  static Future<void> _hide() => SmartSearchBridge.hide();
  static Future<void> _setTheme(String theme) =>
      SmartSearchBridge.setTheme(theme);
  static Future<String?> _currentTheme() => SmartSearchBridge.currentTheme();
}
