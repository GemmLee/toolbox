import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:barcode_widget/barcode_widget.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:toolbox/features/tools/qrcode/qr_page.dart';
import '../support/test_env.dart';

/// 手机竖屏尺寸（逻辑像素），避免 800x600 下二维码卡片落在折叠线以下。
void _usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2300);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpPage(WidgetTester tester) async {
  _usePhoneViewport(tester);
  await tester.pumpWidget(const MaterialApp(home: QrPage()));
  await tester.pumpAndSettle();
}

void main() {
  installCleanEnv();

  testWidgets('空内容时提示，输入后生成二维码', (tester) async {
    await _pumpPage(tester);

    expect(find.text('输入内容后自动生成'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('qr-input')),
      'https://example.com',
    );
    await tester.pumpAndSettle();

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('字符数 19'), findsOneWidget);
    expect(find.textContaining('字节数 19'), findsOneWidget);
  });

  testWidgets('中文按 UTF-8 字节计长', (tester) async {
    await _pumpPage(tester);

    await tester.enterText(find.byKey(const ValueKey('qr-input')), '你好');
    await tester.pumpAndSettle();

    expect(find.textContaining('字符数 2'), findsOneWidget);
    expect(find.textContaining('字节数 6'), findsOneWidget);
  });

  testWidgets('内容超长时显示错误提示，保存按钮禁用', (tester) async {
    await _pumpPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('qr-input')),
      '测' * 4000,
    );
    await tester.pumpAndSettle();

    expect(find.text('内容过长，无法生成二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    // FilledButton.icon 的真实类型是私有子类，find.byType 匹配不到，改用谓词。
    final save = tester.widget<FilledButton>(find
        .ancestor(
          of: find.text('保存图片'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        )
        .first);
    expect(save.onPressed, isNull);
  });

  testWidgets('复制内容会写剪贴板并提示', (tester) async {
    // 测试环境没有真实剪贴板，mock SystemChannels.platform 并记录调用。
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await _pumpPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('qr-input')),
      'XMtool',
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('复制内容'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制内容'));
    // 复制走剪贴板异步回调，需要多 pump 一次才能看到 SnackBar。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('已复制内容'), findsOneWidget);
    final copied = calls
        .where((c) => c.method == 'Clipboard.setData')
        .map((c) => (c.arguments as Map)['text'])
        .toList();
    expect(copied, <String>['XMtool']);
  });

  testWidgets('切换到一维码后渲染条码并可校验编码规则', (tester) async {
    await _pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('qr-kind-code128')));
    await tester.pumpAndSettle();
    expect(find.byType(BarcodeWidget), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('qr-input')),
      'ABC-12345',
    );
    await tester.pumpAndSettle();
    expect(find.byType(BarcodeWidget), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets('Data Matrix 生成正方形矩阵码', (tester) async {
    await _pumpPage(tester);

    final chip = find.byKey(const ValueKey('qr-kind-datamatrix'));
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('qr-input')), 'XM-2026');
    await tester.pumpAndSettle();

    // 矩阵码必须保持正方形，长宽不等会被拉开、扫不出来。
    final widget = tester.widget<BarcodeWidget>(find.byType(BarcodeWidget));
    expect(widget.width, widget.height);
  });

  testWidgets('EAN-13 位数不对时给出明确提示', (tester) async {
    await _pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('qr-kind-ean13')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('qr-input')), '123456');
    await tester.pumpAndSettle();

    expect(find.text('EAN-13 需要 13 位数字'), findsOneWidget);
    expect(find.byType(BarcodeWidget), findsNothing);
  });
}
