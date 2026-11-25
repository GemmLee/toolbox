import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/features/tools/link_parser/baidu_resolver.dart';
import 'package:toolbox/features/tools/link_parser/c139_resolver.dart';
import 'package:toolbox/features/tools/link_parser/quark_uc_resolver.dart';
import 'package:toolbox/features/tools/link_parser/share_link.dart';
import 'package:toolbox/features/tools/link_parser/share_models.dart';

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
  group('夸克协议', () {
    test('token → 列表 → 免转存取链，带上分享参数', () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/sharepage/token')) {
          expect(jsonDecode(request.body)['pwd_id'], 'abc');
          expect(request.headers['User-Agent'], contains('quark-cloud-drive'));
          return _jsonOk(<String, dynamic>{
            'status': 200,
            'data': <String, dynamic>{'stoken': 'ST', 'title': '演示分享'},
          });
        }
        if (url.contains('/sharepage/detail')) {
          expect(request.headers['Origin'], 'https://pan.quark.cn');
          expect(request.url.queryParameters['stoken'], 'ST');
          return _jsonOk(<String, dynamic>{
            'status': 200,
            'data': <String, dynamic>{
              'list': <dynamic>[
                <String, dynamic>{
                  'fid': 'f1',
                  'file_name': 'a.mp4',
                  'size': 12,
                  'dir': false,
                  'pdir_fid': '0',
                  'share_fid_token': 'tok',
                },
              ],
            },
          });
        }
        if (url.contains('/file/download')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['fids'], <dynamic>['f1']);
          expect(body['fids_token'], <dynamic>['tok']);
          expect(body['pwd_id'], 'abc');
          return _jsonOk(<String, dynamic>{
            'status': 200,
            'data': <dynamic>[
              <String, dynamic>{
                'fid': 'f1',
                'file_name': 'a.mp4',
                'download_url': 'https://cdn.example.com/a.mp4',
                'size': 12,
              },
            ],
          });
        }
        fail('意外的请求：$url');
      });

      final resolver = QuarkResolver();
      const share = ParsedShare(
        shareId: 'abc',
        pwd: '1234',
        platform: SharePlatform.quark,
      );
      final session = await resolver.createSession(
        share,
        cookie: 'k=v',
        client: client,
      );
      expect(session.token, 'ST');
      expect(session.title, '演示分享');

      final files = await resolver.listFiles(
        session,
        dirFid: '0',
        cookie: 'k=v',
        client: client,
      );
      expect(files.single.fidToken, 'tok');

      final link = await resolver.downloadLink(
        session,
        files.single,
        cookie: 'k=v',
        client: client,
      );
      expect(link.url, 'https://cdn.example.com/a.mp4');
      expect(link.referer, 'https://pan.quark.cn/');
      expect(link.cleanupDirFid, isEmpty);
    });

    test('游客取链带回应答里的 __pugs', () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/sharepage/token')) {
          return _jsonOk(<String, dynamic>{
            'status': 200,
            'data': <String, dynamic>{'stoken': 'GUEST'},
          });
        }
        if (url.contains('/file/download')) {
          expect(request.headers.containsKey('Cookie'), isFalse);
          return _jsonOk(<String, dynamic>{
            'status': 200,
            'data': <dynamic>[
              <String, dynamic>{
                'download_url': 'https://cdn.example.com/g.mp4',
                'size': 1,
              },
            ],
          }, headers: <String, String>{
            'set-cookie': '__pugs=PUG; Path=/',
          });
        }
        fail('意外的请求：$url');
      });
      final resolver = QuarkResolver();
      final session = await resolver.createSession(
        const ParsedShare(
          shareId: 'guest',
          pwd: '',
          platform: SharePlatform.quark,
        ),
        cookie: '',
        client: client,
      );
      final link = await resolver.downloadLink(
        session,
        const ShareFile(
          fid: 'f1',
          name: 'g.mp4',
          size: 1,
          isDir: false,
          pdirFid: '0',
          fidToken: 'tok',
        ),
        cookie: '',
        client: client,
      );
      expect(link.cookie, contains('__pugs=PUG'));
    });
  });

  group('UC 协议', () {
    test('列表走 transfer_share/detail，取链无需转存', () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/sharepage/token')) {
          expect(jsonDecode(request.body)['share_for_transfer'], true);
          return _jsonOk(<String, dynamic>{
            'status': 200,
            'data': <String, dynamic>{'stoken': 'UCS'},
          });
        }
        if (url.contains('transfer_share/detail')) {
          expect(request.headers['Referer'], 'https://fast.uc.cn/');
          return _jsonOk(<String, dynamic>{
            'status': 200,
            'data': <String, dynamic>{
              'list': <dynamic>[
                <String, dynamic>{
                  'fid': 'uf1',
                  'file_name': 'b.zip',
                  'size': 100,
                  'dir': false,
                  'share_fid_token': 'utok',
                },
              ],
            },
          });
        }
        if (url.contains('/file/download')) {
          return _jsonOk(<String, dynamic>{
            'status': 200,
            'data': <dynamic>[
              <String, dynamic>{
                'download_url': 'https://oss.example.com/b.zip',
                'size': 100,
              },
            ],
          });
        }
        fail('意外的请求：$url');
      });
      final resolver = UcResolver();
      final session = await resolver.createSession(
        const ParsedShare(
          shareId: 'ucid',
          pwd: 'a1',
          platform: SharePlatform.uc,
        ),
        cookie: 'u=v',
        client: client,
      );
      final files = await resolver.listFiles(
        session,
        dirFid: '0',
        cookie: 'u=v',
        client: client,
      );
      expect(files.single.name, 'b.zip');
      final link = await resolver.downloadLink(
        session,
        files.single,
        cookie: 'u=v',
        client: client,
      );
      expect(link.url, 'https://oss.example.com/b.zip');
      expect(link.cleanupDirFid, isEmpty);
    });
  });

  group('百度协议', () {
    test('verify → 列表 → 转存 → locatedownload，优先明文直链', () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/share/verify')) {
          expect(request.body, contains('pwd=abcd'));
          return _jsonOk(<String, dynamic>{'errno': 0, 'randsk': 'SEKEY'});
        }
        if (url.contains('/xpan/share')) {
          expect(request.headers['Cookie'], contains('BDCLND=SEKEY'));
          return _jsonOk(<String, dynamic>{
            'errno': 0,
            'share_id': '11',
            'uk': '22',
            'list': <dynamic>[
              <String, dynamic>{
                'fs_id': '77',
                'server_filename': 'c.pdf',
                'size': 9,
                'isdir': '0',
                'path': '/c.pdf',
              },
            ],
          });
        }
        if (url.contains('gettemplatevariable')) {
          return _jsonOk(<String, dynamic>{
            'errno': 0,
            'result': <String, dynamic>{'bdstoken': 'BD'},
          });
        }
        if (url.contains('/xpan/file?method=list')) {
          return _jsonOk(<String, dynamic>{
            'errno': 0,
            'list': <dynamic>[
              <String, dynamic>{'path': '/XMtools临时转存'},
            ],
          });
        }
        if (url.contains('/share/transfer')) {
          return _jsonOk(<String, dynamic>{
            'errno': 0,
            'extra': <String, dynamic>{
              'list': <dynamic>[
                <String, dynamic>{
                  'to_fs_id': '88',
                  'to': '/XMtools临时转存/c.pdf',
                },
              ],
            },
          });
        }
        if (url.contains('locatedownload')) {
          return _jsonOk(<String, dynamic>{
            'errno': 0,
            'urls': <dynamic>[
              <String, dynamic>{
                'url': 'https://d2-ant.baidu.com/x',
                'encrypt': 1,
              },
              <String, dynamic>{
                'url': 'https://appall01.baidupcs.com/x',
                'encrypt': 0,
              },
            ],
          });
        }
        if (url.contains('filemanager')) {
          return _jsonOk(<String, dynamic>{'errno': 0});
        }
        fail('意外的请求：$url');
      });

      final resolver = BaiduResolver();
      final session = await resolver.createSession(
        const ParsedShare(
          shareId: 'surl1',
          pwd: 'abcd',
          platform: SharePlatform.baidu,
        ),
        cookie: 'BDUSS=TOKEN',
        client: client,
      );
      expect(session.token, 'SEKEY');
      final files = await resolver.listFiles(
        session,
        dirFid: '/',
        cookie: 'BDUSS=TOKEN',
        client: client,
      );
      expect(files.single.fid, '77');
      final link = await resolver.downloadLink(
        session,
        files.single,
        cookie: 'BDUSS=TOKEN',
        client: client,
      );
      expect(link.url, 'https://appall01.baidupcs.com/x');
    });
  });

  group('139 协议', () {
    test('列目录合并 caLst / coLst，取链返回 OBS 直链', () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        final plain = jsonDecode(C139Resolver.decryptBody(request.body))
            as Map<String, dynamic>;
        if (url.contains('getOutLinkInfoV6')) {
          final req = plain['getOutLinkInfoReq'] as Map<String, dynamic>;
          expect(req['linkID'], 'link1');
          expect(req['pCaID'], 'root');
          expect(request.headers['hcy-cool-flag'], '1');
          expect(request.headers.containsKey('mcloud-sign'), isFalse);
          return http.Response(
            C139Resolver.encryptBody(jsonEncode(<String, dynamic>{
              'resultCode': '0',
              'success': true,
              'data': <String, dynamic>{
                'caLst': <dynamic>[
                  <String, dynamic>{'caID': 'ca1', 'caName': '子目录'},
                ],
                'coLst': <dynamic>[
                  <String, dynamic>{
                    'coID': 'co1',
                    'coName': 'd.mp4',
                    'coSize': 9,
                    'coType': 1,
                  },
                ],
              },
            })),
            200,
          );
        }
        if (url.contains('dlFromOutLinkV3')) {
          final req = plain['dlFromOutLinkReqV3'] as Map<String, dynamic>;
          expect(req['coIDLst']['item'], <dynamic>['co1']);
          expect(request.headers['mcloud-sign'], isNotEmpty);
          return http.Response(
            C139Resolver.encryptBody(jsonEncode(<String, dynamic>{
              'resultCode': '0',
              'success': true,
              'data': <String, dynamic>{
                'redrUrl': 'https://obs.example.com/d.mp4',
                'fileName': 'd.mp4',
                'coSize': 9,
              },
            })),
            200,
          );
        }
        fail('意外的请求：$url');
      });

      final resolver = C139Resolver();
      final session = await resolver.createSession(
        const ParsedShare(
          shareId: 'link1',
          pwd: '3388',
          platform: SharePlatform.c139,
        ),
        cookie: 'authorization=Basic abc; Os_SSo_Sid=S; RMKEY=K',
        client: client,
      );
      expect(session.extra['account'], '');
      final files = await resolver.listFiles(
        session,
        dirFid: '',
        cookie: '',
        client: client,
      );
      expect(files.map((f) => f.name), <String>['子目录', 'd.mp4']);
      expect(files.last.isDir, isFalse);

      final link = await resolver.downloadLink(
        session,
        files.last,
        cookie: '',
        client: client,
      );
      expect(link.url, 'https://obs.example.com/d.mp4');
      expect(link.size, 9);
    });
  });
}
