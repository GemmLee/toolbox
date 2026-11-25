import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/crypto/crypto_page.dart';
import '../support/test_env.dart';

void _usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pump(WidgetTester tester) async {
  _usePhoneViewport(tester);
  await tester.pumpWidget(const MaterialApp(home: CryptoPage()));
  await tester.pumpAndSettle();
}

void main() {
  installCleanEnv();

  testWidgets('加密页展示算法选项与口令输入', (tester) async {
    await _pump(tester);

    expect(find.text('加密'), findsWidgets);
    expect(find.text('解密'), findsOneWidget);
    expect(find.text('哈希'), findsOneWidget);
    for (final label in <String>['AES-128', 'AES-256', 'AES-GCM', 'DES', 'RSA']) {
      expect(find.text(label), findsWidgets, reason: '缺少算法 $label');
    }
    expect(find.byKey(const ValueKey('crypto-password')), findsOneWidget);
    expect(find.byKey(const ValueKey('crypto-plain-input')), findsOneWidget);
  });

  testWidgets('选 RSA 后口令换成公钥与生成密钥对', (tester) async {
    await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('crypto-mode-rsa')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('crypto-public-pem')), findsOneWidget);
    expect(find.byKey(const ValueKey('crypto-password')), findsNothing);
    expect(find.text('生成密钥对'), findsOneWidget);
  });

  testWidgets('解密页可切到文件输入，哈希页有 HMAC 密钥', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('解密'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('crypto-cipher-input')), findsOneWidget);
    expect(find.text('自动识别对称算法'), findsOneWidget);

    await tester.tap(find.text('哈希'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hash-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('hash-hmac-key')), findsOneWidget);
  });
}
