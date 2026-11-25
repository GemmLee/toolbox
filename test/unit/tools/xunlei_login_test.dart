import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/features/tools/link_parser/share_link.dart';
import 'package:toolbox/features/tools/link_parser/share_models.dart';
import 'package:toolbox/features/tools/link_parser/xunlei_auth.dart';
import 'package:toolbox/features/tools/link_parser/xunlei_resolver.dart';

/// 迅雷登录 + 转存取链：整条链路都用 MockClient 跑，锁定请求形态与响应解析。
/// MockClient 的 Response 默认按 latin-1 编码 body，中文要先转 UTF-8 字节。
http.Response jsonResponse(String body, [int status = 200]) => http.Response.bytes(
      utf8.encode(body),
      status,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  const device = XunleiDevice(
    id: 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4',
    peerId: 'ffeeddccbbaa99887766554433221100',
    sign: 'div101.a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4deadbeef',
  );

  group('设备指纹与签名', () {
    test('devicesign = div101.{id}{md5(sha1(id+包名+40+appkey))}', () {
      final sign = XunleiAuth.deviceSign(device.id);
      expect(sign.startsWith('div101.${device.id}'), isTrue);
      // 后缀固定 32 位小写 hex（md5）。
      final suffix = sign.substring('div101.${device.id}'.length);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(suffix), isTrue);
    });

    test('相同设备号得到相同签名，不同设备号签名不同', () {
      expect(XunleiAuth.deviceSign('abc'), XunleiAuth.deviceSign('abc'));
      expect(XunleiAuth.deviceSign('abc'), isNot(XunleiAuth.deviceSign('abd')));
    });

    test('captcha_sign 带 1. 前缀，32 位 hex 后缀', () {
      final sign = XunleiAuth.captchaSign(device.id, 1700000000000);
      expect(sign.startsWith('1.'), isTrue);
      expect(RegExp(r'^1\.[0-9a-f]{32}$').hasMatch(sign), isTrue);
      expect(sign, isNot(XunleiAuth.captchaSign(device.id, 1700000000001)));
    });

    test('随机指纹用同一个种子可复现', () {
      final a = XunleiDevice.create(random: Random(7));
      final b = XunleiDevice.create(random: Random(7));
      expect(a.id, b.id);
      expect(a.id.length, 32);
      expect(a.peerId.length, 32);
      expect(a.sign.startsWith('div101.${a.id}'), isTrue);
    });
  });

  group('账号密码登录', () {
    test('登录成功解析 sessionID / userID', () async {
      final auth = XunleiAuth(
        client: MockClient((request) async {
          expect(request.url.path, '/xluser.core.login/v3/login');
          expect(request.headers['User-Agent'], XunleiAuth.passwordUa);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['userName'], '13800000000');
          expect(body['passWord'], 'secret');
          expect(body['appid'], '40');
          expect(body['devicesign'], device.sign);
          return jsonResponse(
            '{"errorCode":"0","error":"success","sessionID":"SID","'
            'userID":"100","nickName":"小明"}',
            200,
          );
        }),
      );
      final step = await auth.loginWithPassword(
        device: device,
        username: '13800000000',
        password: 'secret',
      );
      expect(step.ok, isTrue);
      expect(step.sessionId, 'SID');
      expect(step.userId, '100');
      expect(step.nickname, '小明');
    });

    test('review_panel 视为需要短信验证，并带回服务端原文', () async {
      final auth = XunleiAuth(
        client: MockClient((request) async => jsonResponse(
              '{"errorCode":"1007","error":"review_panel",'
              '"errorDesc":"请进行安全验证"}',
              200,
            )),
      );
      final step = await auth.loginWithPassword(
        device: device,
        username: '13800000000',
        password: 'secret',
      );
      expect(step.ok, isFalse);
      expect(step.needSms, isTrue);
      expect(step.message, '请进行安全验证');
    });

    test('验证码发送带回 creditkey / token', () async {
      final auth = XunleiAuth(
        client: MockClient((request) async {
          expect(request.url.path, '/xluser.core.login/v3/sendsms');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['mobile'], '13800000000');
          return jsonResponse(
              '{"creditkey":"CK","token":"TK","errorDesc":""}');
        }),
      );
      final step = await auth.sendSms(device: device, mobile: '13800000000');
      expect(step.smsCreditKey, 'CK');
      expect(step.smsToken, 'TK');
      expect(step.message, '验证码已发送');
    });

    test('短信登录成功带回 sessionID', () async {
      final auth = XunleiAuth(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['smsCode'], '1234');
          expect(body['creditkey'], 'CK');
          expect(body['token'], 'TK');
          return jsonResponse(
              '{"errorCode":"0","sessionID":"S2","userID":"100"}');
        }),
      );
      final step = await auth.loginWithSms(
        device: device,
        mobile: '13800000000',
        code: '1234',
        creditKey: 'CK',
        smsToken: 'TK',
      );
      expect(step.ok, isTrue);
      expect(step.sessionId, 'S2');
    });

    test('换 token：先 captcha/init（带 user_id），再带 X-Captcha-Token 换令牌', () async {
      final paths = <String>[];
      final auth = XunleiAuth(
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '/v1/shield/captcha/init') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['client_id'], XunleiAuth.appClientId);
            expect(body['device_id'], device.id);
            expect((body['meta'] as Map)['user_id'], '100');
            expect((body['meta'] as Map)['captcha_sign'],
                startsWith('1.'));
            return jsonResponse('{"captcha_token":"CAP"}');
          }
          expect(request.headers['X-Captcha-Token'], 'CAP');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['signin_token'], 'SID');
          expect(body['provider'], 'access_end_point_token');
          return jsonResponse(
              '{"access_token":"AT","refresh_token":"RT"}');
        }),
      );
      final pair = await auth.exchangeToken(
        device: device,
        sessionId: 'SID',
        userId: '100',
        username: '13800000000',
      );
      expect(pair.accessToken, 'AT');
      expect(pair.refreshToken, 'RT');
      expect(paths, <String>[
        '/v1/shield/captcha/init',
        '/v1/auth/signin/token',
      ]);
    });

    test('换 token 失败时给出可读提示', () async {
      final auth = XunleiAuth(
        client: MockClient((request) async {
          if (request.url.path == '/v1/shield/captcha/init') {
            return jsonResponse('{"captcha_token":"CAP"}');
          }
          return jsonResponse('{"error":"invalid_grant","error_description":"登录信息已过期"}', 400);
        }),
      );
      await expectLater(
        auth.exchangeToken(
          device: device,
          sessionId: 'SID',
          userId: '100',
          username: '13800000000',
        ),
        throwsA(isA<ShareResolveException>().having(
          (e) => e.message,
          'message',
          contains('登录信息已过期'),
        )),
      );
    });
  });

  group('账号存取', () {
    test('toStorage / fromStorage 往返', () {
      const account = XunleiAccount(
        device: device,
        accessToken: 'AT',
        refreshToken: 'RT',
        userId: '100',
        nickname: '小明',
      );
      final restored = XunleiAccount.fromStorage(account.toStorage());
      expect(restored, isNotNull);
      expect(restored!.accessToken, 'AT');
      expect(restored.refreshToken, 'RT');
      expect(restored.userId, '100');
      expect(restored.nickname, '小明');
      expect(restored.device.id, device.id);
      expect(restored.device.sign, device.sign);
    });

    test('没有 access_token 时视为未登录', () {
      expect(XunleiAccount.fromStorage(const <String, String>{}), isNull);
      expect(
        XunleiAccount.fromStorage(const <String, String>{'device_id': 'x'}),
        isNull,
      );
    });
  });

  group('转存取链', () {
    dummyShare() => const ParsedShare(
          shareId: 'SHARE1',
          platform: SharePlatform.xunlei,
          pwd: 'abcd',
        );

    const session = ShareSession(
      platform: SharePlatform.xunlei,
      shareId: 'SHARE1',
      token: 'PCT',
      title: '演示',
      extra: <String, dynamic>{'pwd': 'abcd'},
    );

    const file = ShareFile(
      fid: 'f1',
      name: 'a.bin',
      size: 9,
      isDir: false,
      pdirFid: '0',
    );

    test('已登录：建临时目录 → 转存 → 取直链 → 清理', () async {
      final calls = <String>[];
      const account = XunleiAccount(
        device: device,
        accessToken: 'AT',
        refreshToken: '',
        userId: '100',
      );
      final client = MockClient((request) async {
        final path = request.url.path;
        calls.add('${request.method} $path');
        if (path == '/v1/shield/captcha/init') {
          return jsonResponse('{"captcha_token":"CAP"}');
        }
        if (request.method == 'GET' && path == '/drive/v1/files') {
          expect(request.headers['Authorization'], 'Bearer AT');
          return jsonResponse('{"files":[]}');
        }
        if (request.method == 'POST' && path == '/drive/v1/files') {
          expect(request.headers['X-Captcha-Token'], 'CAP');
          return jsonResponse('{"id":"DIR"}');
        }
        if (path == '/drive/v1/share/restore') {
          return jsonResponse(
            '{"params":{"trace_file_ids":"{\\"f1\\":\\"NEW1\\"}"}}',
            200,
          );
        }
        if (path == '/drive/v1/files/NEW1') {
          return jsonResponse(
            '{"name":"a.bin","size":9,'
            '"links":{"application/octet-stream":{"url":"https://cdn/a.bin"}}}',
            200,
          );
        }
        if (path == '/drive/v1/files:batchDelete') {
          return jsonResponse('{}');
        }
        return jsonResponse('{}', 404);
      });

      final resolver = XunleiResolver(account: account);
      final link = await resolver.downloadLink(
        session,
        file,
        cookie: '',
        client: client,
      );
      expect(link.url, 'https://cdn/a.bin');
      expect(link.filename, 'a.bin');
      expect(link.cleanupDirFid, 'NEW1');

      await resolver.cleanup(link, cookie: '', client: client);
      expect(calls.contains('POST /drive/v1/files:batchDelete'), isTrue);
      expect(calls.contains('POST /drive/v1/share/restore'), isTrue);
      expect(calls.first, 'POST /v1/shield/captcha/init');
    });

    test('未登录时取链给出明确中文提示，不发请求', () async {
      final resolver = XunleiResolver();
      var requested = 0;
      final client = MockClient((request) async {
        requested++;
        return jsonResponse('{}');
      });
      await expectLater(
        resolver.downloadLink(session, file, cookie: '', client: client),
        throwsA(isA<ShareResolveException>().having(
          (e) => e.message,
          'message',
          contains('需要账号登录'),
        )),
      );
      expect(requested, 0);
    });

    test('游客列目录不带空 Bearer', () async {
      final resolver = XunleiResolver();
      final client = MockClient((request) async {
        expect(request.headers.containsKey('Authorization'), isFalse);
        return jsonResponse(
          '{"title":"演示","pass_code_token":"PCT",'
          '"files":[{"id":"f1","name":"a.bin","size":9,"kind":"drive#file"}]}',
          200,
        );
      });
      final created = await resolver.createSession(
        dummyShare(),
        cookie: '',
        client: client,
      );
      expect(created.title, '演示');
      expect(created.token, 'PCT');
    });

    test('提取码错误给出对应提示', () async {
      final resolver = XunleiResolver();
      final client = MockClient((request) async =>
          jsonResponse('{"share_status":"PASS_CODE_ERROR"}'));
      await expectLater(
        resolver.createSession(dummyShare(), cookie: '', client: client),
        throwsA(isA<ShareResolveException>()
            .having((e) => e.message, 'message', '提取码错误')),
      );
    });
  });
}
