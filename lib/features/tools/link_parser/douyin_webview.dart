import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// 抖音页面里取回的作品事实（对应 YunX `DouyinParser.WebPayload`）。
class DouyinWebPayload {
  const DouyinWebPayload({
    this.title = '',
    this.desc = '',
    this.author = '',
    this.video = '',
    this.cover = '',
    this.images = const <String>[],
    this.motions = const <String>[],
    this.source = '',
  });

  final String title;
  final String desc;
  final String author;

  /// 无水印视频直链（页面详情接口里的 play_addr 已换成 /play/）。
  final String video;
  final String cover;
  final List<String> images;

  /// 与 [images] 一一对应的动图资源；没有动图时是等长的空串。
  final List<String> motions;

  /// 数据来源：ssr / hook / dom，排查「为什么这次没拿到」用。
  final String source;

  bool get hasMedia => images.isNotEmpty || video.isNotEmpty;

  factory DouyinWebPayload.fromJson(Map<String, dynamic> json) =>
      DouyinWebPayload(
        title: (json['title'] ?? '').toString(),
        desc: (json['desc'] ?? '').toString(),
        author: (json['author'] ?? '').toString(),
        video: (json['video'] ?? '').toString(),
        cover: (json['cover'] ?? '').toString(),
        images: _strings(json['images']),
        motions: _strings(json['motions']),
        source: (json['src'] ?? '').toString(),
      );

  static List<String> _strings(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw
        .map((item) => item?.toString() ?? '')
        .where((item) => item.isNotEmpty && item != 'null')
        .toList(growable: false);
  }
}

/// 抖音解析通道：让原生隐藏 WebView 真跑一遍页面。
///
/// 纯 HTTP 拿不到抖音作品数据——分享页会 302 到 `www.douyin.com` 并被
/// `byted_acrawler` 的 JS 挑战挡下来，页面里的详情接口又要 `a_bogus` 等签名。
/// YunX 的做法就是开一个 1×1 的隐藏 WebView 把页面跑起来，再从页面自己的
/// 详情响应 / SSR 里取直链，这里照搬同一条通道。
class DouyinWebViewBridge {
  DouyinWebViewBridge({this.invoker});

  static const MethodChannel _channel = MethodChannel('toolbox/link_webview');

  /// 测试注入：替代真实 MethodChannel。
  final Future<String?> Function(String method, Map<String, dynamic> args)?
      invoker;

  /// 打开作品页并取回事实；[id] 是作品 id，[kind] 为 `video` / `note`。
  ///
  /// 返回 null 表示这次没拿到（页面风控、加载超时、没有 WebView），
  /// 上层据此给「换个网络重试」这类明确提示，而不是造一个假直链。
  Future<DouyinWebPayload?> load({
    required String id,
    required String kind,
    Duration timeout = const Duration(seconds: 55),
  }) async {
    final args = <String, dynamic>{'id': id, 'kind': kind};
    String? raw;
    try {
      raw = invoker != null
          ? await invoker!('douyinParse', args)
          : await _channel
              .invokeMethod<String>('douyinParse', args)
              .timeout(timeout);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } on TimeoutException {
      return null;
    }
    if (raw == null || raw.isEmpty || raw == 'null') return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final payload = DouyinWebPayload.fromJson(decoded.cast<String, dynamic>());
      return payload.hasMedia ? payload : null;
    } catch (_) {
      return null;
    }
  }
}
