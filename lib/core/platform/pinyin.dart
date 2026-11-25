import 'package:flutter/services.dart';

/// 汉字 → 拼音首字母（走原生系统 ICU，Android 7.0 起可用）。
///
/// 全局搜索的「首字母」口径：输入 `zgdd` 能匹配「中国的首都」。转换在原生侧
/// 完成（`PinyinInitials`，与便捷搜题悬浮窗共用同一份缓存），Dart 只负责批量
/// 送文本、拿结果。系统裁掉 ICU 时 [supported] 为 false，调用方降级提示。
class PinyinBridge {
  PinyinBridge._();

  static const MethodChannel _channel = MethodChannel('toolbox/pinyin');

  /// 批量转换一组文本的首字母串（非汉字字符直接被跳过）。
  ///
  /// 返回 null 表示当前系统不支持（无原生实现、API 过低或 ICU 被裁剪），
  /// 调用方应提示「当前系统不支持首字母搜索」而不是当成「没搜到」。
  static Future<({bool supported, List<String> initials})?> initialsOf(
    List<String> texts,
  ) async {
    if (texts.isEmpty) {
      return (supported: true, initials: const <String>[]);
    }
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'initials',
        <String, Object?>{'texts': texts},
      );
      if (raw == null) return null;
      final list = (raw['initials'] as List?)?.map((e) => '$e').toList() ??
          const <String>[];
      if (list.length != texts.length) return null;
      return (supported: raw['supported'] == true, initials: list);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
