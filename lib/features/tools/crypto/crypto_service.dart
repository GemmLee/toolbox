import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';

/// 加密/解密过程中的可读错误。
class CryptoException implements Exception {
  CryptoException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 支持的对称算法。
enum CipherKind {
  aes128('AES-128-CBC', 16),
  aes256('AES-256-CBC', 32),
  aesGcm('AES-256-GCM', 32),
  des('DES-CBC', 8);

  const CipherKind(this.label, this.keyLength);

  final String label;
  final int keyLength;

  int get code => index + 1;

  bool get isGcm => this == CipherKind.aesGcm;

  bool get isDes => this == CipherKind.des;

  static CipherKind? fromCode(int code) {
    for (final k in CipherKind.values) {
      if (k.code == code) return k;
    }
    return null;
  }
}

/// 加密结果的容器：
/// `XMT` + 版本 + 算法码 + salt(16) + iv(12/16) + 密文
class _Payload {
  static const List<int> magic = <int>[0x58, 0x4D, 0x54]; // XMT
  static const int version = 1;
  static const int saltLen = 16;

  _Payload({
    required this.kind,
    required this.salt,
    required this.iv,
    required this.cipherText,
  });

  final CipherKind kind;
  final Uint8List salt;
  final Uint8List iv;
  final Uint8List cipherText;

  Uint8List encode() {
    final out = BytesBuilder(copy: false)
      ..add(magic)
      ..addByte(version)
      ..addByte(kind.code)
      ..add(salt)
      ..add(iv)
      ..add(cipherText);
    return out.toBytes();
  }

  static _Payload decode(Uint8List bytes) {
    if (bytes.length < 4 + 1 + 16 + 12) {
      throw CryptoException('密文格式不正确或已被截断');
    }
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        throw CryptoException('不是本工具生成的密文（缺少 XMT 标识）');
      }
    }
    if (bytes[3] != version) {
      throw CryptoException('不支持的密文版本：${bytes[3]}');
    }
    final kind = CipherKind.fromCode(bytes[4]);
    if (kind == null) throw CryptoException('密文中的算法标识无效');
    final ivLen = kind.isGcm ? 12 : (kind.isDes ? 8 : 16);
    final header = 5 + saltLen + ivLen;
    if (bytes.length <= header) throw CryptoException('密文内容为空');
    return _Payload(
      kind: kind,
      salt: Uint8List.sublistView(bytes, 5, 5 + saltLen),
      iv: Uint8List.sublistView(bytes, 5 + saltLen, header),
      cipherText: Uint8List.sublistView(bytes, header),
    );
  }
}

/// 加解密服务：对称（口令派生密钥）+ 非对称（RSA PEM）。
class CryptoService {
  CryptoService._();

  static const int _iterations = 20000;

  // ---------------- 对称 ----------------

  /// 加密；结果自带算法标识与 salt/iv，解密时无需再记这些参数。
  static Uint8List encrypt({
    required CipherKind kind,
    required String password,
    required Uint8List data,
  }) {
    if (password.isEmpty) throw CryptoException('请先填写口令');
    if (data.isEmpty) throw CryptoException('内容为空');
    final salt = _randomBytes(_Payload.saltLen);
    final iv = _randomBytes(kind.isGcm ? 12 : (kind.isDes ? 8 : 16));
    final key = _deriveKey(password, salt, kind.keyLength);
    final cipherText = _runCipher(
      kind: kind,
      encrypting: true,
      key: key,
      iv: iv,
      data: data,
    );
    return _Payload(
      kind: kind,
      salt: salt,
      iv: iv,
      cipherText: cipherText,
    ).encode();
  }

  /// 解密；[kind] 为 null 表示按密文里的标识自动识别。
  static Uint8List decrypt({
    CipherKind? kind,
    required String password,
    required Uint8List data,
  }) {
    if (password.isEmpty) throw CryptoException('请先填写口令');
    final payload = _Payload.decode(data);
    if (kind != null && kind != payload.kind) {
      throw CryptoException('算法不匹配：密文使用 ${payload.kind.label} 加密');
    }
    final key = _deriveKey(password, payload.salt, payload.kind.keyLength);
    try {
      return _runCipher(
        kind: payload.kind,
        encrypting: false,
        key: key,
        iv: payload.iv,
        data: payload.cipherText,
      );
    } catch (_) {
      throw CryptoException('解密失败：口令错误或密文已损坏');
    }
  }

  /// 识别密文使用的算法（读不到返回 null）。
  static CipherKind? detectKind(Uint8List data) {
    try {
      return _Payload.decode(data).kind;
    } catch (_) {
      return null;
    }
  }

  static Uint8List _runCipher({
    required CipherKind kind,
    required bool encrypting,
    required Uint8List key,
    required Uint8List iv,
    required Uint8List data,
  }) {
    if (kind.isGcm) {
      final gcm = GCMBlockCipher(AESEngine())
        ..init(
          encrypting,
          AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
        );
      return gcm.process(data);
    }
    // pointycastle 没有单 DES 引擎：DES-EDE 在 K1=K2=K3 时等价于单 DES，
    // 所以把 8 字节密钥重复三份喂给 DESedeEngine，得到的就是标准 DES-CBC。
    final engine = kind.isDes ? DESedeEngine() : AESEngine();
    final keyBytes = kind.isDes ? _expandDesKey(key) : key;
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(engine),
    )
      ..init(
        encrypting,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(KeyParameter(keyBytes), iv),
          null,
        ),
      );
    return cipher.process(data);
  }

  /// 8 字节 DES 密钥 → 24 字节 K|K|K。
  static Uint8List _expandDesKey(Uint8List key) {
    final out = Uint8List(24);
    for (var i = 0; i < 3; i++) {
      out.setRange(i * 8, i * 8 + 8, key);
    }
    return out;
  }

  static Uint8List _deriveKey(String password, Uint8List salt, int length) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _iterations, length));
    return derivator.process(Uint8List.fromList(utf8.encode(password)));
  }

  static Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => rnd.nextInt(256)),
    );
  }

  // ---------------- RSA ----------------

  /// 用公钥（PEM）加密，返回密文字节。
  static Uint8List rsaEncrypt(String publicPem, Uint8List data) {
    final key = parsePublicKey(publicPem);
    final engine = OAEPEncoding.withSHA256(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(key));
    try {
      return engine.process(data);
    } catch (_) {
      throw CryptoException('加密失败：内容可能超过该密钥可加密的最大长度');
    }
  }

  /// 用私钥（PEM）解密。
  static Uint8List rsaDecrypt(String privatePem, Uint8List data) {
    final key = parsePrivateKey(privatePem);
    final engine = OAEPEncoding.withSHA256(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(key));
    try {
      return engine.process(data);
    } catch (_) {
      throw CryptoException('解密失败：私钥不匹配或密文已损坏');
    }
  }

  /// RSA 可加密的最大字节数（OAEP-SHA256：k - 2*hLen - 2）。
  static int rsaMaxBytes(String publicPem) {
    final key = parsePublicKey(publicPem);
    return key.modulus!.bitLength ~/ 8 - 66;
  }

  /// 生成密钥对，返回 (privatePem, publicPem)。
  static (String, String) generateRsaKeyPair({int bits = 2048}) {
    final random = FortunaRandom()
      ..seed(KeyParameter(_randomBytes(32)));
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
          random,
        ),
      );
    final pair = generator.generateKeyPair();
    final private = pair.privateKey as RSAPrivateKey;
    final public = pair.publicKey as RSAPublicKey;
    return (_encodePrivatePem(private), _encodePublicPem(public));
  }

  static RSAPublicKey parsePublicKey(String pem) {
    final der = _pemToDer(pem);
    final top = ASN1Parser(der).nextObject();
    if (top is ASN1Sequence) {
      final items = top.elements;
      // SubjectPublicKeyInfo：SEQUENCE { AlgorithmIdentifier, BIT STRING }
      if (items.length >= 2 && items[1] is ASN1BitString) {
        final bitString = items[1] as ASN1BitString;
        final inner = ASN1Parser(Uint8List.fromList(bitString.stringValue))
            .nextObject();
        if (inner is ASN1Sequence) return _publicFromSequence(inner);
      }
      // PKCS#1 RSAPublicKey：SEQUENCE { modulus, exponent }
      if (items.length >= 2 &&
          items[0] is ASN1Integer &&
          items[1] is ASN1Integer) {
        return _publicFromSequence(top);
      }
    }
    throw CryptoException('无法识别的公钥格式（支持 PKCS#1 / X.509 PEM）');
  }

  static RSAPrivateKey parsePrivateKey(String pem) {
    final der = _pemToDer(pem);
    final top = ASN1Parser(der).nextObject();
    if (top is ASN1Sequence) {
      final items = top.elements;
      // PKCS#1：9 个整数
      if (items.length >= 9 && items[0] is ASN1Integer) {
        return _privateFromSequence(top);
      }
      // PKCS#8：version, AlgorithmIdentifier, OCTET STRING(PKCS#1)
      if (items.length >= 3 && items[2] is ASN1OctetString) {
        final octets = (items[2] as ASN1OctetString).octets;
        final inner = ASN1Parser(octets).nextObject();
        if (inner is ASN1Sequence) return _privateFromSequence(inner);
      }
    }
    throw CryptoException('无法识别的私钥格式（支持 PKCS#1 / PKCS#8 PEM）');
  }

  static RSAPublicKey _publicFromSequence(ASN1Sequence seq) {
    final items = seq.elements;
    final n = (items[0] as ASN1Integer).valueAsBigInteger;
    final e = (items[1] as ASN1Integer).valueAsBigInteger;
    return RSAPublicKey(n, e);
  }

  static RSAPrivateKey _privateFromSequence(ASN1Sequence seq) {
    final items = seq.elements;
    if (items.length < 9) throw CryptoException('私钥内容不完整');
    BigInt at(int i) => (items[i] as ASN1Integer).valueAsBigInteger;
    // pointycastle 只需要 n / d / p / q，dP、dQ、qInv 由 p、q 推算
    return RSAPrivateKey(at(1), at(3), at(4), at(5));
  }

  static Uint8List _pemToDer(String pem) {
    final match = RegExp(
      r'-----BEGIN [^-]+-----([\s\S]*?)-----END [^-]+-----',
    ).firstMatch(pem);
    final body = match == null ? pem : match.group(1)!;
    final cleaned = body.replaceAll(RegExp(r'\s'), '');
    if (cleaned.isEmpty) throw CryptoException('密钥内容为空');
    try {
      return base64Decode(cleaned);
    } catch (_) {
      throw CryptoException('密钥不是有效的 PEM（Base64 解析失败）');
    }
  }

  static String _encodePrivatePem(RSAPrivateKey key) {
    final p = key.p!;
    final q = key.q!;
    final d = key.privateExponent!;
    final seq = ASN1Sequence()
      ..add(ASN1Integer.fromInt(0))
      ..add(ASN1Integer(key.modulus!))
      ..add(ASN1Integer(key.publicExponent!))
      ..add(ASN1Integer(d))
      ..add(ASN1Integer(p))
      ..add(ASN1Integer(q))
      ..add(ASN1Integer(d % (p - BigInt.one)))
      ..add(ASN1Integer(d % (q - BigInt.one)))
      ..add(ASN1Integer(q.modInverse(p)));
    return _pemWrap('RSA PRIVATE KEY', seq.encodedBytes);
  }

  static String _encodePublicPem(RSAPublicKey key) {
    final rsaSeq = ASN1Sequence()
      ..add(ASN1Integer(key.modulus!))
      ..add(ASN1Integer(key.publicExponent!));
    final algorithm = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.1'))
      ..add(ASN1Null());
    final spki = ASN1Sequence()
      ..add(algorithm)
      ..add(ASN1BitString(rsaSeq.encodedBytes));
    return _pemWrap('PUBLIC KEY', spki.encodedBytes);
  }

  static String _pemWrap(String label, Uint8List der) {
    final b64 = base64Encode(der);
    final buffer = StringBuffer('-----BEGIN $label-----\n');
    for (var i = 0; i < b64.length; i += 64) {
      final end = (i + 64 < b64.length) ? i + 64 : b64.length;
      buffer.writeln(b64.substring(i, end));
    }
    buffer.write('-----END $label-----');
    return buffer.toString();
  }

  // ---------------- 哈希 ----------------

  /// 文本/字节摘要，返回小写十六进制。
  static String hashBytes(Uint8List data, HashKind kind) {
    final digest = kind.digest;
    return _hex(digest.process(data));
  }

  /// HMAC：块长随算法变化（SHA-512 为 128 字节），否则结果不符。
  static String hmacBytes(Uint8List data, String key, HashKind kind) {
    final mac = HMac(kind.digest, kind.blockSize)
      ..init(KeyParameter(Uint8List.fromList(utf8.encode(key))));
    return _hex(mac.process(data));
  }

  static String _hex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

/// 可计算的哈希算法。
enum HashKind {
  md5('MD5'),
  sha1('SHA-1'),
  sha256('SHA-256'),
  sha512('SHA-512');

  const HashKind(this.label);

  final String label;

  /// HMAC 的块长度（字节）。
  int get blockSize => this == HashKind.sha512 ? 128 : 64;

  Digest get digest => switch (this) {
        HashKind.md5 => MD5Digest(),
        HashKind.sha1 => SHA1Digest(),
        HashKind.sha256 => SHA256Digest(),
        HashKind.sha512 => SHA512Digest(),
      };
}
