import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/platform/file_import_bridge.dart';
import 'package:toolbox/core/storage/app_files.dart';
import 'package:toolbox/features/tools/text_reader/document_view.dart';
import 'package:toolbox/features/tools/text_reader/reader_view_page.dart';
import 'package:toolbox/features/tools/text_reader/text_reader_page.dart';

import '../support/test_env.dart';

/// 阅读区用 SelectableText / SelectableText.rich，find.text 取不到 TextSpan，
/// 这里把所有可选文本拼成纯文本后再断言。
String plainTextOf(WidgetTester tester) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .map((w) => w.textSpan?.toPlainText() ?? w.data ?? '')
    .join('\n');

/// widget 测试跑在 FakeAsync 下，dart:io 的异步回调无法在 pumpAndSettle 期间完成，
/// 会让加载中的 CircularProgressIndicator 一直转。列表/内容读取一律用同步 I/O
/// 包成纯 Dart Future；确实需要真实异步 I/O 的动作，用 runAsync 开一个真实事件循环窗口。
/// 只 pump 一帧，避免 pumpAndSettle 把 2 秒后自动消失的 SnackBar 一起快进掉。
Future<void> pumpAfterRealIo(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  await tester.pump();
}

void main() {
  late Directory root;

  setUp(() async {
    mockPrefs();
    await useChineseUi();
    root = await Directory.systemTemp.createTemp('reader_widget');
    AppStore.useRootForTest(root);
    FileImportBridge.instance.resetForTest();
  });

  tearDown(() async {
    FileImportBridge.instance.resetForTest();
    AppStore.useRootForTest(null);
    await restoreSystemLanguage();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// 同步写文件并返回 StoredFile，避免 widget 测试里的真实异步 I/O。
  StoredFile makeFile(String name, String content) {
    final dir = Directory('${root.path}/reader')..createSync(recursive: true);
    final file = File('${dir.path}/$name')..writeAsStringSync(content);
    final stat = file.statSync();
    return StoredFile(
      category: AppStoreCategory.reader,
      file: file,
      size: stat.size,
      modified: stat.modified,
    );
  }

  /// 同步扫描 reader 目录，作为页面的注入 loader。
  Future<List<StoredFile>> syncLoader() async {
    final dir = Directory('${root.path}/reader');
    if (!dir.existsSync()) return <StoredFile>[];
    return dir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => FileImportBridge.isSupported(f.path.split(Platform.pathSeparator).last))
        .map((f) {
          final stat = f.statSync();
          return StoredFile(
            category: AppStoreCategory.reader,
            file: f,
            size: stat.size,
            modified: stat.modified,
          );
        })
        .toList();
  }

  testWidgets('空态给出外部导入说明和手动选择入口', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TextReaderPage(loader: () async => const <StoredFile>[]),
    ));
    await tester.pumpAndSettle();

    expect(find.text('还没有文档'), findsOneWidget);
    expect(find.textContaining('用其他应用打开'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-empty-import')), findsOneWidget);
    expect(find.text('长按文件可删除'), findsOneWidget);
  });

  testWidgets('列表展示已导入文件，点击打开阅读页', (tester) async {
    makeFile('note.md', '# 标题\n\n正文');
    await tester.pumpWidget(MaterialApp(
      home: TextReaderPage(
        loader: syncLoader,
        contentLoader: (f) async => f.file.readAsStringSync(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('note.md'), findsOneWidget);
    await tester.tap(find.text('note.md'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderViewPage), findsOneWidget);
    expect(plainTextOf(tester), contains('标题'));
  });

  testWidgets('Markdown 默认渲染，可切换源码', (tester) async {
    const text = '# 标题\n\n正文 **加粗**\n\n- A\n- B';
    final file = makeFile('note.md', text);
    await tester.pumpWidget(MaterialApp(
      home: ReaderViewPage(file: file, contentLoader: (_) async => text),
    ));
    await tester.pumpAndSettle();

    final rendered = plainTextOf(tester);
    expect(rendered, contains('标题'));
    expect(rendered, contains('加粗'));
    expect(rendered.contains('**加粗**'), isFalse);

    await tester.tap(find.byKey(const ValueKey('reader-mode')));
    await tester.pumpAndSettle();
    expect(plainTextOf(tester), contains('**加粗**'));
  });

  testWidgets('JSON 默认格式化，可切回原文', (tester) async {
    const text = '{"a":1,"b":["x",true]}';
    final file = makeFile('data.json', text);
    await tester.pumpWidget(MaterialApp(
      home: ReaderViewPage(file: file, contentLoader: (_) async => text),
    ));
    await tester.pumpAndSettle();

    expect(plainTextOf(tester), contains('"a": 1'));
    await tester.tap(find.byKey(const ValueKey('reader-mode')));
    await tester.pumpAndSettle();
    expect(plainTextOf(tester), contains('{"a":1'));
  });

  testWidgets('非法 JSON 提示后按原文显示', (tester) async {
    const text = '{oops';
    final file = makeFile('bad.json', text);
    await tester.pumpWidget(MaterialApp(
      home: ReaderViewPage(file: file, contentLoader: (_) async => text),
    ));
    await tester.pumpAndSettle();

    expect(find.text('JSON 格式有误，已按原文显示'), findsOneWidget);
    expect(plainTextOf(tester), contains('{oops'));
  });

  testWidgets('Markdown 表格渲染成表格且不丢单元格', (tester) async {
    const text = '| 项目 | 数值 |\n|:--|--:|\n| 身高 | 170 |\n| 体重 | 60 |';
    final file = makeFile('table.md', text);
    await tester.pumpWidget(MaterialApp(
      home: ReaderViewPage(file: file, contentLoader: (_) async => text),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Table), findsOneWidget);
    final rendered = plainTextOf(tester);
    for (final cell in <String>['项目', '数值', '身高', '170', '体重', '60']) {
      expect(rendered, contains(cell));
    }
    // 表格源码里的竖线与分隔行不应作为正文出现。
    expect(rendered.contains('---'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长 JSON 全量展示，不再截断到 12 万字', (tester) async {
    final map = <String, Object>{
      for (var i = 0; i < 12000; i++) 'key$i': i,
    };
    final text = jsonEncode(map);
    final file = makeFile('big.json', text);
    await tester.pumpWidget(MaterialApp(
      home: ReaderViewPage(file: file, contentLoader: (_) async => text),
    ));
    await tester.pumpAndSettle();

    expect(text.length, greaterThan(120000));
    expect(find.textContaining('仅显示前'), findsNothing);
    expect(plainTextOf(tester), contains('"key0": 0'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('超大 JSON 走原文模式并提示', (tester) async {
    final text = jsonEncode(<String, Object>{
      for (var i = 0; i < 20000; i++) 'k$i': 'v' * 40,
    });
    final file = makeFile('huge.json', text);
    await tester.pumpWidget(MaterialApp(
      home: ReaderViewPage(file: file, contentLoader: (_) async => text),
    ));
    await tester.pumpAndSettle();

    expect(text.length, greaterThan(kJsonFormatLimit));
    expect(find.text('内容较大，已按原文显示'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑并保存会覆盖存储空间里的原文件', (tester) async {
    final file = makeFile('a.txt', 'hello');
    await tester.pumpWidget(MaterialApp(
      home: ReaderViewPage(
        file: file,
        contentLoader: (f) async => f.file.readAsStringSync(),
        contentSaver: (text) async => File(file.path).writeAsStringSync(text),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reader-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('reader-editor')),
      'world',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reader-save')));
    // 只 pump 一帧：SnackBar 2 秒后自动消失，pumpAndSettle 会把它快进掉。
    await tester.pump();

    expect(File(file.path).readAsStringSync(), 'world');
    expect(find.text('已保存'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-editor')), findsNothing);
  });

  testWidgets('列表含存储空间其他分类的可读文件，个人信息被排除', (tester) async {
    StoredFile at(AppStoreCategory category, String name, String content) {
      final dir = Directory('${root.path}/${category.id}')
        ..createSync(recursive: true);
      final file = File('${dir.path}/$name')..writeAsStringSync(content);
      final stat = file.statSync();
      return StoredFile(
        category: category,
        file: file,
        size: stat.size,
        modified: stat.modified,
      );
    }

    final files = <StoredFile>[
      at(AppStoreCategory.reader, 'imported.md', '# a'),
      at(AppStoreCategory.quiz, '题库备份.json', '{}'),
      at(AppStoreCategory.assistant, '题库转换.md', '# b'),
      at(AppStoreCategory.profile, 'profile.json', '{}'),
      at(AppStoreCategory.other, 'image.png', 'x'),
    ];

    await tester.pumpWidget(MaterialApp(
      home: TextReaderPage(loader: () async => files),
    ));
    await tester.pumpAndSettle();

    expect(find.text('imported.md'), findsOneWidget);
    expect(find.text('题库备份.json'), findsOneWidget);
    expect(find.text('题库转换.md'), findsOneWidget);
    // 个人信息档案不允许在阅读器里改，非文本格式也不列。
    expect(find.text('profile.json'), findsNothing);
    expect(find.text('image.png'), findsNothing);
  });

  testWidgets('保存写回文件原本所在分类，不会另存一份', (tester) async {
    final dir = Directory('${root.path}/quiz')..createSync(recursive: true);
    final original = File('${dir.path}/bank.json')..writeAsStringSync('{"a":1}');
    final file = StoredFile(
      category: AppStoreCategory.quiz,
      file: original,
      size: original.statSync().size,
      modified: original.statSync().modified,
    );

    await tester.pumpWidget(MaterialApp(
      home: ReaderViewPage(
        file: file,
        contentLoader: (f) async => f.file.readAsStringSync(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reader-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('reader-editor')),
      '{"a":2}',
    );
    await tester.pump();
    // 默认保存走真实异步 I/O，需要真实事件循环窗口。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('reader-save')));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();

    expect(original.readAsStringSync(), '{"a":2}');
    expect(Directory('${root.path}/reader').existsSync(), isFalse,
        reason: '不应在 reader 分类另存一份');
  });

  testWidgets('长按列表项可删除文件', (tester) async {
    makeFile('del.txt', 'x');
    await tester.pumpWidget(MaterialApp(
      home: TextReaderPage(loader: syncLoader),
    ));
    await tester.pumpAndSettle();

    expect(find.text('del.txt'), findsOneWidget);
    await tester.longPress(find.text('del.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await pumpAfterRealIo(tester);

    expect(find.text('del.txt'), findsNothing);
    expect(File('${root.path}/reader/del.txt').existsSync(), isFalse);
  });

  testWidgets('手动导入文件后列表立即刷新', (tester) async {
    final source = File('${root.path}/incoming.txt')
      ..writeAsStringSync('external');
    await tester.pumpWidget(MaterialApp(
      home: TextReaderPage(
        loader: syncLoader,
        importer: () async => <ReaderImportItem>[
          (path: source.path, name: 'incoming.txt', temporary: false),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    // 点击与 adoptPath 的真实文件复制都放进真实事件循环窗口，避免 FakeAsync
    // 卡住 dart:io 的连续异步回调。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('reader-import')));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();

    expect(find.text('incoming.txt'), findsOneWidget);
    expect(find.text('已导入 1 个文件'), findsOneWidget);
    expect(FileImportBridge.instance.takePendingOpen(), isNull);
  });

  testWidgets('外部导入通知会刷新列表', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TextReaderPage(loader: syncLoader),
    ));
    await tester.pumpAndSettle();
    expect(find.text('还没有文档'), findsOneWidget);

    final source = File('${root.path}/pushed.md')
      ..writeAsStringSync('# pushed');
    await tester.runAsync(
      () => FileImportBridge.instance.adoptPath(source.path, name: 'pushed.md'),
    );
    await tester.pumpAndSettle();

    expect(find.text('pushed.md'), findsOneWidget);
  });
}
