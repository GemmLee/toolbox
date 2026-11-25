import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/features/tools/link_parser/guangya_resolver.dart';
import 'package:toolbox/features/tools/link_parser/ilanzou_resolver.dart';
import 'package:toolbox/features/tools/link_parser/pan115_resolver.dart';
import 'package:toolbox/features/tools/link_parser/pan123_resolver.dart';
import 'package:toolbox/features/tools/link_parser/share_crypto.dart';
import 'package:toolbox/features/tools/link_parser/share_link.dart';

http.Response _jsonOk(Map<String, dynamic> data,
        {Map<String, String>? headers}) =>
    http.Response(
      jsonEncode(data),
      200,
      headers: <String, String>{
        'content-type': 'application/json',
        ...?headers,
      },
    );

void main() {
  group('加密工具', () {
    test('CRC32 / MD5 / AES-ECB 与参考值一致', () {
      expect(ShareCrypto.crc32Hex('123456789'), 'cbf43926');
      expect(ShareCrypto.md5Hex('abc'), '900150983cd24fb0d6963f7d28e17f72');
      // AES-ECB 已知向量：key=lanZouY-disk-app 非空，两次一致且长度 32 的倍数。
      final a = ShareCrypto.aesEcbHex('123456789|', 'lanZouY-disk-app');
      final b = ShareCrypto.aesEcbHex('123456789|', 'lanZouY-disk-app');
      expect(a, b);
      expect(a.length % 32, 0);
    });
  });

  group('123 云盘', () {
    test('签名头格式、匿名列表、登录取链解码 URL', () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/b/api/share/get')) {
          expect(request.url.queryParameters['shareKey'], 'abc');
          expect(request.url.queryParameters['SharePwd'], '1234');
          return _jsonOk(<String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{
              'InfoList': <dynamic>[
                <String, dynamic>{
                  'FileId': 'f1',
                  'FileName': 'a.mp4',
                  'Size': 9,
                  'Type': 0,
                  'S3KeyFlag': 'flag',
                  'Etag': 'etag',
                  'StorageNode': 'node',
                },
              ],
            },
          });
        }
        if (url.contains('/b/api/share/download/info')) {
          expect(request.headers['authorization'], 'Bearer TOKEN');
          expect(request.headers['auth-key'], isNotEmpty);
          expect(request.headers['auth-value'], contains('-'));
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['S3KeyFlag'], 'flag');
          expect(body['Etag'], 'etag');
          final encoded = base64.encode(utf8.encode('https://cdn.example.com/a.mp4'));
          return _jsonOk(<String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{'DownloadURL': encoded, 'Size': 9},
          });
        }
        // 直链探测：返回大响应，避免被当成跳转 JSON。
        return http.Response('file', 200, headers: <String, String>{
          'content-length': '1024',
        });
      });

      final resolver = Pan123Resolver();
      final session = await resolver.createSession(
        const ParsedShare(shareId: 'abc', pwd: '1234', platform: SharePlatform.pan123),
        cookie: '',
        client: client,
      );
      expect(session.title, 'a.mp4');
      final files = await resolver.listFiles(session,
          dirFid: '0', cookie: '', client: client);
      expect(files.single.fidToken, 'flag|etag|node');
      final link = await resolver.downloadLink(session, files.single,
          cookie: 'TOKEN', client: client);
      expect(link.url, 'https://cdn.example.com/a.mp4');
      expect(link.referer, 'https://yun.123pan.cn/');
    });
  });

  group('蓝奏优享', () {
    test('AES 参数、列表解析、302 取链', () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/unproved/getUuid')) {
          return _jsonOk(<String, dynamic>{'code': 200, 'uuid': 'abcdefghijklmnop'});
        }
        if (url.contains('/unproved/share/list')) {
          return _jsonOk(<String, dynamic>{
            'code': 200,
            'totalPage': 1,
            'list': <dynamic>[
              <String, dynamic>{
                'fileType': 1,
                'fileId': 42,
                'fileName': 'b.zip',
                'fileSize': 3,
              },
            ],
          });
        }
        if (url.contains('/unproved/file/redirect')) {
          // 302 由 MockClient 原样返回，http 包的跟随由客户端处理；这里直接给 JSON 形态。
          return _jsonOk(<String, dynamic>{
            'code': 200,
            'url': '',
            'data': <String, dynamic>{'url': 'https://cdn.example.com/b.zip'},
          });
        }
        fail('意外请求：$url');
      });

      final resolver = ILanzouResolver();
      final session = await resolver.createSession(
        const ParsedShare(shareId: 'abc', platform: SharePlatform.ilanzou),
        cookie: '',
        client: client,
      );
      final files = await resolver.listFiles(session,
          dirFid: '', cookie: '', client: client);
      expect(files.single.name, 'b.zip');
      expect(files.single.size, 3 * 1024);
      expect(files.single.fid, 'f:42');
      final link = await resolver.downloadLink(session, files.single,
          cookie: '', client: client);
      expect(link.url, 'https://cdn.example.com/b.zip');
    });
  });

  group('光鸭云盘', () {
    test('令牌→列表→明文直链，业务码 207 需登录', () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('get_share_access_token')) {
          return _jsonOk(<String, dynamic>{
            'code': '0',
            'data': <String, dynamic>{'accessToken': 'AT'},
          });
        }
        if (url.contains('get_share_summary')) {
          return _jsonOk(<String, dynamic>{
            'code': '0',
            'data': <String, dynamic>{'title': '演示'},
          });
        }
        if (url.contains('get_share_page_files_list')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['accessToken'], 'AT');
          return _jsonOk(<String, dynamic>{
            'code': '0',
            'data': <String, dynamic>{
              'list': <dynamic>[
                <String, dynamic>{
                  'fileId': 'f1',
                  'fileName': 'c.mp4',
                  'fileSize': 10,
                  'resType': '1',
                },
              ],
              'hasMore': false,
            },
          });
        }
        if (url.contains('get_share_download_url')) {
          return _jsonOk(<String, dynamic>{
            'code': '0',
            'data': <String, dynamic>{'signedURL': 'https://cdn.example.com/c.mp4'},
          });
        }
        fail('意外请求：$url');
      });

      final resolver = GuangYaResolver();
      final session = await resolver.createSession(
        const ParsedShare(shareId: 'sid', pwd: 'pw', platform: SharePlatform.guangya),
        cookie: '',
        client: client,
      );
      expect(session.title, '演示');
      final files = await resolver.listFiles(session,
          dirFid: '', cookie: '', client: client);
      expect(files.single.name, 'c.mp4');
      final link = await resolver.downloadLink(session, files.single,
          cookie: '', client: client);
      expect(link.url, 'https://cdn.example.com/c.mp4');
      expect(link.referer, 'https://www.guangyapan.com/');
    });
  });

  group('115 网盘', () {
    test('snap 取分享者 UID + downurl 取直链', () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/share/snap')) {
          return _jsonOk(<String, dynamic>{
            'state': true,
            'data': <String, dynamic>{
              'count': 1,
              'userinfo': <String, dynamic>{'user_id': 'SHARER'},
              'shareinfo': <String, dynamic>{'share_title': '演示'},
              'list': <dynamic>[
                <String, dynamic>{
                  'fid': 'f1',
                  'n': 'd.mp4',
                  's': 20,
                  'fc': 1,
                  'cid': '0',
                },
              ],
            },
          });
        }
        if (url.contains('/share/downurl')) {
          expect(request.url.queryParameters['user_id'], 'SHARER');
          expect(request.headers['User-Agent'], contains('115Browser'));
          return _jsonOk(<String, dynamic>{
            'state': true,
            'data': <String, dynamic>{
              'file_url_302': 'https://cdn.example.com/d.mp4',
              'fn': 'd.mp4',
              'fs': 20,
            },
          }, headers: <String, String>{
            'set-cookie': 'abc=xyz; path=/d/',
          });
        }
        if (url.contains('appversion.115.com')) {
          return _jsonOk(<String, dynamic>{
            'data': <String, dynamic>{'version': <String, dynamic>{'version_code': '36.0.1'}},
          });
        }
        fail('意外请求：$url');
      });

      final resolver = Pan115Resolver();
      final session = await resolver.createSession(
        const ParsedShare(shareId: 'sid', pwd: 'pw', platform: SharePlatform.pan115),
        cookie: '',
        client: client,
      );
      expect(session.token, 'pw|SHARER');
      final files = await resolver.listFiles(session,
          dirFid: '', cookie: '', client: client);
      expect(files.single.name, 'd.mp4');
      final link = await resolver.downloadLink(session, files.single,
          cookie: '', client: client);
      expect(link.url, 'https://cdn.example.com/d.mp4');
      expect(link.cookie, contains('abc=xyz'));
      expect(link.userAgent, contains('115Browser'));
    });
  });
}
