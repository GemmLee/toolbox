import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 长任务的「息屏保活 / 屏幕常亮」开关。
///
/// 走 Android 原生 `toolbox/wake_lock` 通道：
/// - `setCpuAwake` 持有 PARTIAL_WAKE_LOCK，息屏后 CPU 不休眠，网络任务可继续；
/// - `setKeepScreenOn` 设置窗口 FLAG_KEEP_SCREEN_ON，屏幕不自动熄灭。
///
/// 非 Android 平台（含 widget 测试）没有实现时静默降级：状态仍记录，
/// 但调用原生通道不抛异常，页面逻辑保持一致。
class KeepAwake {
  KeepAwake._();

  static const MethodChannel _channel = MethodChannel('toolbox/wake_lock');

  static bool _cpuAwake = false;
  static bool _screenOn = false;

  static bool get cpuAwake => _cpuAwake;
  static bool get screenOn => _screenOn;

  /// 一次性设置两个开关；重复设置相同值会跳过原生调用。
  static Future<void> set({
    required bool cpuAwake,
    required bool screenOn,
  }) async {
    final changed = cpuAwake != _cpuAwake || screenOn != _screenOn;
    _cpuAwake = cpuAwake;
    _screenOn = screenOn;
    if (!changed) return;
    try {
      await _channel.invokeMethod<void>('setCpuAwake',
          <String, Object?>{'enabled': cpuAwake});
      await _channel.invokeMethod<void>('setKeepScreenOn',
          <String, Object?>{'enabled': screenOn});
    } on MissingPluginException {
      // 测试环境或非 Android 平台：没有原生实现，保持状态即可。
    } on PlatformException {
      // 权限/机型不支持时不阻断业务。
    }
  }

  static Future<void> release() => set(cpuAwake: false, screenOn: false);

  @visibleForTesting
  static void resetForTest() {
    _cpuAwake = false;
    _screenOn = false;
  }
}
