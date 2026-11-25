import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/link_parser/media_preview_page.dart';

import '../support/test_env.dart';

List<PreviewMedia> _images(int count) => <PreviewMedia>[
      for (var i = 1; i <= count; i++)
        PreviewMedia(url: 'https://img.example.com/$i.jpg', isVideo: false),
    ];

void main() {
  installCleanEnv();

  testWidgets('全屏预览：顶栏显示序号，左右翻页，下载交给回调', (tester) async {
    final downloaded = <PreviewMedia>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MediaPreviewPage(
          items: _images(3),
          onDownload: downloaded.add,
          caption: '三张图',
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('preview-index')), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preview-download')));
    expect(downloaded.single.url, 'https://img.example.com/1.jpg');

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preview-download')));
    expect(downloaded.last.url, 'https://img.example.com/2.jpg');
  });

  testWidgets('可以从指定下标打开（点第 3 张就停在第 3 张）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaPreviewPage(items: _images(4), initialIndex: 2),
      ),
    );
    await tester.pump();
    expect(find.text('3 / 4'), findsOneWidget);
  });

  testWidgets('图片加载失败时给出可操作的说明，不白屏', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: MediaPreviewPage(items: _images(1))),
    );
    // 测试环境没有网络：Image.network 会失败，errorBuilder 负责兜住。
    await tester.pumpAndSettle();
    expect(find.textContaining('没能加载出来'), findsOneWidget);
  });
}
