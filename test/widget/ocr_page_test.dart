import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/platform/ocr.dart';
import 'package:toolbox/features/tools/ocr/ocr_page.dart';
import '../support/test_env.dart';

OcrResult sampleResult() => OcrResult.fromMap(<String, dynamic>{
      'text': '第一行\n第二行',
      'lines': <Map<String, dynamic>>[
        <String, dynamic>{
          'text': '第二行',
          'left': 0,
          'top': 32,
          'width': 60,
          'height': 20,
        },
        <String, dynamic>{
          'text': '第一行',
          'left': 0,
          'top': 10,
          'width': 60,
          'height': 20,
        },
      ],
    });

void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  tearDown(restoreSystemLanguage);

  testWidgets('选图后按行坐标还原文本，可复制与保存', (tester) async {
    OcrImageSource? source;
    String? saved;
    await tester.pumpWidget(MaterialApp(
      home: OcrPage(
        picker: (picked) async {
          source = picked;
          return '/no/such/image.png';
        },
        recognizer: (path) async => sampleResult(),
        saver: (text) async {
          saved = text;
          return 'OCR_test.txt';
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ocr-camera')), findsOneWidget);
    expect(find.byKey(const ValueKey('ocr-gallery')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ocr-result')))
          .controller!
          .text,
      isEmpty,
    );

    await tester.tap(find.byKey(const ValueKey('ocr-gallery')));
    await tester.pumpAndSettle();

    expect(source, OcrImageSource.gallery);
    final field =
        tester.widget<TextField>(find.byKey(const ValueKey('ocr-result')));
    // 行坐标排序后自上而下，行距很小不分段。
    expect(field.controller!.text, '第一行\n第二行');
    expect(find.text('2 行'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('ocr-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ocr-save')));
    await tester.pumpAndSettle();
    expect(saved, '第一行\n第二行');
    expect(find.text('已保存到存储空间：OCR_test.txt'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('ocr-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ocr-clear')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ocr-result')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('识别不到文字时给出提示，异常走错误文案', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OcrPage(
        picker: (_) async => '/no/such/image.png',
        recognizer: (_) async => const OcrResult(text: '', lines: <OcrLine>[]),
        saver: (_) async => 'unused.txt',
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ocr-camera')));
    await tester.pumpAndSettle();
    expect(find.text('没有识别到文字，试试更清晰的图片'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
      home: OcrPage(
        picker: (_) async => '/no/such/image.png',
        recognizer: (_) async => throw StateError('engine down'),
        saver: (_) async => 'unused.txt',
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ocr-camera')));
    await tester.pumpAndSettle();
    expect(find.textContaining('识别失败'), findsOneWidget);
  });

  test('OCR 段落还原：行距明显变大时分两段', () {
    final text = assembleOcrText(<OcrLine>[
      const OcrLine(text: '标题', left: 0, top: 10, width: 60, height: 20),
      const OcrLine(text: '正文一', left: 0, top: 100, width: 60, height: 20),
      const OcrLine(text: '正文二', left: 0, top: 122, width: 60, height: 20),
    ]);
    expect(text, '标题\n\n正文一\n正文二');
  });
}
