import 'dart:convert';

import 'package:http/http.dart' as http;

import 'douyin_webview.dart';

/// 视频媒体的类别。
enum VideoMediaKind { video, image, audio }

/// 一条可下载的媒体（对应 YunX 的 `VideoMedia`）。
class VideoMediaItem {
  const VideoMediaItem({
    required this.url,
    required this.kind,
    this.isHls = false,
    this.quality = '',
    this.fileName = '',
    this.referer = '',
    this.userAgent = '',
  });

  final String url;
  final VideoMediaKind kind;

  /// m3u8 需要 HLS 分片下载，普通下载器只能存到播放列表本身。
  final bool isHls;
  final String quality;

  /// 保存时用的文件名；空则按 URL 末段推断。
  final String fileName;

  /// 直链防盗链头：B站/Pixiv 缺了会直接 403。
  final String referer;
  final String userAgent;
}

/// 视频解析结果（对应 YunX 的 `VideoParseResult`）。
class VideoParseResult {
  const VideoParseResult({
    required this.platform,
    required this.title,
    this.author = '',
    this.coverUrl,
    this.text = '',
    this.timestampSeconds = 0,
    this.media = const <VideoMediaItem>[],
    this.note = '',
  });

  final String platform;
  final String title;
  final String author;
  final String? coverUrl;
  final String text;
  final int timestampSeconds;
  final List<VideoMediaItem> media;
  final String note;
}

/// 视频解析失败：message 直接给用户看。
class VideoParseException implements Exception {
  const VideoParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 识别出来的视频链接。
class DetectedVideoLink {
  const DetectedVideoLink({
    required this.platform,
    required this.id,
    required this.kind,
    required this.url,
    this.isShort = false,
  });

  final String platform;
  final String id;
  final String kind;
  final String url;

  /// 短链（b23.tv / v.douyin.com / xhslink）需要先跟随一次跳转再识别。
  final bool isShort;
}

/// 视频平台解析：按 YunX 的 `VideoLinkParser` + 各 `*Parser` 移植。
///
/// B站、AcFun、快手、微博、Pixiv、小红书走纯 HTTP（接口 JSON 或页面内联 SSR）；
/// 抖音的数据被 `byted_acrawler` 的 JS 挑战挡在纯 HTTP 之外，改走原生隐藏
/// WebView（见 [DouyinWebViewBridge]），与 YunX 的主路线一致。
class VideoParser {
  /// 桌面 Chrome UA：多数站点的分享页用桌面 UA 返回完整 SSR。
  static const String uaChrome =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// iPhone UA：快手/抖音的移动页结构更稳。
  static const String uaIPhone =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 '
      'Safari/604.1';

  static final List<(RegExp, String, String)> _rules = <(RegExp, String, String)>[
    // 短链优先，避免被下面更宽的正则先吃掉。
    (
      RegExp(r'xhslink\.(?:com|cn)/[A-Za-z0-9._?%&+=/#@\-]+'),
      '小红书',
      'short'
    ),
    (RegExp(r'b23\.tv/[A-Za-z\d]+'), '哔哩哔哩', 'short'),
    (RegExp(r'bili2233\.cn/[A-Za-z\d]+'), '哔哩哔哩', 'short'),
    (RegExp(r'v\.douyin\.com/[A-Za-z0-9_\-]+'), '抖音', 'short'),
    // 极速版分享出来的短链，同样只带短码，要跟一次跳转才有作品 id。
    (RegExp(r'jx\.douyin\.com/[A-Za-z0-9_\-]+'), '抖音', 'short'),
    (RegExp(r'v\.kuaishou\.com/[A-Za-z\d._?%&+\-=/#]+'), '快手', 'short'),
    (RegExp(r'bilibili\.com/video/(BV[0-9a-zA-Z]{10}|av\d+)'), '哔哩哔哩', 'video'),
    (
      // 分享页 / 桌面页 / 精选页都收：`/share/video/<id>/`、`/video/<id>`、
      // `/note/<id>`、`/slides/<id>`、`jingxuan.douyin.com/m/video/<id>`。
      RegExp(
        r'douyin\.com/(?:share/)?(?:m/)?(?:video|note|slides)/(\d{6,})',
      ),
      '抖音',
      'video'
    ),
    (
      // 电脑版从「用户主页弹层」分享出来的是 `/user/self?modal_id=<作品id>`，
      // 作品 id 藏在参数里，没有它上面的规则一条都命中不了。
      RegExp(r'douyin\.com/[^\s]*[?&]modal_id=(\d{6,})'),
      '抖音',
      'video'
    ),
    (
      RegExp(
        r'xiaohongshu\.com/(?:explore|discovery/item|discovery)/([0-9a-zA-Z]{10,})',
      ),
      '小红书',
      'note'
    ),
    (
      RegExp(
        r'(?:www\.)?kuaishou\.com/(?:short-video|fw/photo|fw/long-video)/'
        r'([A-Za-z\d]+)',
      ),
      '快手',
      'photo'
    ),
    (RegExp(r'kuaishou\.com/f/([A-Za-z\d]+)'), '快手', 'photo'),
    (
      RegExp(
        r'(?:v\.m\.)?chenzhongtech\.com/fw/(?:photo|long-video)/([A-Za-z\d]+)',
      ),
      '快手',
      'photo'
    ),
    (RegExp(r'weibo\.com/tv/show/\d{4}:\d+\?mid=(\d+)'), '微博', 'tv'),
    (RegExp(r'video\.weibo\.com/show\?fid=(\d+:\d+)'), '微博', 'fid'),
    (
      RegExp(r'weibo\.cn/(?:status|statuses|detail)/([0-9a-zA-Z]+)'),
      '微博',
      'status'
    ),
    (RegExp(r'weibo\.com/\d+/([0-9a-zA-Z]{6,})'), '微博', 'status'),
    (RegExp(r'acfun\.cn/.*(?:ac=|/ac)(\d+)'), 'AcFun', 'ac'),
    (
      RegExp(
        r'pixiv\.net/(?:[a-z]{2}/)?artworks/(\d+)|'
        r'member_illust\.php\?[^#]*illust_id=(\d+)',
      ),
      'Pixiv',
      'artwork'
    ),
  ];

  /// 识别视频链接；不认识返回 null，交给通用 og 抓取。
  static DetectedVideoLink? detect(String url) {
    final text = url.trim();
    for (final rule in _rules) {
      final match = rule.$1.firstMatch(text);
      if (match == null) continue;
      var id = '';
      for (var i = 1; i <= match.groupCount; i++) {
        final value = match.group(i);
        if (value != null && value.isNotEmpty) {
          id = value;
          break;
        }
      }
      return DetectedVideoLink(
        platform: rule.$2,
        // 短链里的短码不是作品 id（跟着跳转才拿得到真 id），这里留空，
        // 免得上层拿短码去拼 `www.douyin.com/video/<短码>` 打开一个空页面。
        id: rule.$3 == 'short' ? '' : id,
        kind: rule.$3,
        url: text,
        isShort: rule.$3 == 'short',
      );
    }
    return null;
  }

  /// 解析入口：短链先展开，再按平台分发。
  ///
  /// [douyinBridge] 是抖音专用的原生 WebView 通道：抖音的详情数据被
  /// `byted_acrawler` 挑战挡在纯 HTTP 之外，只有真把页面跑一遍才拿得到。
  static Future<VideoParseResult> parse(
    String url, {
    String cookie = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
    DouyinWebViewBridge? douyinBridge,
  }) async {
    final own = client ?? http.Client();
    var target = url.trim();
    try {
      var detected = detect(target);
      if (detected == null) {
        throw const VideoParseException('没有识别出视频平台');
      }
      if (detected.isShort) {
        final resolved = await _resolveShort(
          own,
          target,
          detected.platform,
          timeout,
        );
        if (resolved != null && resolved != target) {
          target = resolved;
          detected = detect(resolved) ?? detected;
        }
      }
      if (detected.platform == '抖音') {
        return _douyin(detected, douyinBridge);
      }
      if (detected.platform == '哔哩哔哩') {
        return _bilibili(own, detected, cookie, timeout);
      }
      if (detected.platform == 'AcFun') {
        return _acfun(own, detected, cookie, timeout);
      }
      if (detected.platform == '快手') {
        return _kuaishou(own, detected, cookie, timeout);
      }
      if (detected.platform == '微博') {
        return _weibo(own, detected, cookie, timeout);
      }
      if (detected.platform == 'Pixiv') {
        return _pixiv(own, detected, cookie, timeout);
      }
      return _xhs(own, detected, cookie, timeout);
    } finally {
      if (client == null) own.close();
    }
  }

  // ---------------------------------------------------------------- 抖音

  /// 抖音：交给原生隐藏 WebView 跑页面取数据。
  ///
  /// 纯 HTTP 走不通已经不是「签名没拼对」的问题：分享页会 302 到
  /// `www.douyin.com`，返回的是 `byted_acrawler` 的 JS 挑战页（要算出
  /// `__ac_signature` 写回 Cookie 再 reload），而页面里的详情接口又要
  /// `a_bogus` / `msToken` 等每次请求都变的签名。所以这里和 YunX 一样
  /// 用 WebView 当执行环境，再从 SSR / 页面自己的详情响应里取直链。
  static Future<VideoParseResult> _douyin(
    DetectedVideoLink link,
    DouyinWebViewBridge? bridge,
  ) async {
    final id = link.id;
    if (!RegExp(r'^\d{6,}$').hasMatch(id)) {
      // 走到这里一定是短链没解开：抖音短链的 Location 里本来就有 id，
      // 拿不到只能是请求被拦或断网 —— 让用户换一条能直接打开的链接来。
      throw const VideoParseException(
        '这条抖音短链没能展开（没能拿到跳转后的作品地址）。'
        '可以在浏览器里打开一次这条短链，把跳转后的完整地址复制过来，'
        '或者改用抖音 App「分享 → 复制链接」重新复制一份。',
      );
    }
    final payload = await (bridge ?? DouyinWebViewBridge()).load(
      id: id,
      // 图文作品也走 video 路由：抖音会自己 302 到 /note/<id>，
      // 这里按链接自身的类型传，省一次跳转。
      kind: link.kind == 'note' || link.url.contains('/note/') ? 'note' : 'video',
    );
    if (payload == null) {
      throw const VideoParseException(
        '抖音这次没给出作品数据（风控挑战没通过或加载超时）。换个网络重试一次；'
        '一直失败的话，去系统里更新「Android System WebView」后再试。',
      );
    }
    final base = _fileNameBase(
      payload.title.isEmpty ? payload.desc : payload.title,
      'douyin_$id',
    );
    final media = <VideoMediaItem>[];
    if (payload.images.isNotEmpty) {
      for (var i = 0; i < payload.images.length; i++) {
        final url = payload.images[i];
        final motion = i < payload.motions.length && payload.motions[i].isNotEmpty;
        media.add(
          VideoMediaItem(
            url: url,
            kind: VideoMediaKind.image,
            // 动图的静图仍是 webp/jpeg；动图那一半我们只做静态保存，扩展名按原图给。
            fileName: '${base}_${i + 1}${motion ? '.jpg' : _extOf(url, '.jpg')}',
            referer: 'https://www.douyin.com/',
            userAgent: uaIPhone,
          ),
        );
      }
    } else {
      media.add(
        VideoMediaItem(
          url: payload.video,
          kind: VideoMediaKind.video,
          fileName: '$base.mp4',
          referer: 'https://www.douyin.com/',
          userAgent: uaIPhone,
        ),
      );
    }
    return VideoParseResult(
      platform: '抖音',
      title: payload.title.isEmpty ? base : payload.title,
      author: payload.author,
      coverUrl: payload.cover.isNotEmpty
          ? payload.cover
          : (payload.images.isEmpty ? null : payload.images.first),
      text: payload.desc.isEmpty ? payload.title : payload.desc,
      media: media,
      note: payload.images.isNotEmpty && payload.motions.any((m) => m.isNotEmpty)
          ? '这是动图作品，这里保存的是每一帧的静态原图。'
          : '',
    );
  }

  // ---------------------------------------------------------------- B 站

  static Future<VideoParseResult> _bilibili(
    http.Client client,
    DetectedVideoLink link,
    String cookie,
    Duration timeout,
  ) async {
    final headers = <String, String>{
      'User-Agent': uaChrome,
      'Referer': 'https://www.bilibili.com/',
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
    final isBv = link.id.toLowerCase().startsWith('bv');
    final viewUrl = isBv
        ? 'https://api.bilibili.com/x/web-interface/view?bvid=${link.id}'
        : 'https://api.bilibili.com/x/web-interface/view'
            '?aid=${link.id.replaceFirst(RegExp('^av'), '')}';
    final view = await _json(client, viewUrl, headers, timeout);
    if ((view['code'] as num?)?.toInt() != 0) {
      throw VideoParseException(
        'B 站接口返回错误 ${view['code']}：${view['message'] ?? ''}',
      );
    }
    final data = view['data'];
    if (data is! Map) throw const VideoParseException('B 站没有返回视频信息');
    final map = data.cast<String, dynamic>();
    final bvid = (map['bvid'] ?? '').toString();
    var cid = 0;
    final pages = map['pages'];
    if (pages is List && pages.isNotEmpty && pages.first is Map) {
      cid = ((pages.first as Map)['cid'] as num?)?.toInt() ?? 0;
    }
    if (cid == 0) cid = (map['cid'] as num?)?.toInt() ?? 0;
    if (bvid.isEmpty || cid <= 0) {
      throw const VideoParseException('B 站视频 ID 缺失，可能是分 P 结构变化');
    }

    final title = (map['title'] ?? '').toString();
    final base = _fileNameBase(title, 'bilibili_$bvid');
    final owner = map['owner'] is Map
        ? (map['owner'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final cover = _secure((map['pic'] ?? '').toString());

    // 单文件 durl：能直接下载播放。DASH 是音视频分离的两路流，
    // 当前下载器没有合轨能力，所以固定走单文件，避免给出下不了的链接。
    final playUrl = 'https://api.bilibili.com/x/player/playurl?bvid=$bvid'
        '&cid=$cid&qn=80&fnval=1&fnver=0&fourk=1&platform=html5&high_quality=1';
    final play = await _json(client, playUrl, headers, timeout);
    final playData = play['data'];
    final playMap = playData is Map
        ? playData.cast<String, dynamic>()
        : const <String, dynamic>{};
    final durl = playMap['durl'];
    if (durl is! List || durl.isEmpty || durl.first is! Map) {
      throw VideoParseException(
        'B 站没有返回可下载的视频流（${play['code'] ?? ''} ${play['message'] ?? ''}）',
      );
    }
    final first = (durl.first as Map).cast<String, dynamic>();
    final mediaUrl = _secure((first['url'] ?? '').toString());
    if (mediaUrl.isEmpty) {
      throw const VideoParseException('B 站视频直链为空，可能被风控拦截，请稍后重试');
    }
    final quality = _biliQuality((playMap['quality'] as num?)?.toInt() ?? 0);

    return VideoParseResult(
      platform: '哔哩哔哩',
      title: title,
      author: (owner['name'] ?? '').toString(),
      coverUrl: cover.isEmpty ? null : cover,
      text: (map['desc'] ?? '').toString(),
      timestampSeconds: (map['pubdate'] as num?)?.toInt() ?? 0,
      media: <VideoMediaItem>[
        VideoMediaItem(
          url: mediaUrl,
          kind: VideoMediaKind.video,
          quality: quality,
          fileName: '$base.mp4',
          referer: 'https://www.bilibili.com/',
          userAgent: uaChrome,
        ),
        if (cover.isNotEmpty)
          VideoMediaItem(
            url: cover,
            kind: VideoMediaKind.image,
            fileName: '${base}_cover.jpg',
            referer: 'https://www.bilibili.com/',
            userAgent: uaChrome,
          ),
      ],
      note: cookie.isEmpty
          ? 'B 站未登录只能拿到单文件低清直链；下载需要带 Referer，已随直链保存。'
          : '直链带 Referer 校验，已随直链保存，请用应用内下载。',
    );
  }

  static String _biliQuality(int qn) => switch (qn) {
        6 || 7 => '240P',
        16 => '360P',
        32 => '480P',
        64 => '720P',
        74 => '720P60',
        80 => '1080P',
        112 => '1080P+',
        116 => '1080P60',
        120 => '4K',
        _ => qn > 0 ? '${qn}P' : '',
      };

  // -------------------------------------------------------------- AcFun

  static Future<VideoParseResult> _acfun(
    http.Client client,
    DetectedVideoLink link,
    String cookie,
    Duration timeout,
  ) async {
    final url = 'https://www.acfun.cn/v/ac${link.id}'
        '?quickViewId=videoInfo_new&ajaxpipe=1';
    final response = await _raw(
      client,
      url,
      <String, String>{
        'User-Agent': uaChrome,
        'Referer': 'https://www.acfun.cn/',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      },
      timeout: timeout,
    );
    _requireOk(response);
    final html = utf8.decode(response.body, allowMalformed: true);
    final raw = _extractInlineJson(html, 'window.videoInfo');
    if (raw == null) {
      throw const VideoParseException('AcFun 页面里没有 videoInfo，稿件可能已删除');
    }
    // 这段内联 JSON 被转义了两层：先还原 \" 再还原反斜杠转义。
    final jsonText = _unescapeQuotes(raw.replaceAll('\\\\"', '\\"'));
    final Map<String, dynamic> info;
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) throw const FormatException('不是对象');
      info = decoded.cast<String, dynamic>();
    } catch (_) {
      throw const VideoParseException('AcFun 视频信息解析失败');
    }
    final title = (info['title'] ?? '').toString();
    final m3u8 = _acfunM3u8(info);
    if (m3u8 == null) throw const VideoParseException('AcFun 没有取到播放地址');
    final user = info['user'] is Map
        ? (info['user'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final cover = _secure((info['coverUrl'] ?? '').toString());
    final base = _fileNameBase(title, 'acfun_${link.id}');

    return VideoParseResult(
      platform: 'AcFun',
      title: title,
      author: (user['name'] ?? '').toString(),
      coverUrl: cover.isEmpty ? null : cover,
      text: (info['description'] ?? '').toString(),
      timestampSeconds: _parseDate((info['createTime'] ?? '').toString()),
      media: <VideoMediaItem>[
        VideoMediaItem(
          url: m3u8,
          kind: VideoMediaKind.video,
          isHls: true,
          quality: '720P',
          fileName: '$base.m3u8',
          referer: 'https://www.acfun.cn/',
          userAgent: uaChrome,
        ),
        if (cover.isNotEmpty)
          VideoMediaItem(
            url: cover,
            kind: VideoMediaKind.image,
            fileName: '${base}_cover.jpg',
            referer: 'https://www.acfun.cn/',
            userAgent: uaChrome,
          ),
      ],
      note: 'AcFun 返回的是 m3u8 播放列表，需要支持 HLS 的播放器；分片下载不在本工具范围内。',
    );
  }

  static String? _acfunM3u8(Map<String, dynamic> info) {
    final current = info['currentVideoInfo'];
    if (current is! Map) return null;
    var ksPlay = current['ksPlayJson'];
    if (ksPlay is String) {
      try {
        ksPlay = jsonDecode(ksPlay);
      } catch (_) {
        return null;
      }
    }
    if (ksPlay is! Map) return null;
    final sets = ksPlay['adaptationSet'];
    if (sets is! List || sets.isEmpty || sets.first is! Map) return null;
    final reps = (sets.first as Map)['representation'];
    if (reps is! List) return null;
    final urls = <String>[];
    for (final item in reps) {
      if (item is Map) {
        final value = (item['url'] ?? '').toString();
        if (value.isNotEmpty) urls.add(value);
      }
    }
    if (urls.isEmpty) return null;
    // 直链数组按 4K → 360P 降序，固定取第 4 档（≈720P），不足则取首档。
    return urls.length > 3 ? urls[3] : urls.first;
  }

  // -------------------------------------------------------------- 快手

  static Future<VideoParseResult> _kuaishou(
    http.Client client,
    DetectedVideoLink link,
    String cookie,
    Duration timeout,
  ) async {
    // 长视频页结构不同，统一换成 photo 页；再跟一次重定向到移动端作品页。
    var pageUrl = link.url.replaceAll('/fw/long-video/', '/fw/photo/');
    final headers = <String, String>{
      // 桌面 UA 会返回没有 INIT_STATE 的 SPA 页，必须用移动 UA。
      'User-Agent': uaIPhone,
      'Referer': 'https://v.kuaishou.com/',
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
    final page = await _raw(client, pageUrl, headers, timeout: timeout);
    _requireOk(page);
    var html = utf8.decode(page.body, allowMalformed: true);
    if (!html.contains('INIT_STATE') && link.kind == 'short') {
      pageUrl = page.finalUrl;
    }
    var state = _extractInlineJson(html, 'window.INIT_STATE');
    if (state == null) {
      // 少数入口先给跳转页，跟随一次再取。
      final retry = await _raw(client, pageUrl, headers, timeout: timeout);
      html = utf8.decode(retry.body, allowMalformed: true);
      state = _extractInlineJson(html, 'window.INIT_STATE');
    }
    if (state == null) {
      throw const VideoParseException('快手页面里没有 INIT_STATE，作品可能已删除或需要登录');
    }
    final Map<String, dynamic> photo;
    try {
      final decoded = jsonDecode(state);
      if (decoded is! Map) throw const FormatException('不是对象');
      photo = _findPhoto(decoded.cast<String, dynamic>()) ??
          <String, dynamic>{};
    } catch (_) {
      throw const VideoParseException('快手作品数据解析失败');
    }
    if (photo.isEmpty) throw const VideoParseException('快手没有找到作品数据');

    final caption = (photo['caption'] ?? '').toString();
    final base = _fileNameBase(caption, 'kuaishou_${link.id}');
    const referer = 'https://www.kuaishou.com/';
    final media = <VideoMediaItem>[];
    final videos = photo['mainMvUrls'];
    if (videos is List) {
      for (final item in videos) {
        if (item is Map) {
          final url = _secure((item['url'] ?? '').toString());
          if (url.isNotEmpty) {
            media.add(
              VideoMediaItem(
                url: url,
                kind: VideoMediaKind.video,
                fileName: '$base.mp4',
                referer: referer,
                userAgent: uaIPhone,
              ),
            );
            break;
          }
        }
      }
    }
    final cover = _firstUrl(photo['coverUrls']);
    final atlas = _kuaishouAtlas(photo);
    for (var i = 0; i < atlas.length; i++) {
      media.add(
        VideoMediaItem(
          url: atlas[i],
          kind: VideoMediaKind.image,
          fileName: '${base}_${i + 1}${_extOf(atlas[i], '.jpg')}',
          referer: referer,
          userAgent: uaIPhone,
        ),
      );
    }
    if (media.isEmpty) throw const VideoParseException('快手没有取到可下载的媒体');

    return VideoParseResult(
      platform: '快手',
      title: caption,
      author: (photo['userName'] ?? '').toString().replaceAll('\u3164', ''),
      coverUrl: cover,
      text: caption,
      timestampSeconds: ((photo['timestamp'] as num?)?.toInt() ?? 0) ~/ 1000,
      media: media,
      note: atlas.isNotEmpty ? '图集已按原图路由拼出，可逐张下载。' : '',
    );
  }

  /// INIT_STATE 是「作品 id → 数据」映射，key 不总是链接里的 id，
  /// 取第一个 photo 非空的即可（与 YunX 一致）。
  static Map<String, dynamic>? _findPhoto(Map<String, dynamic> state) {
    for (final value in state.values) {
      if (value is Map) {
        final photo = value['photo'];
        if (photo is Map && photo.isNotEmpty) {
          return photo.cast<String, dynamic>();
        }
      }
    }
    return null;
  }

  static List<String> _kuaishouAtlas(Map<String, dynamic> photo) {
    final ext = photo['ext_params'];
    if (ext is! Map) return const <String>[];
    final atlas = ext['atlas'];
    if (atlas is! Map) return const <String>[];
    final cdnList = atlas['cdnList'];
    String cdn = '';
    if (cdnList is List) {
      for (final item in cdnList) {
        if (item is Map) {
          cdn = (item['cdn'] ?? '').toString();
          if (cdn.isNotEmpty) break;
        }
      }
    }
    if (cdn.isEmpty) return const <String>[];
    final routes = atlas['list'];
    if (routes is! List) return const <String>[];
    final urls = <String>[];
    for (final item in routes) {
      if (item is Map) {
        final route = (item['path'] ?? item['cdn'] ?? '').toString();
        if (route.isNotEmpty) urls.add(_secure('$cdn/$route'));
      }
    }
    return urls;
  }

  // -------------------------------------------------------------- 微博

  static Future<VideoParseResult> _weibo(
    http.Client client,
    DetectedVideoLink link,
    String cookie,
    Duration timeout,
  ) async {
    if (link.kind == 'fid') {
      return _weiboFid(client, link, cookie, timeout);
    }
    var wid = link.id;
    if (link.kind == 'tv') {
      wid = _mid2id(link.id);
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final response = await _raw(
      client,
      'https://m.weibo.cn/statuses/show?id=$wid&_=$stamp',
      <String, String>{
        'User-Agent': uaChrome,
        'Accept': 'application/json, text/plain, */*',
        'Referer': 'https://m.weibo.cn/detail/$wid',
        'Origin': 'https://m.weibo.cn',
        'X-Requested-With': 'XMLHttpRequest',
        'MWeibo-Pwa': '1',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      },
      // 跟随重定向会被 302 到登录/验证页，必须自己看状态码。
      follow: false,
      timeout: timeout,
    );
    if (response.status != 200) {
      throw VideoParseException('微博接口返回 HTTP ${response.status}，可能触发了风控');
    }
    final type = (response.headers['content-type'] ?? '').toLowerCase();
    if (!type.contains('json')) {
      throw const VideoParseException('微博返回了验证页，请稍后重试或先登录微博');
    }
    final Map<String, dynamic> root;
    try {
      final decoded = jsonDecode(utf8.decode(response.body, allowMalformed: true));
      if (decoded is! Map) throw const FormatException('不是对象');
      root = decoded.cast<String, dynamic>();
    } catch (_) {
      throw const VideoParseException('微博返回内容解析失败');
    }
    var data = root['data'];
    if (data is! Map) throw const VideoParseException('微博没有返回正文数据');
    var map = data.cast<String, dynamic>();
    // 转发微博：外层没有媒体时进一层被转发的正文。
    if (!_weiboHasMedia(map) && map['retweeted_status'] is Map) {
      map = (map['retweeted_status'] as Map).cast<String, dynamic>();
    }
    return _weiboResult(map);
  }

  static Future<VideoParseResult> _weiboFid(
    http.Client client,
    DetectedVideoLink link,
    String cookie,
    Duration timeout,
  ) async {
    final fid = link.id;
    final response = await _raw(
      client,
      'https://h5.video.weibo.com/api/component?page=/show/$fid',
      <String, String>{
        'User-Agent': uaChrome,
        'Referer': 'https://h5.video.weibo.com/show/$fid',
        'Content-Type': 'application/x-www-form-urlencoded',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      },
      method: 'POST',
      body: 'data=${Uri.encodeQueryComponent('{"Component_Play_Playinfo":{"oid":"$fid"}}')}',
      timeout: timeout,
    );
    _requireOk(response);
    final Map<String, dynamic> info;
    try {
      final decoded = jsonDecode(utf8.decode(response.body, allowMalformed: true));
      final root = decoded is Map ? decoded.cast<String, dynamic>() : null;
      final data = root?['data'];
      final node = data is Map ? data['Component_Play_Playinfo'] : null;
      if (node is! Map) throw const FormatException('缺少播放信息');
      info = node.cast<String, dynamic>();
    } catch (_) {
      throw const VideoParseException('微博视频接口解析失败');
    }
    final title = (info['title'] ?? '').toString();
    final base = _fileNameBase(title, 'weibo_$fid');
    const referer = 'https://weibo.com/';
    final media = <VideoMediaItem>[];
    final url =
        _weiboBestUrl(info['urls']) ?? _secure((info['stream_url'] ?? '').toString());
    if (url.isNotEmpty) {
      media.add(
        VideoMediaItem(
          url: url,
          kind: VideoMediaKind.video,
          fileName: '$base.mp4',
          referer: referer,
          userAgent: uaChrome,
        ),
      );
    }
    final cover = _secure((info['cover_image'] ?? '').toString());
    if (cover.isNotEmpty) {
      media.add(
        VideoMediaItem(
          url: cover,
          kind: VideoMediaKind.image,
          fileName: '${base}_cover.jpg',
          referer: referer,
          userAgent: uaChrome,
        ),
      );
    }
    if (media.isEmpty) throw const VideoParseException('微博视频没有取到直链');
    return VideoParseResult(
      platform: '微博',
      title: title,
      author: (info['reward'] is Map)
          ? (((info['reward'] as Map)['user'] as Map?)?['name'] ?? '').toString()
          : '',
      coverUrl: cover.isEmpty ? null : cover,
      timestampSeconds: _parseDate((info['real_date'] ?? '').toString()),
      media: media,
      note: '微博直链带时效，下载请尽快。',
    );
  }

  static Future<VideoParseResult> _weiboResult(
    Map<String, dynamic> map,
  ) async {
    final media = <VideoMediaItem>[];
    final pageInfo = map['page_info'] is Map
        ? (map['page_info'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final weiboTitle = (pageInfo['title'] ?? '').toString();
    final base = _fileNameBase(weiboTitle, 'weibo_${map['id'] ?? 'item'}');
    const referer = 'https://weibo.com/';
    final videoUrl = _weiboBestUrl(pageInfo['urls']);
    if (videoUrl != null && videoUrl.isNotEmpty) {
      media.add(
        VideoMediaItem(
          url: videoUrl,
          kind: VideoMediaKind.video,
          fileName: '$base.mp4',
          referer: referer,
          userAgent: uaChrome,
        ),
      );
    }
    // 图集：large.url 是原图；videoSrc 是 Live Photo 的动态部分。
    final pics = map['pics'];
    if (pics is List) {
      var index = 0;
      for (final item in pics) {
        if (item is! Map) continue;
        final large = item['large'];
        final url = large is Map
            ? _secure((large['url'] ?? '').toString())
            : _secure((item['url'] ?? '').toString());
        if (url.isEmpty) continue;
        index++;
        media.add(
          VideoMediaItem(
            url: url,
            kind: VideoMediaKind.image,
            fileName: '${base}_$index${_extOf(url, '.jpg')}',
            referer: referer,
            userAgent: uaChrome,
          ),
        );
      }
    }
    if (media.isEmpty) throw const VideoParseException('这条微博没有可下载的图片或视频');
    final user = map['user'] is Map
        ? (map['user'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final cover = pageInfo['page_pic'] is Map
        ? _secure(((pageInfo['page_pic'] as Map)['url'] ?? '').toString())
        : null;

    return VideoParseResult(
      platform: '微博',
      title: weiboTitle,
      author: (user['screen_name'] ?? '').toString(),
      coverUrl: cover,
      text: _cleanWeiboText((map['text'] ?? '').toString()),
      timestampSeconds: _parseWeiboTime((map['created_at'] ?? '').toString()),
      media: media,
      note: '微博直链带时效，下载请尽快；Live Photo 只取静图。',
    );
  }

  static bool _weiboHasMedia(Map<String, dynamic> map) {
    final pageInfo = map['page_info'];
    if (pageInfo is Map && pageInfo['urls'] != null) return true;
    final pics = map['pics'];
    return pics is List && pics.isNotEmpty;
  }

  /// urls 是「码率 → 地址」字典，按高清优先取第一个非空。
  static String? _weiboBestUrl(Object? urls) {
    if (urls is String) return _secure(urls);
    if (urls is! Map) return null;
    for (final key in const <String>['mp4_720p_mp4', 'mp4_hd_mp4', 'mp4_ld_mp4']) {
      final value = urls[key];
      if (value is String && value.isNotEmpty) return _secure(value);
    }
    for (final value in urls.values) {
      if (value is String && value.isNotEmpty) return _secure(value);
    }
    return null;
  }

  /// 微博 mid → 数字 id：每 7 位一段，段内反转后按 base62 编码。
  static String _mid2id(String mid) {
    const alphabet =
        '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final reversed = mid.split('').reversed.toList();
    final size = (reversed.length + 6) ~/ 7;
    final encoded = <String>[];
    for (var i = 0; i < size; i++) {
      final start = i * 7;
      final end = start + 7 > reversed.length ? reversed.length : start + 7;
      if (start >= end) break;
      final segment = reversed.sublist(start, end).reversed.join();
      var value = int.tryParse(segment) ?? 0;
      var out = '';
      while (value > 0) {
        out = alphabet[value % 62] + out;
        value ~/= 62;
      }
      if (out.isEmpty) out = '0';
      if (i != size - 1) {
        while (out.length < 4) {
          out = '0$out';
        }
      }
      encoded.add(out);
    }
    return encoded.reversed.join();
  }

  static String _cleanWeiboText(String text) => text
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .trim();

  static int _parseWeiboTime(String value) {
    if (value.isEmpty) return 0;
    // 形如 "Wed Nov 06 12:00:00 +0800 2024"
    final match = RegExp(
      r'^\w{3} (\w{3}) (\d{2}) (\d{2}):(\d{2}):(\d{2}) ([+-]\d{4}) (\d{4})$',
    ).firstMatch(value.trim());
    if (match == null) return _parseDate(value);
    const months = <String, int>{
      'Jan': 1,
      'Feb': 2,
      'Mar': 3,
      'Apr': 4,
      'May': 5,
      'Jun': 6,
      'Jul': 7,
      'Aug': 8,
      'Sep': 9,
      'Oct': 10,
      'Nov': 11,
      'Dec': 12,
    };
    final month = months[match.group(1) ?? ''];
    if (month == null) return 0;
    final zone = match.group(6) ?? '+0800';
    final sign = zone.startsWith('-') ? -1 : 1;
    final offsetHours = int.tryParse(zone.substring(1, 3)) ?? 8;
    final offsetMinutes = int.tryParse(zone.substring(3, 5)) ?? 0;
    final local = DateTime.utc(
      int.tryParse(match.group(7) ?? '') ?? 1970,
      month,
      int.tryParse(match.group(2) ?? '') ?? 1,
      int.tryParse(match.group(3) ?? '') ?? 0,
      int.tryParse(match.group(4) ?? '') ?? 0,
      int.tryParse(match.group(5) ?? '') ?? 0,
    );
    return local.subtract(Duration(hours: sign * offsetHours, minutes: sign * offsetMinutes))
            .millisecondsSinceEpoch ~/
        1000;
  }

  // ------------------------------------------------------------- Pixiv

  static Future<VideoParseResult> _pixiv(
    http.Client client,
    DetectedVideoLink link,
    String cookie,
    Duration timeout,
  ) async {
    final headers = <String, String>{
      'User-Agent': uaChrome,
      'Referer': 'https://www.pixiv.net/',
      'Accept': 'application/json',
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
    final detail = await _json(
      client,
      'https://www.pixiv.net/ajax/illust/${link.id}',
      headers,
      timeout,
    );
    if (detail['error'] == true) {
      final message = (detail['message'] ?? '').toString();
      if (message.toLowerCase().contains('not found')) {
        throw const VideoParseException('Pixiv 作品不存在或已删除');
      }
      throw VideoParseException(
        cookie.isEmpty ? 'Pixiv 需要登录：这个作品受限，请先填写 Cookie' : 'Pixiv 解析失败：$message',
      );
    }
    final body = detail['body'];
    if (body is! Map) throw const VideoParseException('Pixiv 没有返回作品信息');
    final info = body.cast<String, dynamic>();
    if ((info['illustType'] as num?)?.toInt() == 2) {
      throw const VideoParseException('Pixiv 动图（ugoira）需要合成 GIF，暂不支持');
    }

    final pages = await _json(
      client,
      'https://www.pixiv.net/ajax/illust/${link.id}/pages',
      headers,
      timeout,
    );
    final list = pages['body'];
    final urls = <String>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map) {
          final inner = item['urls'];
          if (inner is Map) {
            final url = _secure((inner['original'] ?? '').toString());
            if (url.isNotEmpty) urls.add(url);
          }
        }
      }
    }
    if (urls.isEmpty) {
      final single = info['urls'];
      if (single is Map) {
        final url = _secure((single['original'] ?? '').toString());
        if (url.isNotEmpty) urls.add(url);
      }
    }
    if (urls.isEmpty) throw const VideoParseException('Pixiv 没有取到原图地址');

    final title = (info['title'] ?? '').toString();
    final base = _fileNameBase(title, 'pixiv_${link.id}');
    const referer = 'https://www.pixiv.net/';
    final media = <VideoMediaItem>[
      for (var i = 0; i < urls.length; i++)
        VideoMediaItem(
          url: urls[i],
          kind: VideoMediaKind.image,
          fileName: '${base}_${i + 1}${_extOf(urls[i], '.jpg')}',
          referer: referer,
          userAgent: uaChrome,
        ),
    ];
    return VideoParseResult(
      platform: 'Pixiv',
      title: title,
      author: (info['userName'] ?? '').toString(),
      coverUrl: urls.first,
      text: (info['description'] ?? '').toString(),
      timestampSeconds: _parseDate((info['createDate'] ?? '').toString()),
      media: media,
      note: 'Pixiv 原图 CDN 校验 Referer，已随直链保存；必须带 Cookie 才能下载。',
    );
  }

  // ------------------------------------------------------------ 小红书

  static Future<VideoParseResult> _xhs(
    http.Client client,
    DetectedVideoLink link,
    String cookie,
    Duration timeout,
  ) async {
    final headers = <String, String>{
      'User-Agent': uaChrome,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,'
              'image/webp,*/*;q=0.8',
      'Referer': 'https://www.xiaohongshu.com/',
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
    final response = await _raw(
      client,
      'https://www.xiaohongshu.com/explore/${link.id}',
      headers,
      timeout: timeout,
    );
    if (response.status == 403 || response.status == 461) {
      throw const VideoParseException('小红书风控拦截，请稍后重试或先登录');
    }
    _requireOk(response);
    final html = utf8.decode(response.body, allowMalformed: true);
    if (response.finalUrl.contains('/login') ||
        response.finalUrl.contains('website-login')) {
      throw const VideoParseException('小红书需要登录：请先在登录面板保存 Cookie 再解析');
    }
    final raw = _extractInlineJson(html, 'window.__INITIAL_STATE__');
    if (raw == null) {
      throw const VideoParseException('小红书页面里没有笔记数据，可能需要登录');
    }
    // 这段 JSON 里混了裸 undefined，必须先替换成 null 才能解析。
    final Map<String, dynamic> state;
    try {
      final decoded = jsonDecode(raw.replaceAll('undefined', 'null'));
      if (decoded is! Map) throw const FormatException('不是对象');
      state = decoded.cast<String, dynamic>();
    } catch (_) {
      throw const VideoParseException('小红书笔记数据解析失败');
    }
    final noteMap = state['note'];
    final detailMap = noteMap is Map ? noteMap['noteDetailMap'] : null;
    Map<String, dynamic>? note;
    if (detailMap is Map) {
      final node = detailMap[link.id] ?? (detailMap.isEmpty ? null : detailMap.values.first);
      if (node is Map && node['note'] is Map) {
        note = (node['note'] as Map).cast<String, dynamic>();
      }
    }
    if (note == null) {
      throw const VideoParseException('小红书没有找到笔记内容，可能需要登录');
    }

    final noteTitle = (note['title'] ?? note['desc'] ?? '').toString();
    final base = _fileNameBase(noteTitle, 'xhs_${link.id}');
    const referer = 'https://www.xiaohongshu.com/';
    final media = <VideoMediaItem>[];
    var degraded = false;
    final video = note['video'];
    if (video is Map) {
      final stream = (video['media'] is Map)
          ? ((video['media'] as Map)['stream'] as Map?)
          : null;
      String? videoLink;
      if (stream != null) {
        for (final key in const <String>['h265', 'h264', 'av1', 'h266']) {
          final list = stream[key];
          if (list is List && list.isNotEmpty && list.first is Map) {
            final url = _secure(
              ((list.first as Map)['masterUrl'] ??
                      (list.first as Map)['master_url'] ??
                      '')
                  .toString(),
            );
            if (url.isNotEmpty) {
              videoLink = url;
              break;
            }
          }
        }
      }
      if (videoLink != null) {
        media.add(
          VideoMediaItem(
            url: videoLink,
            kind: VideoMediaKind.video,
            fileName: '$base.mp4',
            referer: referer,
            userAgent: uaChrome,
          ),
        );
      }
    }

    final images = note['imageList'];
    if (images is List) {
      var index = 0;
      for (final item in images) {
        if (item is! Map) continue;
        final rawUrl = (item['urlDefault'] ?? item['url'] ?? '').toString();
        if (rawUrl.isEmpty) continue;
        final cleaned = _xhsCleanImage(rawUrl);
        final usable = cleaned != rawUrl && await _headOk(client, cleaned, timeout);
        if (cleaned != rawUrl && !usable) degraded = true;
        index++;
        final chosen = usable ? cleaned : rawUrl;
        media.add(
          VideoMediaItem(
            url: chosen,
            kind: VideoMediaKind.image,
            fileName: '${base}_$index${_extOf(chosen, '.jpg')}',
            referer: referer,
            userAgent: uaChrome,
          ),
        );
      }
    }
    if (media.isEmpty) throw const VideoParseException('小红书笔记里没有可下载的媒体');
    final user = note['user'] is Map
        ? (note['user'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final cover = media.firstWhere(
      (item) => item.kind == VideoMediaKind.image,
      orElse: () => media.first,
    );

    return VideoParseResult(
      platform: '小红书',
      title: noteTitle,
      author: (user['nickname'] ?? user['nickName'] ?? '').toString(),
      coverUrl: cover.url,
      text: (note['desc'] ?? '').toString(),
      timestampSeconds: ((note['time'] as num?)?.toInt() ?? 0) ~/ 1000,
      media: media,
      note: degraded ? '部分原图地址已失效，已回退到带水印版本。' : '',
    );
  }

  /// 小红书图片地址带网页处理规格，换算成无水印原图：
  /// `host/202501011200/0f5e/<图片ID>!<规格>` → `sns-img-bd.xhscdn.com/<图片ID>`。
  static String _xhsCleanImage(String raw) {
    var text = raw;
    final query = text.indexOf('?');
    if (query >= 0) text = text.substring(0, query);
    final scheme = text.indexOf('://');
    if (scheme < 0) return raw;
    final rest = text.substring(scheme + 3);
    final slash = rest.indexOf('/');
    if (slash < 0) return raw;
    final segments = rest.substring(slash + 1).split('/');
    if (segments.length <= 2) return raw;
    final id = segments.sublist(2).join('/').split('!').first;
    if (id.isEmpty) return raw;
    return 'https://sns-img-bd.xhscdn.com/$id';
  }

  static Future<bool> _headOk(
    http.Client client,
    String url,
    Duration timeout,
  ) async {
    try {
      final response = await _raw(
        client,
        url,
        <String, String>{'User-Agent': uaChrome},
        method: 'HEAD',
        timeout: timeout,
      );
      return response.status != 404 && response.status != 410;
    } catch (_) {
      return true;
    }
  }

  // ------------------------------------------------------------ 公共工具

  static Future<Map<String, dynamic>> _json(
    http.Client client,
    String url,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final response = await _raw(client, url, headers, timeout: timeout);
    _requireOk(response);
    try {
      final decoded = jsonDecode(utf8.decode(response.body, allowMalformed: true));
      if (decoded is! Map) throw const FormatException('不是对象');
      return decoded.cast<String, dynamic>();
    } catch (_) {
      throw const VideoParseException('接口返回了非 JSON 内容，可能被风控拦截');
    }
  }

  static void _requireOk(_Raw response) {
    final status = response.status;
    if (status >= 200 && status < 300) return;
    if (status == 403 || status == 418 || status == 429) {
      throw const VideoParseException('被平台风控拦截，请稍后重试');
    }
    if (status == 404 || status == 410) {
      throw const VideoParseException('内容不存在或已删除');
    }
    throw VideoParseException('请求失败：HTTP $status');
  }

  static Future<_Raw> _raw(
    http.Client client,
    String url,
    Map<String, String> headers, {
    String method = 'GET',
    String? body,
    bool follow = true,
    Duration? timeout,
  }) async {
    final request = http.Request(method, Uri.parse(url));
    request.headers.addAll(headers);
    request.followRedirects = follow;
    if (body != null) request.body = body;
    final streamed = await client
        .send(request)
        .timeout(timeout ?? const Duration(seconds: 20));
    final response = await http.Response.fromStream(streamed);
    return _Raw(
      status: response.statusCode,
      body: response.bodyBytes,
      headers: response.headers,
      finalUrl: response.request?.url.toString() ?? url,
    );
  }

  /// 短链展开：手工跟 302，拿到真正带作品 id 的地址。
  ///
  /// 两个细节缺一不可：
  /// 1. **抖音 / 快手的短链只认移动端 UA**：拿桌面 UA 去请求会被引到桌面 SPA 页，
  ///    既没有 `Location` 也没有可用的 SSR —— 这也是之前「v.douyin.com 取不到 id」的根因。
  /// 2. **自己读 `Location` 而不是靠最终地址**：抖音短链第一跳就是
  ///    `https://www.iesdouyin.com/share/video/<id>/`，后面即使落到风控挑战页，
  ///    作品 id 也已经拿到了。
  static Future<String?> _resolveShort(
    http.Client client,
    String url,
    String platform,
    Duration timeout,
  ) async {
    final headers = <String, String>{
      'User-Agent': switch (platform) {
        '抖音' || '快手' => uaIPhone,
        _ => uaChrome,
      },
    };
    var current = url;
    for (var hop = 0; hop < 5; hop++) {
      final _Raw response;
      try {
        response = await _raw(
          client,
          current,
          headers,
          follow: false,
          timeout: timeout,
        );
      } catch (_) {
        return hop == 0 ? null : current;
      }
      final location = _headerOf(response.headers, 'location');
      if (location == null || location.isEmpty) {
        // 没有下一跳：当前地址就是终点。首跳就没跳转说明短链没解开。
        return hop == 0 ? null : current;
      }
      current = Uri.parse(current).resolve(location).toString();
      final next = detect(current);
      if (next != null && !next.isShort && next.id.isNotEmpty) return current;
    }
    return current;
  }

  /// 响应头按小写取（package:http 会把名字规范化成小写）。
  static String? _headerOf(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  /// 从页面里抠出 `window.XXX = {...}</script>` 之间的 JSON 文本。
  static String? _extractInlineJson(String html, String key) {
    final pattern = RegExp(
      '${RegExp.escape(key)}\\s*=\\s*(.*?)</script>',
      multiLine: true,
      dotAll: true,
    );
    final match = pattern.firstMatch(html);
    final text = match?.group(1)?.trim();
    if (text == null || text.isEmpty) return null;
    return text;
  }

  static String _unescapeQuotes(String text) =>
      text.replaceAll('\\"', '"').replaceAll('\\\\/', '/');

  /// `//x` 与 `http://x` 统一成 https，避免明文地址被系统网络策略拦。
  static String _secure(String url) {
    final text = url.trim();
    if (text.isEmpty) return '';
    if (text.startsWith('//')) return 'https:$text';
    if (text.startsWith('http://')) return 'https://${text.substring(7)}';
    return text;
  }

  static String? _firstUrl(Object? list) {
    if (list is! List) return null;
    for (final item in list) {
      if (item is Map) {
        final url = _secure((item['url'] ?? '').toString());
        if (url.isNotEmpty) return url;
      }
    }
    return null;
  }

  /// 从直链路径猜扩展名，猜不到用兜底值。
  static String _extOf(String url, String fallback) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in const <String>[
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.mp4',
      '.mov',
    ]) {
      if (path.endsWith(ext)) return ext;
    }
    return fallback;
  }

  static String _fileNameBase(String title, String fallback) {    final cleaned = title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    final trimmed = cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned;
    return trimmed.isEmpty ? fallback : trimmed;
  }

  static int _parseDate(String value) {
    final text = value.trim();
    if (text.isEmpty) return 0;
    if (RegExp(r'^\d+$').hasMatch(text)) {
      final number = int.tryParse(text) ?? 0;
      return number > 1000000000000 ? number ~/ 1000 : number;
    }
    final parsed = DateTime.tryParse(text);
    return parsed == null ? 0 : parsed.millisecondsSinceEpoch ~/ 1000;
  }
}

class _Raw {
  const _Raw({
    required this.status,
    required this.body,
    required this.headers,
    required this.finalUrl,
  });

  final int status;
  final List<int> body;
  final Map<String, String> headers;
  final String finalUrl;
}
