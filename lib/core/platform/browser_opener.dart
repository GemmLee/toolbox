import 'package:flutter/services.dart';

/// 用系统浏览器打开外部公开链接。
class BrowserOpener {
  BrowserOpener({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('toolbox/browser');

  final MethodChannel _channel;

  Future<bool> open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty) {
      return false;
    }
    try {
      final result =
          await _channel.invokeMethod<bool>('open', <String, Object?>{
        'url': uri.toString(),
      });
      return result ?? false;
    } on MissingPluginException {
      // 测试环境或旧版本原生未注册时，返回 false 由调用方提示。
      return false;
    } on PlatformException {
      return false;
    }
  }
}
