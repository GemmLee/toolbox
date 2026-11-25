import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/features/tools/link_parser/video_parser.dart';

/// 把 JSON 再转义一层，模拟各平台页面里 `\\"` 双转义的内联脚本。
String _doubleEscape(String json) => json.replaceAll('"', r'\\"');

http.Client _client(
  Map<String, http.Response> routes, {
  Map<String, http.Response>? byMethod,
}) {
  return MockClient((request) async {
    final key = '${request.method} ${request.url}';
    final exact = byMethod?[key];
    if (exact != null) return exact;
    for (final entry in routes.entries) {
      if (request.url.toString().startsWith(entry.key)) return entry.value;
    }
    return http.Response('not found', 404);
  });
}

void main() {
  group('视频链接识别', () {
    test('B 站：BV 号 / av 号 / 短链', () {
      expect(
        VideoParser.detect('https://www.bilibili.com/video/BV1xx411c7mD')?.id,
        'BV1xx411c7mD',
      );
      expect(
        VideoParser.detect('https://www.bilibili.com/video/av170001')?.id,
        'av170001',
      );
      final short = VideoParser.detect('https://b23.tv/abc123');
      expect(short?.platform, '哔哩哔哩');
      expect(short?.isShort, isTrue);
    });

    test('AcFun / Pixiv / 快手 / 微博 识别', () {
      expect(
        VideoParser.detect('https://www.acfun.cn/v/ac12345678')?.id,
        '12345678',
      );
      expect(
        VideoParser.detect('https://www.pixiv.net/artworks/987654')?.id,
        '987654',
      );
      expect(
        VideoParser.detect(
          'https://www.pixiv.net/member_illust.php?illust_id=555',
        )?.id,
        '555',
      );
      expect(
        VideoParser.detect('https://www.kuaishou.com/short-video/3xabc')?.id,
        '3xabc',
      );
      expect(
        VideoParser.detect('https://m.weibo.cn/status/5012345678901234')?.id,
        '5012345678901234',
      );
      expect(
        VideoParser.detect('https://video.weibo.com/show?fid=1034:4900000')?.id,
        '1034:4900000',
      );
    });

    test('小红书笔记与短链', () {
      final note = VideoParser.detect(
        'https://www.xiaohongshu.com/explore/65f0a1b2c3d4e5f60718293a',
      );
      expect(note?.platform, '小红书');
      expect(note?.id, '65f0a1b2c3d4e5f60718293a');
      expect(VideoParser.detect('https://xhslink.com/a/bCdEf')?.isShort, isTrue);
    });

    test('非视频链接不识别', () {
      expect(VideoParser.detect('https://pan.quark.cn/s/abc'), isNull);
      expect(VideoParser.detect('https://example.com/a.mp4'), isNull);
    });
  });

  group('B 站解析', () {
    test('取标题 / 作者 / 单文件直链，并带上防盗链头', () async {
      final client = _client(<String, http.Response>{
        'https://api.bilibili.com/x/web-interface/view': http.Response(
          jsonEncode(<String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{
              'bvid': 'BV1xx411c7mD',
              'cid': 123,
              'title': '测试视频',
              'desc': '简介',
              'pubdate': 1700000000,
              'pic': '//i0.hdslb.com/cover.jpg',
              'owner': <String, dynamic>{
                'name': 'UP 主',
                'face': '//i0.hdslb.com/face.jpg',
              },
              'pages': <dynamic>[
                <String, dynamic>{'cid': 123},
              ],
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
        'https://api.bilibili.com/x/player/playurl': http.Response(
          jsonEncode(<String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{
              'quality': 80,
              'durl': <dynamic>[
                <String, dynamic>{
                  'url': '//upos-sz-mirror.bilivideo.com/v.mp4',
                  'size': 1024,
                },
              ],
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      });

      final result = await VideoParser.parse(
        'https://www.bilibili.com/video/BV1xx411c7mD',
        client: client,
      );
      expect(result.title, '测试视频');
      expect(result.author, 'UP 主');
      expect(result.coverUrl, 'https://i0.hdslb.com/cover.jpg');
      expect(result.media.length, 2);
      final video = result.media.first;
      expect(video.url, 'https://upos-sz-mirror.bilivideo.com/v.mp4');
      expect(video.fileName, '测试视频.mp4');
      expect(video.referer, 'https://www.bilibili.com/');
      expect(video.quality, '1080P');
      expect(result.media.last.kind, VideoMediaKind.image);
    });

    test('接口返回错误码时给出可读提示', () async {
      final client = _client(<String, http.Response>{
        'https://api.bilibili.com/x/web-interface/view': http.Response(
          jsonEncode(<String, dynamic>{'code': -404, 'message': '啥都木有'}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      });
      await expectLater(
        VideoParser.parse(
          'https://www.bilibili.com/video/BV1xx411c7mD',
          client: client,
        ),
        throwsA(
          isA<VideoParseException>().having(
            (e) => e.message,
            'message',
            contains('-404'),
          ),
        ),
      );
    });
  });

  group('AcFun 解析', () {
    test('从内联 videoInfo 取标题与 m3u8', () async {
      final info = <String, dynamic>{
        'title': 'AcFun 测试',
        'coverUrl': '//cdn.acfun.cn/c.jpg',
        'createTime': '2024-12-01',
        'user': <String, dynamic>{'name': '阿婆主'},
        'currentVideoInfo': <String, dynamic>{
          'ksPlayJson': jsonEncode(<String, dynamic>{
            'adaptationSet': <dynamic>[
              <String, dynamic>{
                'representation': <dynamic>[
                  <String, dynamic>{'url': 'https://cdn/a-4k.m3u8'},
                  <String, dynamic>{'url': 'https://cdn/a-1080.m3u8'},
                  <String, dynamic>{'url': 'https://cdn/a-720p60.m3u8'},
                  <String, dynamic>{'url': 'https://cdn/a-720.m3u8'},
                ],
              },
            ],
          }),
        },
      };
      final html = '<script>window.videoInfo = '
          '${_doubleEscape(jsonEncode(info))}</script>';
      final client = _client(<String, http.Response>{
        'https://www.acfun.cn/v/ac12345678':
            http.Response.bytes(utf8.encode(html), 200),
      });

      final result = await VideoParser.parse(
        'https://www.acfun.cn/v/ac12345678',
        client: client,
      );
      expect(result.title, 'AcFun 测试');
      expect(result.author, '阿婆主');
      expect(result.media.first.isHls, isTrue);
      expect(result.media.first.url, 'https://cdn/a-720.m3u8');
      expect(result.media.first.fileName, 'AcFun 测试.m3u8');
    });
  });

  group('微博解析', () {
    test('status 接口取图集与标题', () async {
      final client = _client(<String, http.Response>{
        'https://m.weibo.cn/statuses/show': http.Response(
          jsonEncode(<String, dynamic>{
            'data': <String, dynamic>{
              'id': '5012345678901234',
              'text': '正文<br />第二行',
              'created_at': 'Wed Nov 06 12:00:00 +0800 2024',
              'user': <String, dynamic>{'screen_name': '博主'},
              'page_info': <String, dynamic>{
                'title': '微博标题',
                'page_pic': <String, dynamic>{'url': 'https://wx/pic.jpg'},
              },
              'pics': <dynamic>[
                <String, dynamic>{
                  'large': <String, dynamic>{'url': 'https://wx/1.jpg'},
                },
                <String, dynamic>{
                  'large': <String, dynamic>{'url': 'https://wx/2.png'},
                },
              ],
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      });

      final result = await VideoParser.parse(
        'https://m.weibo.cn/status/5012345678901234',
        client: client,
      );
      expect(result.title, '微博标题');
      expect(result.author, '博主');
      expect(result.text, '正文\n第二行');
      expect(result.media.length, 2);
      expect(result.media.first.url, 'https://wx/1.jpg');
      expect(result.media.first.fileName, '微博标题_1.jpg');
      expect(result.media.last.fileName, '微博标题_2.png');
    });
  });

  group('Pixiv 解析', () {
    test('多页原图逐张命名', () async {
      final client = _client(<String, http.Response>{
        'https://www.pixiv.net/ajax/illust/987654/pages': http.Response(
          jsonEncode(<String, dynamic>{
            'error': false,
            'body': <dynamic>[
              <String, dynamic>{
                'urls': <String, dynamic>{'original': 'https://i.pximg.net/a.jpg'},
              },
              <String, dynamic>{
                'urls': <String, dynamic>{'original': 'https://i.pximg.net/b.png'},
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
        'https://www.pixiv.net/ajax/illust/987654': http.Response(
          jsonEncode(<String, dynamic>{
            'error': false,
            'body': <String, dynamic>{
              'illustType': 0,
              'title': '作品名',
              'userName': '画师',
              'description': '说明',
              'createDate': '2024-01-02T03:04:05+09:00',
              'urls': <String, dynamic>{'original': 'https://i.pximg.net/a.jpg'},
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      });

      final result = await VideoParser.parse(
        'https://www.pixiv.net/artworks/987654',
        client: client,
      );
      expect(result.title, '作品名');
      expect(result.author, '画师');
      expect(result.media.length, 2);
      expect(result.media.first.fileName, '作品名_1.jpg');
      expect(result.media.last.fileName, '作品名_2.png');
      expect(result.media.first.referer, 'https://www.pixiv.net/');
      expect(result.timestampSeconds, greaterThan(0));
    });

    test('动图作品直接提示不支持', () async {
      final client = _client(<String, http.Response>{
        'https://www.pixiv.net/ajax/illust/1': http.Response(
          jsonEncode(<String, dynamic>{
            'error': false,
            'body': <String, dynamic>{'illustType': 2, 'title': '动图'},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      });
      await expectLater(
        VideoParser.parse('https://www.pixiv.net/artworks/1', client: client),
        throwsA(
          isA<VideoParseException>().having(
            (e) => e.message,
            'message',
            contains('ugoira'),
          ),
        ),
      );
    });
  });

  group('小红书解析', () {
    test('从 __INITIAL_STATE__ 取标题与图片', () async {
      final state = <String, dynamic>{
        'note': <String, dynamic>{
          'noteDetailMap': <String, dynamic>{
            '65f0a1b2c3d4e5f60718293a': <String, dynamic>{
              'note': <String, dynamic>{
                'title': '笔记标题',
                'desc': '正文内容',
                'time': 1700000000000,
                'user': <String, dynamic>{'nickname': '作者'},
                'imageList': <dynamic>[
                  <String, dynamic>{'urlDefault': 'https://sns-img-qc.xhscdn.com/abc'},
                ],
              },
            },
          },
        },
      };
      // 页面里的裸 undefined 必须能被替换成 null 后解析。
      final json = jsonEncode(state).replaceFirst('{', '{"junk":undefined,');
      final html = '<script>window.__INITIAL_STATE__ = $json</script>';
      final client = _client(<String, http.Response>{
        'https://www.xiaohongshu.com/explore/':
            http.Response.bytes(utf8.encode(html), 200),
      });

      final result = await VideoParser.parse(
        'https://www.xiaohongshu.com/explore/65f0a1b2c3d4e5f60718293a',
        client: client,
      );
      expect(result.title, '笔记标题');
      expect(result.author, '作者');
      expect(result.media.single.url, 'https://sns-img-qc.xhscdn.com/abc');
      expect(result.media.single.fileName, '笔记标题_1.jpg');
    });
  });
}
