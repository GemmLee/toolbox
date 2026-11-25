import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 各网盘协议共用的摘要 / 对称加密小工具。
///
/// 全部是确定性纯函数，便于单测逐字节核对 YunX 参考实现。
class ShareCrypto {
  ShareCrypto._();

  static final MD5Digest _md5 = MD5Digest();
  static final SHA1Digest _sha1 = SHA1Digest();

  static String md5Hex(String text) =>
      md5Bytes(Uint8List.fromList(utf8.encode(text)));

  static String md5Bytes(Uint8List bytes) => _hex(_md5.process(bytes));

  /// SHA-1 → 小写 hex（迅雷 devicesign 用）。
  static String sha1Hex(String text) =>
      _hex(_sha1.process(Uint8List.fromList(utf8.encode(text))));

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// 标准 CRC-32（IEEE 802.3），与 Java CRC32 / zlib.crc32 一致。
  static int crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        final mask = (crc & 1) != 0 ? 0xEDB88320 : 0;
        crc = (crc >> 1) ^ mask;
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  /// CRC-32 → 小写十六进制（123 云盘签名用）。
  /// 与 Java `Long.toHexString` 一致：不补前导零。
  static String crc32Hex(String text) =>
      crc32(utf8.encode(text)).toRadixString(16);

  /// AES-ECB / PKCS7 加密 → 小写 hex（蓝奏优享的 AES_KEY 用）。
  static String aesEcbHex(String plain, String key) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      ECBBlockCipher(AESEngine()),
    );
    cipher.init(
      true,
      PaddedBlockCipherParameters(KeyParameter(utf8.encode(key)), null),
    );
    final out = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// AES-CBC / PKCS7 加密，随机 IV 前置，返回 base64(IV ‖ cipher)。
  static String aesCbcEncrypt(String plain, String key) {
    final iv = List<int>.generate(16, (_) => _nextByte());
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      true,
      PaddedBlockCipherParameters(
        ParametersWithIV(
          KeyParameter(utf8.encode(key)),
          Uint8List.fromList(iv),
        ),
        null,
      ),
    );
    final encrypted = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    return base64.encode(<int>[...iv, ...encrypted]);
  }

  /// AES-CBC / PKCS7 解密，输入 base64(IV ‖ cipher)。
  static String aesCbcDecrypt(String raw, String key) {
    final bytes = base64.decode(raw.trim());
    if (bytes.length < 32) return raw;
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      false,
      PaddedBlockCipherParameters(
        ParametersWithIV(
          KeyParameter(utf8.encode(key)),
          Uint8List.fromList(bytes.sublist(0, 16)),
        ),
        null,
      ),
    );
    final plain = cipher.process(Uint8List.fromList(bytes.sublist(16)));
    return utf8.decode(plain, allowMalformed: true);
  }

  static int _nextByte() => DateTime.now().microsecondsSinceEpoch.remainder(256);
}
