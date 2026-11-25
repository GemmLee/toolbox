import 'crypto_service.dart';

/// 页面上的算法选项（RSA 与对称算法并列展示）。
enum CryptoMode {
  aes128('AES-128', 'CBC · PKCS7', CipherKind.aes128),
  aes256('AES-256', 'CBC · PKCS7', CipherKind.aes256),
  gcm('AES-GCM', '认证加密', CipherKind.aesGcm),
  des('DES', 'CBC · PKCS7', CipherKind.des),
  rsa('RSA', 'OAEP-SHA256', null);

  const CryptoMode(this.label, this.detail, this.kind);

  final String label;
  final String detail;

  /// 对称算法对应的实现；RSA 为 null。
  final CipherKind? kind;

  bool get isRsa => this == CryptoMode.rsa;

  bool get needsPassword => !isRsa;

  /// 从密文中识别出的对称算法反查页面选项。
  static CryptoMode? fromKind(CipherKind kind) {
    for (final m in CryptoMode.values) {
      if (m.kind == kind) return m;
    }
    return null;
  }
}
