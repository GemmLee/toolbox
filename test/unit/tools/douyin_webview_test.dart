import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/features/tools/link_parser/douyin_webview.dart';
import 'package:toolbox/features/tools/link_parser/video_parser.dart';

DouyinWebViewBridge _bridge(Object? payload) => DouyinWebViewBridge(
      invoker: (method, args) async {
        expect(method, 'douyinParse');
        expect(args['id'], isNotEmpty);
        if (payload == null) return null;
        return payload is String ? payload : jsonEncode(payload);
      },
    );

void main() {
  test('识别抖音短链 / 视频页 / 图集页并取出作品 id', () {
    final short = VideoParser.detect('https://v.douyin.com/iAbCdEf/');
    expect(short?.platform, '抖音');
    expect(short?.isShort, isTrue);
    // 短码不是作品 id：留空，等展开后再取。
    expect(short?.id, isEmpty);

    final video = VideoParser.detect(
      'https://www.douyin.com/video/7312345678901234567',
    );
    expect(video?.platform, '抖音');
    expect(video?.id, '7312345678901234567');

    final share = VideoParser.detect(
      'https://www.iesdouyin.com/share/video/7312345678901234567/?region=CN',
    );
    expect(share?.id, '7312345678901234567');

    final note = VideoParser.detect(
      'https://www.douyin.com/note/7312345678901234567',
    );
    expect(note?.id, '7312345678901234567');
  });

  test('电脑版弹层链接（modal_id）与极速版短链也能识别', () {
    final modal = VideoParser.detect(
      'https://www.douyin.com/user/self?from_tab_name=main&modal_id=7312345678901234567',
    );
    expect(modal?.platform, '抖音');
    expect(modal?.id, '7312345678901234567');

    expect(
      VideoParser.detect('https://m.douyin.com/share/video/7312345678901234567')
          ?.id,
      '7312345678901234567',
    );
    expect(
      VideoParser.detect(
              'https://jingxuan.douyin.com/m/note/7312345678901234567')
          ?.id,
      '7312345678901234567',
    );
    expect(
        VideoParser.detect('https://jx.douyin.com/iAbCdEf')?.isShort, isTrue);
  });

  test('短链跟一次 302 后从 Location 里取到作品 id', () async {
    String? seenId;
    final bridge = DouyinWebViewBridge(
      invoker: (method, args) async {
        seenId = args['id'] as String?;
        return jsonEncode(<String, dynamic>{
          'title': '海边的一天',
          'video': 'https://v3.douyinpic.com/play/abc.mp4',
          'images': <String>[],
        });
      },
    );
    var hops = 0;
    final result = await VideoParser.parse(
      'https://v.douyin.com/iAbCdEf/',
      client: MockClient((request) async {
        hops++;
        expect(request.headers['User-Agent'], contains('iPhone'));
        return http.Response(
          '',
          302,
          headers: <String, String>{
            'location':
                'https://www.iesdouyin.com/share/video/7312345678901234567/?region=CN',
          },
        );
      }),
      douyinBridge: bridge,
    );

    expect(hops, 1);
    expect(seenId, '7312345678901234567');
    expect(result.title, '海边的一天');
    expect(result.media.single.kind, VideoMediaKind.video);
  });

  test('WebView 返回视频时给一条无水印直链', () async {
    final result = await VideoParser.parse(
      'https://www.douyin.com/video/7312345678901234567',
      douyinBridge: _bridge(<String, dynamic>{
        'title': '海边的一天',
        'desc': '海边的一天',
        'author': '作者甲',
        'video': 'https://v3.douyinpic.com/play/abc.mp4',
        'images': <String>[],
        'cover': 'https://p3.douyinpic.com/cover.jpg',
        'src': 'hook',
      }),
    );

    expect(result.platform, '抖音');
    expect(result.title, '海边的一天');
    expect(result.author, '作者甲');
    expect(result.coverUrl, 'https://p3.douyinpic.com/cover.jpg');
    expect(result.media, hasLength(1));
    expect(result.media.single.kind, VideoMediaKind.video);
    expect(result.media.single.url, contains('/play/'));
    expect(result.media.single.fileName, endsWith('.mp4'));
    expect(result.media.single.referer, 'https://www.douyin.com/');
  });

  test('图集给多张原图，动图作品在说明里讲清楚只存静态帧', () async {
    final result = await VideoParser.parse(
      'https://www.douyin.com/note/7312345678901234567',
      douyinBridge: _bridge(<String, dynamic>{
        'title': '两张图',
        'images': <String>[
          'https://p3.douyinpic.com/a.webp',
          'https://p3.douyinpic.com/b.webp',
        ],
        'motions': <String>['https://v3.douyinpic.com/m1.mp4', ''],
        'src': 'ssr',
      }),
    );

    expect(result.media, hasLength(2));
    expect(result.media.every((m) => m.kind == VideoMediaKind.image), isTrue);
    expect(result.media.first.fileName, endsWith('_1.jpg'));
    expect(result.media.last.fileName, endsWith('_2.webp'));
    expect(result.note, contains('静态原图'));
  });

  test('图文作品三张图全部保留，空串与 null 占位被过滤', () async {
    // 回归：SSR / aweme_detail.images 只给 2 张时，取数脚本应改从
    // image_post_info.images 取全 3 张；这里验证 Dart 侧不会二次截断。
    final result = await VideoParser.parse(
      'https://www.douyin.com/note/7708587331557953128',
      douyinBridge: _bridge(<String, dynamic>{
        'title': '110kV单回电缆终端钢管杆',
        'images': <String>[
          'https://p3.douyinpic.com/a.webp',
          '',
          'https://p3.douyinpic.com/b.webp',
          'null',
          'https://p3.douyinpic.com/c.webp',
        ],
        'motions': <String>['', '', ''],
        'src': 'hook',
      }),
    );

    expect(result.media, hasLength(3));
    expect(
      result.media.map((m) => m.url).toList(),
      <String>[
        'https://p3.douyinpic.com/a.webp',
        'https://p3.douyinpic.com/b.webp',
        'https://p3.douyinpic.com/c.webp',
      ],
    );
    expect(result.media[0].fileName, endsWith('_1.webp'));
    expect(result.media[1].fileName, endsWith('_2.webp'));
    expect(result.media[2].fileName, endsWith('_3.webp'));
    expect(result.coverUrl, 'https://p3.douyinpic.com/a.webp');
  });

  test('页面没给出数据时给出可操作的提示，而不是假链接', () async {
    await expectLater(
      VideoParser.parse(
        'https://www.douyin.com/video/7312345678901234567',
        douyinBridge: _bridge(null),
      ),
      throwsA(
        isA<VideoParseException>().having(
          (e) => e.message,
          'message',
          contains('换个网络'),
        ),
      ),
    );
  });

  test('只有封面没有媒体时视为失败', () async {
    final bridge = _bridge(<String, dynamic>{
      'title': '只有标题',
      'cover': 'https://p3.douyinpic.com/c.jpg',
      'images': <String>[],
    });
    final payload = await bridge.load(id: '7312345678901234567', kind: 'video');
    expect(payload, isNull);
  });

  test('短链展开失败时提示重新复制链接', () async {
    await expectLater(
      VideoParser.parse(
        'https://v.douyin.com/iAbCdEf/',
        // 短链展开拿不到 Location：保持短码 → 取不出作品 id。
        client: MockClient((request) async => http.Response('', 200)),
        douyinBridge: _bridge(<String, dynamic>{'video': 'https://x/y.mp4'}),
      ),
      throwsA(
        isA<VideoParseException>().having(
          (e) => e.message,
          'message',
          contains('复制链接'),
        ),
      ),
    );
  });
}
