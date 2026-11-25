import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/crypto/crypto_service.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

String _text(Uint8List b) => utf8.decode(b);

void main() {
  group('对称加密', () {
    final samples = <String>['hello', '中文内容 · 123', 'a' * 999];

    for (final kind in CipherKind.values) {
      test('${kind.label} 口令往返一致', () {
        for (final s in samples) {
          final enc = CryptoService.encrypt(
            kind: kind,
            password: 'p@ssw0rd-测试',
            data: _bytes(s),
          );
          expect(enc.sublist(0, 3), <int>[0x58, 0x4D, 0x54]);
          expect(_text(CryptoService.decrypt(kind: kind, password: 'p@ssw0rd-测试', data: enc)), s);
        }
      });
    }

    test('每次加密的 salt/iv 不同，密文不同', () {
      final a = CryptoService.encrypt(
        kind: CipherKind.aes256,
        password: 'same',
        data: _bytes('same'),
      );
      final b = CryptoService.encrypt(
        kind: CipherKind.aes256,
        password: 'same',
        data: _bytes('same'),
      );
      expect(a, isNot(equals(b)));
    });

    test('算法可自动识别', () {
      for (final kind in CipherKind.values) {
        final enc = CryptoService.encrypt(
          kind: kind,
          password: 'k',
          data: _bytes('x'),
        );
        expect(CryptoService.detectKind(enc), kind);
      }
    });

    test('口令错误时抛出可读异常', () {
      final enc = CryptoService.encrypt(
        kind: CipherKind.aes256,
        password: 'right',
        data: _bytes('secret'),
      );
      expect(
        () => CryptoService.decrypt(kind: CipherKind.aes256, password: 'wrong', data: enc),
        throwsA(isA<CryptoException>()),
      );
    });

    test('算法不匹配时提示实际算法', () {
      final enc = CryptoService.encrypt(
        kind: CipherKind.des,
        password: 'k',
        data: _bytes('x'),
      );
      expect(
        () => CryptoService.decrypt(kind: CipherKind.aes256, password: 'k', data: enc),
        throwsA(isA<CryptoException>()),
      );
    });

    test('非本工具密文被拒绝', () {
      expect(
        () => CryptoService.decrypt(kind: null, password: 'k', data: _bytes('not a payload')),
        throwsA(isA<CryptoException>()),
      );
    });

    test('空口令/空内容直接拒绝', () {
      expect(
        () => CryptoService.encrypt(kind: CipherKind.aes256, password: '', data: _bytes('x')),
        throwsA(isA<CryptoException>()),
      );
      expect(
        () => CryptoService.encrypt(kind: CipherKind.aes256, password: 'k', data: Uint8List(0)),
        throwsA(isA<CryptoException>()),
      );
    });
  });

  group('RSA', () {
    test('生成密钥对 → PEM 解析 → 加解密往返', () {
      final (privatePem, publicPem) = CryptoService.generateRsaKeyPair(bits: 1024);
      expect(privatePem, contains('BEGIN RSA PRIVATE KEY'));
      expect(publicPem, contains('BEGIN PUBLIC KEY'));

      // 公钥/私钥都能被解析回来，且模数一致
      final pub = CryptoService.parsePublicKey(publicPem);
      final pri = CryptoService.parsePrivateKey(privatePem);
      expect(pub.modulus, pri.modulus);

      final plain = _bytes('RSA payload 中文');
      final enc = CryptoService.rsaEncrypt(publicPem, plain);
      expect(_text(CryptoService.rsaDecrypt(privatePem, enc)), 'RSA payload 中文');
    });

    test('超长内容给出可读错误', () {
      final (_, publicPem) = CryptoService.generateRsaKeyPair(bits: 1024);
      expect(CryptoService.rsaMaxBytes(publicPem), greaterThan(0));
      final tooLong = Uint8List(CryptoService.rsaMaxBytes(publicPem) + 10);
      expect(
        () => CryptoService.rsaEncrypt(publicPem, tooLong),
        throwsA(isA<CryptoException>()),
      );
    });

    test('PEM 内容非法时报错', () {
      expect(
        () => CryptoService.parsePublicKey('not a pem'),
        throwsA(isA<CryptoException>()),
      );
    });
  });

  group('哈希', () {
    test('标准测试向量', () {
      expect(
        CryptoService.hashBytes(_bytes('abc'), HashKind.md5),
        '900150983cd24fb0d6963f7d28e17f72',
      );
      expect(
        CryptoService.hashBytes(_bytes('abc'), HashKind.sha1),
        'a9993e364706816aba3e25717850c26c9cd0d89d',
      );
      expect(
        CryptoService.hashBytes(_bytes('abc'), HashKind.sha256),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        CryptoService.hashBytes(_bytes(''), HashKind.sha512),
        'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce'
            '47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e',
      );
    });

    test('HMAC-SHA256 与 RFC 4231 用例一致', () {
      // RFC 4231 Test Case 1：key = 0x0b * 20, data = "Hi There"
      final key = String.fromCharCodes(List<int>.filled(20, 0x0b));
      expect(
        CryptoService.hmacBytes(_bytes('Hi There'), key, HashKind.sha256),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
      );
    });
  });
}
