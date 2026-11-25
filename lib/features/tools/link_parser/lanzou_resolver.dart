import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'share_link.dart';
import 'share_models.dart';

/// 蓝奏云：解析分享页 HTML/JS 变量 → 文件夹分页（filemoreajax）/ 单文件 →
/// 下载参数（ajaxm/ajaxfile）→ HEAD 探测直链。全程匿名，无需登录。
///
/// 蓝奏对裸 HTTP 客户端会先下发 acw_sc__v2 校验页，这里按 YunX `LanzouApi`
/// 的算法本地算出 Cookie 重放；下载节点还要注入 down_ip=1。
class LanzouResolver implements ShareResolver {
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  @override
  SharePlatform get platform => SharePlatform.lanzou;

  @override
  bool get requiresLogin => false;

  @override
  Future<void> cleanup(
    DownloadLink link, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {}

  /// host → cookie 键值（acw_sc__v2 / down_ip）。
  final Map<String, Map<String, String>> _cookies =
      <String, Map<String, String>>{};

  String _cookieHeader(String host) {
    final jar = _cookies[host];
    if (jar == null || jar.isEmpty) return '';
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void _setCookie(String host, String name, String value) =>
      (_cookies[host] ??= <String, String>{})[name] = value;

  @override
  Future<ShareSession> createSession(
    ParsedShare share, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final url = _shareUrl(share.shareId);
    final page = await _fetchPage(url, timeout);
    // session.token 带分享提取码，列目录/取链时复用。
    return ShareSession(
      platform: platform,
      shareId: url,
      token: share.pwd ?? '',
      title: _title(page.html),
      extra: <String, dynamic>{
        'html': page.html,
        'baseUrl': page.baseUrl,
        'isFolder': _isFolder(page.html),
        'needsPwd': _needsPwd(page.html),
        'shareId': url,
      },
    );
  }

  static String _shareUrl(String id) => 'https://www.lanzoui.com/$id';

  @override
  Future<List<ShareFile>> listFiles(
    ShareSession session, {
    required String dirFid,
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final html = strOf(session.extra, 'html');
    final baseUrl = strOf(session.extra, 'baseUrl');
    final isFolder = boolOf(session.extra, 'isFolder');
    if (!isFolder) {
      final displaySize = _displaySize(RegExp(
              r'(?:文件大小|大小)\s*[:：]\s*([\d.]+)\s*([KMGT]?)(?:i?B)?',
              caseSensitive: false)
          .firstMatch(html));
      return <ShareFile>[
        ShareFile(
          fid: strOf(session.extra, 'shareId'),
          name: session.title,
          size: displaySize,
          isDir: false,
          pdirFid: '',
        ),
      ];
    }
    final lx = _jsVar(html, 'lx');
    final fid = _jsVar(html, 'fid') ?? _lastPath(session.shareId);
    final t = _jsVar(html, 't');
    final k = _jsVar(html, 'k');
    if (lx == null || t == null || k == null) {
      throw const ShareResolveException('分享页缺少分页参数，可能已失效');
    }
    final all = <ShareFile>[];
    final seen = <String>{};
    var page = 1;
    while (page <= 500) {
      final fields = <String, String>{
        'lx': lx,
        'fid': fid,
        't': t,
        'k': k,
        'pwd': session.token,
        'pg': '$page',
      };
      final json = await _formPost(
        '$baseUrl/filemoreajax.php',
        fields,
        referer: session.shareId,
        origin: baseUrl,
        timeout: timeout,
      );
      final zt = intOf(json, 'zt');
      if (zt == 4) throw const ShareResolveException('请求太频繁，稍后再试');
      if (zt == 2) break;
      if (zt == 3) throw const ShareResolveException('提取码错误');
      if (zt != 1) throw const ShareResolveException('解析失败');
      final list = listOf(json, 'text');
      if (list.isEmpty) break;
      var added = 0;
      for (final item in list) {
        final reference = strOf(item, 'id');
        if (reference.isEmpty) continue;
        final id = reference.split('?').first;
        if (id.isEmpty || !seen.add(id)) continue;
        all.add(ShareFile(
          fid: id,
          name: strOf(item, 'name_all').isEmpty
              ? strOf(item, 'name')
              : strOf(item, 'name_all'),
          size: _displaySize(RegExp(r'([\d.]+)\s*([KMGT]?)', caseSensitive: false)
              .firstMatch(strOf(item, 'size'))),
          isDir: false,
          pdirFid: '',
          fidToken: reference.contains('?') ? '$baseUrl/$reference' : '',
          modifiedAt: strOf(item, 'time'),
        ));
        added++;
      }
      if (added == 0) break;
      page++;
    }
    return all;
  }

  @override
  Future<DownloadLink> downloadLink(
    ShareSession session,
    ShareFile file, {
    required String cookie,
    required http.Client client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final baseUrl = strOf(session.extra, 'baseUrl');
    var html = strOf(session.extra, 'html');
    var referer = session.shareId;
    final memberUrl = file.fidToken;
    if (memberUrl.isNotEmpty) {
      referer = memberUrl;
      html = (await _fetchPage(memberUrl, timeout)).html;
    }
    // 同源 iframe 下载页
    final iframe = RegExp(r'''<iframe[^>]+src=["']([^"']+)["']''')
        .firstMatch(html)
        ?.group(1);
    if (iframe != null) {
      final absolute = _absolutize(baseUrl, iframe);
      if (Uri.tryParse(absolute)?.host == Uri.tryParse(referer)?.host) {
        html = (await _fetchPage(absolute, timeout, referer: referer)).html;
        referer = absolute;
      }
    }
    final fileId = _jsVar(html, 'file') ??
        RegExp(r'(?:ajaxm|ajaxfile)\.php\?file=(\d+)')
            .firstMatch(html)
            ?.group(1) ??
        RegExp(r'file=(\d+)').firstMatch(html)?.group(1);
    if (fileId == null || fileId.isEmpty) {
      throw const ShareResolveException('分享页里找不到下载参数');
    }
    final needsPwd = boolOf(session.extra, 'needsPwd') ||
        html.contains('function down_p(');
    final withPwd = needsPwd && session.token.isNotEmpty;
    if (needsPwd && session.token.isEmpty) {
      throw const ShareResolveException('该分享需要提取码');
    }
    final ajaxUrl = _ajaxUrl(html, baseUrl, fileId, withPwd);
    final sign = _dataValue(html, 'sign') ?? _jsVar(html, 'sign');
    if (sign == null || sign.isEmpty) {
      throw const ShareResolveException('缺少下载签名，可能页面结构已变化');
    }
    final fields = <String, String>{
      'action': 'downprocess',
      'sign': sign,
    };
    if (withPwd) {
      fields['p'] = session.token;
      fields['kd'] = '1';
    } else {
      final ajaxData = _jsVar(html, 'ajaxdata') ?? '';
      final key = _jsVar(html, 'websignkey') ?? '';
      if (key.isEmpty) {
        throw const ShareResolveException('缺少下载参数，可能页面结构已变化');
      }
      if (ajaxData.isNotEmpty) fields['signs'] = ajaxData;
      fields['websignkey'] = key;
      fields['websign'] = _jsVar(html, 'websign') ?? '';
      fields['kd'] = '1';
      fields['ves'] = '1';
    }
    final json = await _formPost(ajaxUrl, fields,
        referer: referer, origin: baseUrl, timeout: timeout);
    final inf = strOf(json, 'inf');
    if (intOf(json, 'zt') != 1) {
      throw ShareResolveException(inf.isEmpty ? '取下载直链失败' : inf);
    }
    final dom = strOf(json, 'dom');
    final rel = strOf(json, 'url');
    final domUri = Uri.tryParse(dom);
    if (rel.isEmpty || domUri == null) {
      throw const ShareResolveException('服务端返回的下载地址无效');
    }
    final jump = '${domUri.scheme}://${domUri.host}/file/$rel';
    final direct = await _probe(jump, baseUrl, timeout);
    return DownloadLink(
      url: direct,
      filename: file.name.isEmpty ? inf : file.name,
      size: file.size,
      referer: baseUrl,
      userAgent: _ua,
      cookie: _cookieHeader(Uri.parse(jump).host),
    );
  }

  /// 用 dart:io 关闭自动跟随，手动处理跳转、acw 校验、down_ip 注入。
  Future<_Page> _fetchPage(
    String url,
    Duration timeout, {
    String? referer,
  }) async {
    var current = url;
    final challenged = <String>{};
    for (var attempt = 0; attempt < 8; attempt++) {
      final uri = Uri.parse(current);
      final host = uri.host;
      final client = HttpClient()..connectionTimeout = timeout;
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers
        ..set('User-Agent', _ua)
        ..set('Referer', referer ?? current);
      final cookie = _cookieHeader(host);
      if (cookie.isNotEmpty) request.headers.set('Cookie', cookie);
      final response = await request.close().timeout(timeout);
      final code = response.statusCode;
      if (code >= 300 && code < 400) {
        final location = response.headers.value('location');
        response.drain<void>();
        client.close();
        if (location == null) {
          throw const ShareResolveException('分享链接跳转异常');
        }
        final next = _absolutize(current, location);
        final nextHost = Uri.tryParse(next)?.host ?? '';
        if (!_isLanzouHost(nextHost)) {
          throw const ShareResolveException('分享链接已失效');
        }
        current = next;
        continue;
      }
      final body = await utf8.decoder.bind(response).join();
      client.close();
      if (body.length > 2000000) {
        throw const ShareResolveException('分享页过大');
      }
      final challenge = _acwChallenge(body);
      if (challenge != null) {
        if (!challenged.add(host)) {
          throw const ShareResolveException('下载需要人机验证，请用官方客户端');
        }
        _setCookie(host, 'acw_sc__v2', challenge);
        continue;
      }
      if (body.contains('文件已取消') || body.contains('不存在')) {
        throw const ShareResolveException('分享已取消或不存在');
      }
      if (body.contains('请求过于频繁') || body.contains('稍后再试')) {
        throw const ShareResolveException('请求太频繁，稍后再试');
      }
      final origin = '${uri.scheme}://${uri.host}';
      return _Page(current, origin, body);
    }
    throw const ShareResolveException('分享链接跳转过多');
  }

  Future<Map<String, dynamic>> _formPost(
    String url,
    Map<String, String> fields, {
    required String referer,
    required String origin,
    required Duration timeout,
  }) async {
    final uri = Uri.parse(url);
    final host = uri.host;
    final client = HttpClient()..connectionTimeout = timeout;
    final request = await client.postUrl(uri).timeout(timeout);
    request.headers
      ..set('User-Agent', _ua)
      ..set('Referer', referer)
      ..set('Origin', origin)
      ..set('Content-Type', 'application/x-www-form-urlencoded');
    final cookie = _cookieHeader(host);
    if (cookie.isNotEmpty) request.headers.set('Cookie', cookie);
    request.write(fields.entries
        .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&'));
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join();
    client.close();
    try {
      return (jsonDecode(body) as Map).cast<String, dynamic>();
    } catch (_) {
      throw const ShareResolveException('下载服务返回异常，稍后再试');
    }
  }

  /// HEAD 探测直链：跟随若干跳，注入 down_ip=1，遇到 acw 校验本地计算重放。
  Future<String> _probe(String url, String shareOrigin, Duration timeout) async {
    var current = url;
    final visited = <String>{};
    for (var i = 0; i < 8; i++) {
      final uri = Uri.parse(current);
      if (!visited.add(current)) {
        throw const ShareResolveException('下载地址循环跳转');
      }
      _setCookie(uri.host, 'down_ip', '1');
      final client = HttpClient()..connectionTimeout = timeout;
      final request = await client.headUrl(uri).timeout(timeout);
      request.headers
        ..set('User-Agent', _ua)
        ..set('Referer', shareOrigin);
      final cookie = _cookieHeader(uri.host);
      if (cookie.isNotEmpty) request.headers.set('Cookie', cookie);
      final response = await request.close().timeout(timeout);
      final code = response.statusCode;
      final location = response.headers.value('location');
      final type = response.headers.value('content-type') ?? '';
      response.drain<void>();
      client.close();
      if (code >= 300 && code < 400 && location != null) {
        current = _absolutize(current, location);
        continue;
      }
      if (type.contains('text/html')) {
        final page = await _fetchPage(current, timeout, referer: shareOrigin);
        final arg1 = RegExp(r"""\barg1\s*=\s*'([0-9A-Fa-f]{40})'""")
            .firstMatch(page.html)
            ?.group(1);
        if (arg1 != null) {
          _setCookie(uri.host, 'acw_sc__v2', _acwScV2(arg1));
          visited.remove(current);
          continue;
        }
        throw const ShareResolveException('下载需要验证，请用官方客户端');
      }
      return current;
    }
    throw const ShareResolveException('下载地址探测失败');
  }

  // ---------- HTML / JS 解析工具 ----------

  static String _title(String html) {
    final title = RegExp(r'<title>([^<]*)</title>')
        .firstMatch(html)
        ?.group(1)
        ?.replaceAll(' - 蓝奏云', '')
        .replaceAll('蓝奏云', '')
        .trim();
    if (title != null && title.isNotEmpty && !title.contains('密码')) return title;
    final n = RegExp(r'''class=["']n["']>([^<]+)<''').firstMatch(html)?.group(1);
    if (n != null) return n.trim();
    return _jsVar(html, 'filename') ?? '';
  }

  static bool _needsPwd(String html) =>
      html.contains('请输入密码') ||
      html.contains('id="pwbox"') ||
      html.contains('input_password') ||
      html.contains('密码不正确') ||
      html.contains('function down_p(');

  static bool _isFolder(String html) =>
      html.contains('filemoreajax') ||
      html.contains('class="filemore"') ||
      html.contains('file_more');

  static String? _jsVar(String html, String name) => RegExp(
          '''(?:(?:var|let|const)\\s+)?$name\\s*=\\s*['"]([^'"]*)['"]''')
      .firstMatch(html)
      ?.group(1);

  static String? _dataValue(String html, String key) {
    final object = RegExp(r'''\bdata\s*:\s*\{([^{}]*)\}''', dotAll: true)
        .allMatches(html)
        .map((m) => m.group(1) ?? '')
        .toList();
    for (final source in object.reversed) {
      final match = RegExp(
              '''['"]?$key['"]?\\s*:\\s*(['"][^'"]*['"]|[A-Za-z_][\\w]*|\\d+)''')
          .firstMatch(source);
      if (match == null) continue;
      var raw = match.group(1)!;
      if ((raw.startsWith("'") && raw.endsWith("'")) ||
          (raw.startsWith('"') && raw.endsWith('"'))) {
        return raw.substring(1, raw.length - 1);
      }
      final variable = _jsVar(html, raw);
      if (variable != null) return variable;
    }
    return null;
  }

  static String _ajaxUrl(String html, String origin, String fileId, bool withPwd) {
    final fromScript = RegExp(
            r'''['"]?url['"]?\s*:\s*['"]((?:\./)?[^'"]*ajax(?:m|file)\.php\?file=\d+[^'"]*)['"]''')
        .firstMatch(html)
        ?.group(1);
    if (fromScript != null && fromScript.isNotEmpty) {
      return _absolutize(origin, fromScript);
    }
    final domain = _jsVar(html, 'domain1');
    if (domain != null && domain.contains('/ajax')) return domain;
    final absolute = RegExp(r"""https?://[^'"\s]+/(?:ajaxm|ajaxfile)\.php\?file=\d+""")
        .firstMatch(html)
        ?.group(0);
    if (absolute != null) return absolute;
    return withPwd
        ? '$origin/ajaxfile.php?file=$fileId'
        : '$origin/ajaxm.php?file=$fileId';
  }

  static String? _acwChallenge(String html) {
    final arg1 = RegExp(r"""\barg1\s*=\s*'([0-9A-Fa-f]{40})'""")
        .firstMatch(html)
        ?.group(1);
    return arg1 == null ? null : _acwScV2(arg1);
  }

  static String _acwScV2(String arg1) {
    const pos = <int>[
      15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6,
      11, 39, 18, 20, 8, 14, 21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12,
      36,
    ];
    const mask = '3000176000856006061501533003690027800375';
    final q = List<String>.filled(pos.length, '');
    for (var x = 0; x < arg1.length; x++) {
      for (var z = 0; z < pos.length; z++) {
        if (pos[z] == x + 1) q[z] = arg1[x];
      }
    }
    final u = q.join();
    final out = StringBuffer();
    var i = 0;
    while (i + 2 <= u.length && i + 2 <= mask.length) {
      final a = int.parse(u.substring(i, i + 2), radix: 16);
      final b = int.parse(mask.substring(i, i + 2), radix: 16);
      out.write((a ^ b).toRadixString(16).padLeft(2, '0'));
      i += 2;
    }
    return out.toString();
  }

  static String _absolutize(String base, String target) {
    if (target.startsWith('http://') || target.startsWith('https://')) {
      return target;
    }
    final uri = Uri.tryParse(base);
    if (uri == null) return target;
    final root = '${uri.scheme}://${uri.host}';
    if (target.startsWith('//')) return '${uri.scheme}:$target';
    if (target.startsWith('/')) return root + target;
    if (target.startsWith('?')) return root + uri.path + target;
    return Uri.parse('$root/').resolve(target).toString();
  }

  static bool _isLanzouHost(String host) => RegExp(
          r'^(?:[a-z0-9-]+\.)*(?:lanzou[a-z]?|lan[zs]o[ux]|lanzn)\.(?:com|net|org|cn)$',
          caseSensitive: false)
      .hasMatch(host);

  static String _lastPath(String url) {
    final uri = Uri.tryParse(url);
    final segments = uri?.pathSegments ?? const <String>[];
    return segments.isEmpty ? '' : segments.last;
  }

  static int _displaySize(Match? match) {
    if (match == null) return 0;
    final value = double.tryParse(match.group(1) ?? '') ?? 0;
    final unit = (match.group(2) ?? '').toUpperCase();
    final factor = switch (unit) {
      'K' => 1024,
      'M' => 1024 * 1024,
      'G' => 1024 * 1024 * 1024,
      'T' => 1024 * 1024 * 1024 * 1024,
      _ => 1,
    };
    return (value * factor).toInt();
  }
}

class _Page {
  const _Page(this.url, this.baseUrl, this.html);

  final String url;
  final String baseUrl;
  final String html;
}
