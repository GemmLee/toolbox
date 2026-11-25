import 'dart:convert';

import 'package:http/http.dart' as http;

import 'baidu_resolver.dart';
import 'c139_resolver.dart';
import 'douyin_webview.dart';
import 'guangya_resolver.dart';
import 'ilanzou_resolver.dart';
import 'lanzou_resolver.dart';
import 'pan115_resolver.dart';
import 'pan123_resolver.dart';
import 'quark_uc_resolver.dart';
import 'share_link.dart';
import 'share_models.dart';
import 'video_parser.dart';
import 'xunlei_auth.dart';
import 'xunlei_resolver.dart';

/// 解析出来的媒体类型。
enum MediaKind {
  image('图片'),
  video('视频'),
  audio('音频'),
  file('文件');

  const MediaKind(this.label);

  final String label;
}

/// 一条可下载的媒体直链。
class MediaItem {
  const MediaItem({
    required this.url,
    required this.kind,
    this.filename = '',
    this.referer = '',
    this.userAgent = '',
  });

  final String url;
  final MediaKind kind;

  /// 视频平台给出的文件名与防盗链头：B站/Pixiv 缺 Referer 会直接 403。
  final String filename;
  final String referer;
  final String userAgent;
}

/// 链接解析结果。
class LinkParseResult {
  const LinkParseResult({
    required this.url,
    required this.platform,
    this.title = '',
    this.coverUrl,
    this.media = const <MediaItem>[],
    this.note = '',
    this.endpoint = '',
    this.error,
    this.files = const <ShareFile>[],
    this.session,
    this.resolver,
    this.canBrowse = false,
  });

  final String url;
  final String platform;
  final String title;
  final String? coverUrl;
  final List<MediaItem> media;

  /// 网盘分享解析出来的文件列表（目录可直接继续打开）。
  final List<ShareFile> files;

  /// 网盘会话与适配器：后续浏览目录 / 取直链时复用，不重复打 token 接口。
  final ShareSession? session;
  final ShareResolver? resolver;

  /// 是否支持继续浏览目录与取直链。
  final bool canBrowse;

  /// 给用户看的补充说明（例如「该平台需要登录，暂只拿到封面」）。
  final String note;

  /// 实际取到内容的地址：失败切换备用域名后能看出走的哪条线。
  final String endpoint;

  final String? error;

  bool get success => error == null;
}

/// 链接解析：把分享文本里的链接抠出来，按平台分别取标题 / 封面 / 直链。
///
/// 网盘走各平台的分享协议（需要登录的用本机保存的凭证）；视频平台里
/// B站 / AcFun / 快手 / 微博 / Pixiv / 小红书走接口或页面内联 SSR，
/// 抖音走原生隐藏 WebView（它的数据被 JS 挑战挡在纯 HTTP 之外）。
/// 拿不到直链时会在 [LinkParseResult.note] 里说清原因，而不是给一个下不了的假链接。
///
/// 失败切换：同一批候选域名按历史失败次数排序，超时 / 空响应会自动换下一个；
/// 具体网盘的协议适配器由调用方通过 [endpointBuilder] 注入，本类不内置逆向逻辑。
class LinkParser {
  LinkParser({
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
    this.headers = const <String, String>{},
    this.endpointBuilder,
  }) : _client = client;

  final http.Client? _client;
  http.Client? _shareClient;
  String _cookie = '';

  /// 协议适配器共用的客户端：会话期间不关，dispose 时统一释放。
  http.Client get shareClient => _shareClient ??= _client ?? http.Client();

  /// 页面销毁时调用；注入了 client 的测试实例由测试自己管理。
  void dispose() {
    if (_client == null) _shareClient?.close();
    _shareClient = null;
  }

  final Duration timeout;

  /// 登录后的 Cookie 等请求头，由页面从 [LinkCredentialStore] 取来传入。
  final Map<String, String> headers;

  /// 候选域名 / 接口；返回空列表时只用原始链接。
  final List<String> Function(String url)? endpointBuilder;

  /// 进程内失败计数：连续超时 / 空响应的域名自动降权，相当于轻量的 CDN 切换。
  static final Map<String, int> _failures = <String, int>{};

  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 从一段分享文本里提取第一个 http(s) 链接。
  static String? extractUrl(String input) {
    final match = RegExp(r'https?://[^\s，。；、）)】」]+').firstMatch(input);
    if (match == null) return null;
    var url = match.group(0)!;
    while (url.isNotEmpty && '.,;:!?'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    return url.isEmpty ? null : url;
  }

  /// 平台识别（用于展示与选择解析策略）。
  static String platformOf(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.contains('bilibili.com') || host == 'b23.tv') return '哔哩哔哩';
    if (host.contains('douyin.com') || host.contains('iesdouyin.com')) {
      return '抖音';
    }
    if (host.contains('xiaohongshu.com') || host.contains('xhslink.com')) {
      return '小红书';
    }
    if (host.contains('pan.quark.cn')) return '夸克网盘';
    if (host.contains('drive.uc.cn')) return 'UC 网盘';
    if (host.contains('pan.baidu.com')) return '百度网盘';
    if (host.contains('yun.139.com') || host.contains('139.com')) {
      return '139 云盘';
    }
    if (host.contains('xunlei.com')) return '迅雷网盘';
    if (host.contains('123pan.com') ||
        host.contains('123pan.cn') ||
        host.contains('123865.com')) {
      return '123 云盘';
    }
    if (host.contains('115.com')) return '115 网盘';
    if (host.contains('guangyapan.com')) return '光鸭云盘';
    if (host.contains('ilanzou.')) return '蓝奏优享';
    if (RegExp(r'lanzou|lan[zs]o[ux]|lanzn').hasMatch(host)) return '蓝奏云';
    if (host.contains('kuaishou.com') || host.contains('chenzhongtech.com')) {
      return '快手';
    }
    if (host.contains('weibo.com') || host.contains('weibo.cn')) return '微博';
    if (host.contains('acfun.cn')) return 'AcFun';
    if (host.contains('pixiv.net')) return 'Pixiv';
    return '直链 / 其他';
  }

  /// 解析链接。[headers] 可以带上登录后的 Cookie；只在同主域的候选地址上发送。
  ///
  /// [pwd] 是用户在界面上手填的提取码：非空时覆盖分享文案里自动识别出来的那个。
  /// [credentialStorage] 是本机保存的平台凭证（迅雷的 access_token 就在这里）。
  Future<LinkParseResult> parse(
    String input, {
    Map<String, String>? headers,
    String pwd = '',
    Map<String, String> credentialStorage = const <String, String>{},
    DouyinWebViewBridge? douyinBridge,
  }) async {
    final requestHeaders = <String, String>{
      ...this.headers,
      ...?headers,
    };
    _cookie = requestHeaders.entries
        .firstWhere(
          (e) => e.key.toLowerCase() == 'cookie',
          orElse: () => const MapEntry<String, String>('', ''),
        )
        .value;
    final netShare = ShareLinkParser.parse(input);
    if (netShare != null) {
      return _parseNetShare(
        pwd.trim().isEmpty
            ? netShare
            : ParsedShare(
                shareId: netShare.shareId,
                platform: netShare.platform,
                pwd: pwd.trim(),
              ),
        requestHeaders,
        credentialStorage,
      );
    }
    final url = extractUrl(input);
    if (url == null) {
      return const LinkParseResult(
        url: '',
        platform: '',
        error: '没有找到链接，粘贴完整分享文本或 http(s) 地址',
      );
    }
    final platform = platformOf(url);
    final direct = _directMedia(url);
    if (direct != null) {
      return LinkParseResult(
        url: url,
        platform: platform,
        title: Uri.parse(url).pathSegments.isEmpty
            ? url
            : Uri.parse(url).pathSegments.last,
        media: <MediaItem>[direct],
      );
    }
    final client = _client ?? http.Client();
    var videoFailure = '';
    // 视频平台走各站接口：B站/AcFun/快手/微博/Pixiv/小红书，抖音走原生 WebView。
    // 失败时退回 og 抓取，至少把标题和封面给出来。
    if (VideoParser.detect(url) != null) {
      try {
        final parsed = await VideoParser.parse(
          url,
          cookie: _cookie,
          client: shareClient,
          timeout: timeout,
          douyinBridge: douyinBridge,
        );
        return LinkParseResult(
          url: url,
          platform: parsed.platform,
          title: parsed.title,
          coverUrl: parsed.coverUrl,
          media: <MediaItem>[
            for (final item in parsed.media)
              MediaItem(
                url: item.url,
                kind: _videoKindOf(item.kind),
                filename: item.fileName,
                referer: item.referer,
                userAgent: item.userAgent,
              ),
          ],
          note: parsed.note,
          endpoint: url,
        );
      } on VideoParseException catch (e) {
        videoFailure = e.message;
      }
    }
    try {
      final fetched = await _fetch(client, url, requestHeaders);
      final response = fetched.response;
      final html = _decode(response);
      final title = _meta(html, 'og:title') ??
          _tag(html, 'title') ??
          (platform == '直链 / 其他' ? url : '');
      final cover = _meta(html, 'og:image') ?? _meta(html, 'twitter:image');
      final media = <MediaItem>[];
      final headVideo = _meta(html, 'og:video') ??
          _meta(html, 'og:video:url') ??
          _meta(html, 'og:video:secure_url');
      if (headVideo != null && headVideo.isNotEmpty) {
        media.add(
            MediaItem(url: _absolute(headVideo, url), kind: MediaKind.video));
      }
      // 分享页常常把 mp4 直链放在内联脚本里，抓一个最常见的即可。
      final inline = RegExp(r'https?://[^"\\\s]+?\.mp4[^"\\\s]*')
          .firstMatch(html)
          ?.group(0);
      if (inline != null && media.every((item) => item.url != inline)) {
        media.add(MediaItem(url: inline, kind: MediaKind.video));
      }
      if (cover != null && cover.isNotEmpty) {
        media.add(
          MediaItem(url: _absolute(cover, url), kind: MediaKind.image),
        );
      }
      final note = videoFailure.isNotEmpty
          ? '$videoFailure；已退回页面标题与封面抓取。'
          : _noteFor(platform, media);
      return LinkParseResult(
        url: url,
        platform: platform,
        title: _unescape(title.trim()),
        coverUrl: cover == null ? null : _absolute(cover, url),
        media: media,
        note: note,
        endpoint: fetched.url,
      );
    } catch (e) {
      return LinkParseResult(
        url: url,
        platform: platform,
        error: '解析失败：$e',
      );
    } finally {
      if (_client == null) client.close();
    }
  }

  /// 网盘分享走服务端协议：token → 文件列表，结果里带上会话供后续浏览/取链。
  Future<LinkParseResult> _parseNetShare(
    ParsedShare share,
    Map<String, String> headers,
    Map<String, String> credentialStorage,
  ) async {
    final label = share.platform.label;
    final url = _netShareUrl(share);
    final ShareResolver resolver;
    switch (share.platform) {
      case SharePlatform.quark:
        resolver = QuarkResolver();
      case SharePlatform.uc:
        resolver = UcResolver();
      case SharePlatform.baidu:
        resolver = BaiduResolver();
      case SharePlatform.c139:
        resolver = C139Resolver();
      case SharePlatform.pan123:
        resolver = Pan123Resolver();
      case SharePlatform.pan115:
        resolver = Pan115Resolver();
      case SharePlatform.xunlei:
        resolver = XunleiResolver(
          account: XunleiAccount.fromStorage(credentialStorage),
        );
      case SharePlatform.guangya:
        resolver = GuangYaResolver();
      case SharePlatform.lanzou:
        resolver = LanzouResolver();
      case SharePlatform.ilanzou:
        resolver = ILanzouResolver();
      default:
        return LinkParseResult(
          url: url,
          platform: label,
          title: share.shareId,
          note: '已识别为 $label 分享，当前版本暂不做该平台的协议直链解析，请用官方客户端打开。',
        );
    }
    try {
      final session = await resolver.createSession(
        share,
        cookie: _cookie,
        client: shareClient,
        timeout: timeout,
      );
      final root = switch (share.platform) {
        SharePlatform.baidu => '/',
        SharePlatform.c139 => 'root',
        _ => '0',
      };
      final files = await resolver.listFiles(
        session,
        dirFid: root,
        cookie: _cookie,
        client: shareClient,
        timeout: timeout,
      );
      return LinkParseResult(
        url: url,
        platform: label,
        title: session.title.isNotEmpty ? session.title : share.shareId,
        files: files,
        session: session,
        resolver: resolver,
        canBrowse: true,
        note: files.isEmpty ? '这个分享里没有文件，或提取码不正确。' : '',
      );
    } catch (e) {
      final hint = resolver.requiresLogin && _cookie.isEmpty
          ? '；可先在下方打开官方登录页保存本机凭证'
          : '';
      return LinkParseResult(
        url: url,
        platform: label,
        title: share.shareId,
        error: '解析失败：$e$hint',
      );
    }
  }

  String _netShareUrl(ParsedShare share) => switch (share.platform) {
        SharePlatform.quark => 'https://pan.quark.cn/s/${share.shareId}',
        SharePlatform.uc => 'https://drive.uc.cn/s/${share.shareId}',
        SharePlatform.baidu => 'https://pan.baidu.com/s/1${share.shareId}',
        SharePlatform.c139 =>
          'https://yun.139.com/shareweb/#/w/i/${share.shareId}',
        _ => '',
      };

  /// 打开网盘分享里的子目录。
  Future<LinkParseResult> openDirectory(
    LinkParseResult result,
    ShareFile directory,
  ) async {
    final session = result.session;
    final resolver = result.resolver;
    if (session == null || resolver == null) return result;
    try {
      final files = await resolver.listFiles(
        session,
        dirFid: directory.fid,
        cookie: _cookie,
        client: shareClient,
        timeout: timeout,
      );
      return LinkParseResult(
        url: result.url,
        platform: result.platform,
        title: directory.name,
        files: files,
        session: session,
        resolver: resolver,
        canBrowse: true,
        note: files.isEmpty ? '这个目录是空的' : '',
      );
    } catch (e) {
      return LinkParseResult(
        url: result.url,
        platform: result.platform,
        title: directory.name,
        error: '打开目录失败：$e',
        session: session,
        resolver: resolver,
        canBrowse: true,
      );
    }
  }

  /// 把网盘文件换成可直接下载的临时直链。
  Future<DownloadLink> resolveDownload(
    LinkParseResult result,
    ShareFile file,
  ) async {
    final session = result.session;
    final resolver = result.resolver;
    if (session == null || resolver == null) {
      throw const ShareResolveException('会话已失效，请重新解析链接');
    }
    return resolver.downloadLink(
      session,
      file,
      cookie: _cookie,
      client: shareClient,
      timeout: timeout,
    );
  }

  Future<void> cleanup(
    LinkParseResult result,
    DownloadLink link,
  ) =>
      result.resolver?.cleanup(
        link,
        cookie: _cookie,
        client: shareClient,
        timeout: timeout,
      ) ??
      Future<void>.value();

  /// 依次尝试候选地址，超时 / 空响应 / 4xx 都换下一个；
  /// 失败过的主机在进程内降权，下一轮解析会优先走正常的那个。
  Future<_Fetched> _fetch(
    http.Client client,
    String url,
    Map<String, String> headers,
  ) async {
    final extra = endpointBuilder?.call(url) ?? const <String>[];
    final candidates = <String>[
      url,
      for (final item in extra)
        if (item != url) item,
    ];
    final indexed = candidates.asMap().entries.toList()
      ..sort((a, b) {
        final left = _failures[Uri.tryParse(a.value)?.host] ?? 0;
        final right = _failures[Uri.tryParse(b.value)?.host] ?? 0;
        return left != right ? left.compareTo(right) : a.key.compareTo(b.key);
      });

    Object? lastError;
    for (final entry in indexed) {
      final candidate = entry.value;
      final host = Uri.tryParse(candidate)?.host ?? candidate;
      try {
        final response = await client.get(
          Uri.parse(candidate),
          headers: <String, String>{
            'User-Agent': _ua,
            'Accept': 'text/html,application/xhtml+xml',
            ..._safeHeaders(candidate, url, headers),
          },
        ).timeout(timeout);
        if (response.statusCode >= 400) {
          _failures[host] = (_failures[host] ?? 0) + 1;
          lastError = StateError('HTTP ${response.statusCode}');
          continue;
        }
        if (response.bodyBytes.isEmpty) {
          _failures[host] = (_failures[host] ?? 0) + 1;
          lastError = StateError('页面为空');
          continue;
        }
        _failures[host] = 0;
        return _Fetched(response, candidate);
      } catch (e) {
        _failures[host] = (_failures[host] ?? 0) + 1;
        lastError = e;
      }
    }
    throw lastError ?? StateError('没有可用的解析地址');
  }

  /// Cookie 绝不能发给别的域名：备用地址只有主域相同才带凭证。
  static Map<String, String> _safeHeaders(
    String candidate,
    String original,
    Map<String, String> headers,
  ) {
    final a = Uri.tryParse(candidate)?.host.split('.') ?? const <String>[];
    final b = Uri.tryParse(original)?.host.split('.') ?? const <String>[];
    String domain(List<String> parts) => parts.length >= 2
        ? parts.sublist(parts.length - 2).join('.')
        : parts.join('.');
    if (a.isEmpty || b.isEmpty || domain(a) != domain(b)) {
      return <String, String>{
        for (final entry in headers.entries)
          if (entry.key.toLowerCase() != 'cookie') entry.key: entry.value,
      };
    }
    return headers;
  }

  static MediaKind _videoKindOf(VideoMediaKind kind) => switch (kind) {
        VideoMediaKind.video => MediaKind.video,
        VideoMediaKind.image => MediaKind.image,
        VideoMediaKind.audio => MediaKind.audio,
      };

  /// 平台能力说明：把「做不到」讲清楚，避免用户反复试。
  static String _noteFor(String platform, List<MediaItem> media) {
    if (platform == '哔哩哔哩') {
      return '这个地址不是标准视频页（BV / av 号），只取到标题与封面。';
    }
    if (platform == '抖音') {
      return media.isEmpty
          ? '抖音作品数据被页面风控挡住，这次没取到直链；标题与封面仍可下载。换网络重试通常就好。'
          : '已解析到无水印直链；如果下载 403，是直链短时过期，回到这里重新解析即可。';
    }
    if (platform == '小红书') {
      return media.isEmpty
          ? '该平台视频地址带签名，解析不到直链；封面与标题可正常下载。'
          : '封面与公开直链已解析，带签名的视频流可能无法下载。';
    }
    if (platform == '夸克网盘' ||
        platform == 'UC 网盘' ||
        platform == '百度网盘' ||
        platform == '139 云盘' ||
        platform == '迅雷网盘') {
      return media.isEmpty
          ? '网盘文件需要服务端鉴权；先点「网盘登录」复用官方页登录，再解析分享页。'
          : '已解析到公开链接；网盘生成的临时直链可能很快过期，下载失败请用官方客户端。';
    }
    return '';
  }

  static MediaItem? _directMedia(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (RegExp(r'\.(jpe?g|png|gif|webp|bmp|heic)$').hasMatch(path)) {
      return MediaItem(url: url, kind: MediaKind.image);
    }
    if (RegExp(r'\.(mp4|mov|m4v|webm|mkv)$').hasMatch(path)) {
      return MediaItem(url: url, kind: MediaKind.video);
    }
    if (RegExp(r'\.(mp3|m4a|aac|wav|flac|ogg)$').hasMatch(path)) {
      return MediaItem(url: url, kind: MediaKind.audio);
    }
    if (RegExp(r'\.(pdf|txt|md|json|zip|apk)$').hasMatch(path)) {
      return MediaItem(url: url, kind: MediaKind.file);
    }
    return null;
  }

  static String _decode(http.Response response) {
    final type = response.headers['content-type'] ?? '';
    if (type.contains('charset=gb')) {
      return latin1.decode(response.bodyBytes);
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  /// 取 `<meta property="og:title" content="...">` 之类的值。
  static String? _meta(String html, String property) {
    final patterns = <RegExp>[
      RegExp(
        '<meta[^>]+(?:property|name)=["\']${RegExp.escape(property)}["\'][^>]*'
        'content=["\']([^"\']*)["\']',
        caseSensitive: false,
      ),
      RegExp(
        '<meta[^>]+content=["\']([^"\']*)["\'][^>]*'
        '(?:property|name)=["\']${RegExp.escape(property)}["\']',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match != null) return match.group(1);
    }
    return null;
  }

  static String? _tag(String html, String tag) {
    final match = RegExp('<$tag[^>]*>([\\s\\S]*?)</$tag>', caseSensitive: false)
        .firstMatch(html);
    return match?.group(1);
  }

  static String _absolute(String url, String base) {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return url;
    if (parsed.hasScheme) return url;
    final origin = Uri.parse(base);
    return origin.resolveUri(parsed).toString();
  }

  static String _unescape(String text) => text
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');
}

/// 一次成功抓取：连同最终使用的地址一起返回，便于界面显示走了哪条线。
class _Fetched {
  const _Fetched(this.response, this.url);

  final http.Response response;
  final String url;
}
