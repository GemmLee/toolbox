import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 便捷搜题悬浮窗的原生桥（Android）。
///
/// 弹窗本体在原生 Service 里用自绘 View 实现：不依赖 Flutter 引擎、
/// 不持有输入焦点，切到别的 App 也还能用。Dart 只负责三件事：
/// 查权限 / 申请权限 / 把题库快照落盘后启停悬浮窗。
class QuickSearchBridge {
  QuickSearchBridge._();

  static const MethodChannel _channel = MethodChannel('toolbox/quick_search');

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

  /// 跳系统授权页；返回 false 说明这台 ROM 没有该设置页，直接走降级。
  static Future<bool> requestOverlayPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 启动悬浮窗；权限被拒或被 ROM 拦截都返回 false。
  ///
  /// [bankIds] 为空表示搜索全部题库；窗口已经开着时再次调用只切换搜索范围。
  /// [maxResults] 是一次最多显示几道候选（相关度从高到低）。
  static Future<bool> show({
    required String indexPath,
    Set<String>? bankIds,
    int maxResults = 3,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('show', <String, Object?>{
            'indexPath': indexPath,
            'bankIds': bankIds?.toList(growable: false),
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

  /// 读取当前背景色偏好（原生侧为准，避免两端各存一份）。
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

/// 悬浮窗索引的文件名（放在应用私有目录，原生 Service 直接读）。
const String kQuickSearchIndexFile = 'quick_search_index.json';

/// 便捷搜题自己的索引：按开启页选的题库裁剪过，和智能搜题的全量索引分开，
/// 免得两个功能各自改掉对方的搜索范围。
const String kQuickSearchScopeIndexFile = 'quick_search_scope_index.json';

/// 悬浮窗能力包装：把四个静态方法收成一个可注入对象，widget 测试不用碰通道。
class QuickSearchHost {
  const QuickSearchHost({
    this.canDraw = _canDraw,
    this.request = _request,
    this.show = _show,
    this.hide = _hide,
    this.setTheme = _setTheme,
    this.currentTheme = _currentTheme,
  });

  final Future<bool> Function() canDraw;
  final Future<bool> Function() request;

  /// 第二个参数是只搜索的题库集合（null / 空 = 全部），第三个是每次最多显示几道题。
  final Future<bool> Function(
    String indexPath,
    Set<String>? bankIds,
    int maxResults,
  ) show;

  final Future<void> Function() hide;
  final Future<void> Function(String theme) setTheme;
  final Future<String?> Function() currentTheme;

  static Future<bool> _canDraw() => QuickSearchBridge.canDrawOverlay();
  static Future<bool> _request() =>
      QuickSearchBridge.requestOverlayPermission();
  static Future<bool> _show(
    String indexPath,
    Set<String>? bankIds,
    int maxResults,
  ) =>
      QuickSearchBridge.show(
        indexPath: indexPath,
        bankIds: bankIds,
        maxResults: maxResults,
      );
  static Future<void> _hide() => QuickSearchBridge.hide();
  static Future<void> _setTheme(String theme) =>
      QuickSearchBridge.setTheme(theme);
  static Future<String?> _currentTheme() => QuickSearchBridge.currentTheme();
}

/// 索引 JSON：原生侧只认 `questions[].stem / options / answer`。
String encodeQuickSearchIndex(List<Map<String, dynamic>> questions) =>
    jsonEncode(<String, dynamic>{
      'version': 1,
      'questions': questions,
    });

/// 把题库快照写进私有目录，返回绝对路径。
///
/// 每题只保留题干 / 选项 / 答案，几千题的 JSON 通常只有几百 KB。
Future<String> writeQuickSearchIndex(
  List<Map<String, dynamic>> questions, {
  Directory? directory,
  String fileName = kQuickSearchIndexFile,
}) async {
  final dir = directory ?? await getApplicationDocumentsDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsString(
    encodeQuickSearchIndex(questions),
    flush: true,
  );
  return file.path;
}
