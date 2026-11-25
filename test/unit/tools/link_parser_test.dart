import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/features/tools/link_parser/link_parser.dart';

void main() {
  group('链接提取与平台识别', () {
    test('从分享文本里抠出链接并去掉尾部标点', () {
      expect(
        LinkParser.extractUrl(
            '看看这个 https://www.bilibili.com/video/BV1xx411c7mD，很好'),
        'https://www.bilibili.com/video/BV1xx411c7mD',
      );
      expect(LinkParser.extractUrl('没有链接'), isNull);
    });

    test('平台识别覆盖主流站点', () {
      expect(LinkParser.platformOf('https://b23.tv/abc'), '哔哩哔哩');
      expect(LinkParser.platformOf('https://v.douyin.com/abc/'), '抖音');
      expect(LinkParser.platformOf('https://www.xiaohongshu.com/x'), '小红书');
      expect(LinkParser.platformOf('https://pan.quark.cn/s/1'), '夸克网盘');
      expect(LinkParser.platformOf('https://drive.uc.cn/s/1'), 'UC 网盘');
      expect(LinkParser.platformOf('https://example.com/a.jpg'), '直链 / 其他');
    });
  });

  group('直链', () {
    test('图片 / 视频 / 音频 / 文件按扩展名识别，不发起请求', () async {
      final parser = LinkParser(
        client: MockClient((_) async => throw StateError('不该请求直链')),
      );
      final image = await parser.parse('https://cdn.example.com/a.jpg');
      expect(image.media.single.kind, MediaKind.image);
      expect(image.url, 'https://cdn.example.com/a.jpg');

      final video = await parser.parse('https://cdn.example.com/a.mp4?x=1');
      expect(video.media.single.kind, MediaKind.video);

      final audio = await parser.parse('https://cdn.example.com/a.m4a');
      expect(audio.media.single.kind, MediaKind.audio);

      final pdf = await parser.parse('https://cdn.example.com/a.pdf');
      expect(pdf.media.single.kind, MediaKind.file);
    });
  });

  group('登录凭证与备用地址', () {
    test('登录后的 Cookie 会随同域请求一起发出', () async {
      final headersSeen = <Map<String, String>>[];
      final parser = LinkParser(
        client: MockClient((request) async {
          headersSeen.add(request.headers);
          return http.Response('<title>已登录</title>', 200,
              headers: <String, String>{
                'content-type': 'text/html; charset=utf-8'
              });
        }),
      );
      final result = await parser.parse(
        'https://pan.baidu.com/s/abc',
        headers: <String, String>{'Cookie': 'authorToken=abc'},
      );
      expect(result.success, isTrue);
      expect(headersSeen.single['Cookie'], 'authorToken=abc');
    });

    test('主地址失败会自动换备用地址，并记录实际使用的地址', () async {
      var calls = 0;
      final parser = LinkParser(
        client: MockClient((request) async {
          calls++;
          if (request.url.host == 'down.example.com') {
            return http.Response('', 503);
          }
          return http.Response('<title>备用标题</title>', 200,
              headers: <String, String>{
                'content-type': 'text/html; charset=utf-8'
              });
        }),
        endpointBuilder: (_) => <String>['https://backup.example.net/p'],
      );
      final result = await parser.parse('https://down.example.com/p');
      expect(calls, 2);
      expect(result.title, '备用标题');
      expect(result.endpoint, 'https://backup.example.net/p');
    });
  });

  group('网盘协议解析', () {
    test('识别夸克分享后走协议，结果保留会话供后续取链', () async {
      final parser = LinkParser(
        client: MockClient((request) async {
          final url = request.url.toString();
          if (url.contains('/sharepage/token')) {
            return http.Response(
              '{"status":200,"data":{"stoken":"ST","title":"协议标题"}}',
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          if (url.contains('/sharepage/detail')) {
            return http.Response(
              '{"status":200,"data":{"list":[{"fid":"f1","file_name":"a.txt",'
              '"size":3,"dir":false,"pdir_fid":"0","share_fid_token":"tok"}]}}',
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          if (url.contains('/file/download')) {
            return http.Response(
              '{"status":200,"data":[{"download_url":"https://cdn.example.com/a.txt",'
              '"size":3}]}',
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final result = await parser.parse('https://pan.quark.cn/s/abc 提取码: 1234');
      expect(result.success, isTrue);
      expect(result.platform, '夸克网盘');
      expect(result.title, '协议标题');
      expect(result.canBrowse, isTrue);
      expect(result.files.single.name, 'a.txt');
      expect(result.session, isNotNull);

      final link = await parser.resolveDownload(result, result.files.single);
      expect(link.url, 'https://cdn.example.com/a.txt');
      parser.dispose();
    });

    test('123 云盘走协议解析，返回可继续浏览的文件列表', () async {
      final parser = LinkParser(
        client: MockClient((request) async {
          expect(request.url.host, contains('123pan'));
          return http.Response(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{
                'InfoList': <dynamic>[
                  <String, dynamic>{
                    'FileId': 11,
                    'FileName': '资料.txt',
                    'Size': 10,
                    'Type': 0,
                    'ParentFileId': 0,
                  },
                ],
                'Next': '-1',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      final result =
          await parser.parse('https://www.123pan.com/s/2785Vv-T4Ded');
      expect(result.success, isTrue);
      expect(result.platform, '123 云盘');
      expect(result.canBrowse, isTrue);
      expect(result.files.single.name, '资料.txt');
    });

    test('手填提取码会覆盖分享文案里识别不到的提取码', () async {
      final queries = <String>[];
      final parser = LinkParser(
        client: MockClient((request) async {
          queries.add(request.url.toString());
          return http.Response(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{
                'InfoList': <dynamic>[],
                'Next': '-1',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      // 文案里没有提取码：不填则请求不带 SharePwd。
      await parser.parse('https://www.123pan.com/s/2785Vv-T4Ded');
      expect(queries.last.contains('SharePwd'), isFalse);

      // 手填 8888 后按它请求。
      await parser.parse(
        'https://www.123pan.com/s/2785Vv-T4Ded',
        pwd: '8888',
      );
      expect(queries.last, contains('SharePwd=8888'));
    });
  });

  group('分享页解析', () {
    test('取 og:title / og:image / og:video，并补全相对地址', () async {
      const html = '''
<html><head>
<title>页面标题</title>
<meta property="og:title" content="三分钟看懂某个东西">
<meta property="og:image" content="/cover.jpg">
<meta property="og:video" content="https://cdn.example.com/v.mp4">
</head><body></body></html>
''';
      final parser = LinkParser(
        client: MockClient((request) async {
          expect(request.headers['User-Agent'], contains('Mozilla'));
          return http.Response(html, 200, headers: <String, String>{
            'content-type': 'text/html; charset=utf-8'
          });
        }),
      );
      final result =
          await parser.parse('https://www.xiaohongshu.com/explore/1');
      expect(result.success, isTrue);
      expect(result.title, '三分钟看懂某个东西');
      expect(result.coverUrl, 'https://www.xiaohongshu.com/cover.jpg');
      expect(
        result.media.map((m) => m.kind),
        containsAll(<MediaKind>[MediaKind.video, MediaKind.image]),
      );
      expect(result.note, isNotEmpty);
    });

    test('HTTP 错误给出可读提示而不是抛异常', () async {
      final parser = LinkParser(
        client: MockClient((_) async => http.Response('nope', 403)),
      );
      final result = await parser.parse('https://v.douyin.com/abc/');
      expect(result.success, isFalse);
      expect(result.error, contains('403'));
    });

    test('没有链接时直接报错', () async {
      final result = await LinkParser().parse('随便一段文字');
      expect(result.success, isFalse);
      expect(result.error, contains('没有找到链接'));
    });
  });
}
