import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/link_parser/c139_resolver.dart';
import 'package:toolbox/features/tools/link_parser/share_link.dart';

void main() {
  group('网盘分享识别', () {
    test('夸克与 UC：链接短码 + 文案提取码', () {
      final quark = ShareLinkParser.parse(
        '复制这段 https://pan.quark.cn/s/abc123 打开夸克网盘，提取码：xy12',
      );
      expect(quark?.platform, SharePlatform.quark);
      expect(quark?.shareId, 'abc123');
      expect(quark?.pwd, 'xy12');

      final uc = ShareLinkParser.parse('https://drive.uc.cn/s/UC987?pwd=a1b2');
      expect(uc?.platform, SharePlatform.uc);
      expect(uc?.shareId, 'UC987');
      expect(uc?.pwd, 'a1b2');
    });

    test('百度 surl 去掉开头 1，139 识别 shareweb 路径', () {
      final baidu =
          ShareLinkParser.parse('https://pan.baidu.com/s/1AbC-123?pwd=9z8y');
      expect(baidu?.platform, SharePlatform.baidu);
      expect(baidu?.shareId, 'AbC-123');
      expect(baidu?.pwd, '9z8y');

      final c139 = ShareLinkParser.parse(
        'https://yun.139.com/shareweb/#/w/i/abcDEF-01 提取码: 3388',
      );
      expect(c139?.platform, SharePlatform.c139);
      expect(c139?.shareId, 'abcDEF-01');
      expect(c139?.pwd, '3388');
    });

    test('115 口令式链接与蓝奏域名族', () {
      final command =
          ShareLinkParser.parse('https://115.com/sws8lxs36jf-n307/');
      expect(command?.platform, SharePlatform.pan115);
      expect(command?.shareId, 'sws8lxs36jf');
      expect(command?.pwd, 'n307');

      final lanzou =
          ShareLinkParser.parse('https://wwx.lanzn.com/iXnuF4c8sqmb');
      expect(lanzou?.platform, SharePlatform.lanzou);
      expect(lanzou?.shareId, 'iXnuF4c8sqmb');
    });

    test('普通视频链接不被误判成网盘', () {
      expect(ShareLinkParser.parse('https://b23.tv/abcd'), isNull);
      expect(ShareLinkParser.parse('随便一段文字'), isNull);
    });
  });

  group('139 凭证提取', () {
    const raw = 'authorization=Basic YXBwOjEzOTo=; '
        'Os_SSo_Sid=SID; RMKEY=KEY; track=xxx; '
        'ORCHES-I-ACCOUNT-ENCRYPT=MTM4MDAwMDAwMDA=; Login_UserNumber=13800000000';

    test('只保留协议白名单字段', () {
      final cookies = ShareLinkParser.c139Cookies(raw);
      expect(cookies, contains('Os_SSo_Sid=SID'));
      expect(cookies, contains('RMKEY=KEY'));
      expect(cookies, isNot(contains('track')));
    });

    test('账号优先取 base64 完整手机号', () {
      expect(
        ShareLinkParser.c139Account(raw),
        '13800000000',
      );
    });
  });

  group('139 加密与签名', () {
    test('AES-CBC body 可往返，且每次 IV 不同', () {
      const plain = '{"getOutLinkInfoReq":{"linkID":"abc"}}';
      final first = C139Resolver.encryptBody(plain);
      final second = C139Resolver.encryptBody(plain);
      expect(first, isNot(second));
      expect(C139Resolver.decryptBody(first), plain);
      expect(C139Resolver.decryptBody(second), plain);
    });

    test('mcloud-sign 是 32 位大写十六进制且随随机串变化', () {
      final a = C139Resolver.calSign('{"a":1}', '2026-01-01 00:00:00', 'rand1');
      final b = C139Resolver.calSign('{"a":1}', '2026-01-01 00:00:00', 'rand2');
      expect(a.length, 32);
      expect(a, matches(RegExp(r'^[0-9A-F]{32}$')));
      expect(a, isNot(b));
    });
  });
}
