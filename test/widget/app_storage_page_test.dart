import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:toolbox/core/platform/file_share.dart';
import 'package:toolbox/core/storage/app_files.dart';
import 'package:toolbox/core/storage/cache_inventory.dart';
import 'package:toolbox/features/user/app_storage_page.dart';
import '../support/test_env.dart';

/// 存储空间页：分类分组与文件行展示。
///
/// 文件读写细节由 `app_store_test.dart` 覆盖；这里用注入的 loader
/// 只验证界面分组，避免 widget 测试里跑真实文件 I/O。
void main() {
  late Directory root;

  setUp(() async {
    mockPrefs();
    await useChineseUi();
    root = await Directory.systemTemp.createTemp('storage_page_test');
  });

  tearDown(() async {
    await restoreSystemLanguage();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  StoredFile makeFile(AppStoreCategory category, String name, int size) {
    final file = File('${root.path}/$name');
    file.writeAsStringSync('x' * size);
    return StoredFile(
      category: category,
      file: file,
      size: size,
      modified: DateTime.now(),
    );
  }

  testWidgets('按「个人信息 / 存储文件」分组展示文件', (tester) async {
    final files = <StoredFile>[
      makeFile(AppStoreCategory.profile, '背景-1.jpg', 2048),
      makeFile(AppStoreCategory.quiz, '题库备份.json', 512),
      makeFile(AppStoreCategory.assistant, '题库.json', 300),
    ];

    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(loader: () async => files),
    ));
    await tester.pumpAndSettle();

    expect(find.text('个人信息'), findsWidgets);
    expect(find.text('存储文件'), findsWidgets);
    expect(find.text('背景-1.jpg'), findsOneWidget);
    expect(find.text('题库备份.json'), findsOneWidget);
    expect(find.text('题库.json'), findsOneWidget);
    // 分类标签出现在文件副标题里
    expect(find.textContaining('刷题助手'), findsWidgets);
  });

  testWidgets('每个分类的文件都会落到某个分组里展示', (tester) async {
    // 回归用例：分组表漏掉某个分类时，文件只进「管理文件」计数却不显示。
    final files = <StoredFile>[
      for (final c in AppStoreCategory.values)
        makeFile(c, '${c.id}-文件.txt', 16),
    ];

    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(loader: () async => files),
    ));
    await tester.pumpAndSettle();

    for (final c in AppStoreCategory.values) {
      expect(
        find.text('${c.id}-文件.txt'),
        findsOneWidget,
        reason: '${c.label}（${c.id}）分类的文件必须可见',
      );
    }
  });

  testWidgets('没有任何文件时给出空分组提示', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(loader: () async => const <StoredFile>[]),
    ));
    await tester.pumpAndSettle();

    expect(find.text('个人信息'), findsWidgets);
    expect(find.textContaining('还没有个人资料文件'), findsOneWidget);
    expect(find.textContaining('还没有存储文件'), findsOneWidget);
  });

  // —— 多选管理 ——

  List<StoredFile> makeThree() => <StoredFile>[
        makeFile(AppStoreCategory.quiz, '一.json', 10),
        makeFile(AppStoreCategory.reader, '二.md', 20),
        makeFile(AppStoreCategory.other, '三.txt', 30),
      ];

  testWidgets('长按进入多选，可连续选中多个文件', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(loader: () async => makeThree()),
    ));
    await tester.pumpAndSettle();

    // 未选择时不显示操作栏和多选框。
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byKey(const ValueKey('storage-action-分享')), findsNothing);

    await tester.longPress(find.text('一.json'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(3));

    // 选择模式下单击即切换选中。
    await tester.tap(find.text('二.md'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);

    // 再点一次取消选中。
    await tester.tap(find.text('二.md'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);

    // 关闭按钮退出多选。
    await tester.tap(find.byTooltip('退出多选'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('全选 / 取消全选一次选中全部文件', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(loader: () async => makeThree()),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('一.json'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);

    await tester.tap(find.text('取消全选'));
    await tester.pumpAndSettle();
    // 全部取消后自动退出多选。
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('多选后一次性分享全部选中文件', (tester) async {
    final shared = <List<File>>[];
    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(
        loader: () async => makeThree(),
        sharer: (files) async {
          shared.add(files);
          return true;
        },
      ),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('一.json'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('二.md'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('storage-action-分享')));
    await tester.pumpAndSettle();

    expect(shared, hasLength(1));
    expect(
      shared.single.map((f) => p.basename(f.path)).toList()..sort(),
      <String>['一.json', '二.md'],
    );
  });

  testWidgets('多选后一次性导出到手机', (tester) async {
    final exported = <List<File>>[];
    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(
        loader: () async => makeThree(),
        exporter: (files) async {
          exported.add(files);
          return const FileExportResult(
            count: 2,
            failed: 0,
            dir: 'Download/XMtools',
          );
        },
      ),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('一.json'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('二.md'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('storage-action-导出到手机')));
    await tester.pumpAndSettle();

    expect(exported, hasLength(1));
    expect(exported.single, hasLength(2));
    expect(find.textContaining('已导出 2 个文件到 Download/XMtools'), findsOneWidget);
  });

  testWidgets('多选后一次性删除全部选中文件', (tester) async {
    final deleted = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(
        loader: () async => makeThree(),
        deleter: (file) async => deleted.add(file.name),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('一.json'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('二.md'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('storage-action-删除')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('确认删除选中的 2 个文件'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(deleted..sort(), <String>['一.json', '二.md']);
    expect(find.byType(Checkbox), findsNothing, reason: '删除后应退出多选');
  });

  List<CacheEntry> cacheEntries() => <CacheEntry>[
        const CacheEntry(
          id: 'runtime/image_cache',
          key: 'runtime/image_cache',
          tool: '系统',
          name: '运行时缓存',
          detail: '3 个文件 · 多为 .png',
          bytes: 512,
          kind: CacheKind.runtime,
        ),
        const CacheEntry(
          id: 'quiz-ai',
          tool: '刷题助手',
          name: 'AI 解析缓存',
          detail: '10 条解析',
          bytes: 2048,
          kind: CacheKind.quizAi,
        ),
      ];

  testWidgets('点击缓存卡片看明细，按占用从大到小排列并可单独清理', (tester) async {
    var loads = 0;
    final cleaned = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(
        loader: () async {
          loads++;
          return makeThree();
        },
        cacheLoader: () async => cacheEntries(),
        cacheItemCleaner: (entry) async {
          cleaned.add(entry.id);
          return entry.bytes;
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(loads, 1);

    await tester.tap(find.byKey(const ValueKey('storage-cache-tile')));
    await tester.pumpAndSettle();

    expect(find.text('缓存明细'), findsOneWidget);
    expect(find.byKey(const ValueKey('cache-entry-quiz-ai')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('cache-entry-quiz-ai'))).dy,
      lessThan(
        tester
            .getTopLeft(
                find.byKey(const ValueKey('cache-entry-runtime/image_cache')))
            .dy,
      ),
      reason: '占用大的缓存要排在前面',
    );

    await tester.tap(
      find.byKey(const ValueKey('cache-clean-runtime/image_cache')),
    );
    await tester.pumpAndSettle();

    expect(cleaned, <String>['runtime/image_cache']);
    expect(
      find.byKey(const ValueKey('cache-entry-runtime/image_cache')),
      findsNothing,
    );
    expect(loads, 2, reason: '单项清理后要刷新存储统计');
  });

  testWidgets('缓存明细可一次清理全部，取消则不清理', (tester) async {
    final cleaned = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(
        loader: () async => makeThree(),
        cacheLoader: () async => cacheEntries(),
        cacheItemCleaner: (entry) async {
          cleaned.add(entry.id);
          return entry.bytes;
        },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('storage-cache-tile')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('cache-clean-all')));
    await tester.pumpAndSettle();
    expect(find.textContaining('将清除全部缓存项'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(cleaned, isEmpty);

    await tester.tap(find.byKey(const ValueKey('cache-clean-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清理'));
    await tester.pumpAndSettle();
    expect(cleaned..sort(), <String>['quiz-ai', 'runtime/image_cache']);
    expect(find.text('暂无可清理缓存'), findsOneWidget);
  });

  testWidgets('单文件菜单可以分享到其他应用', (tester) async {
    final shared = <List<File>>[];
    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(
        loader: () async => makeThree(),
        sharer: (files) async {
          shared.add(files);
          return true;
        },
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('分享'));
    await tester.pumpAndSettle();

    expect(shared, hasLength(1));
    expect(shared.single, hasLength(1));
  });

  testWidgets('窄屏下四列统计不溢出', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(320, 640));
    final files = <StoredFile>[
      makeFile(AppStoreCategory.quiz, '题库备份.json', 12345678),
    ];
    await tester.pumpWidget(MaterialApp(
      home: AppStoragePage(loader: () async => files),
    ));
    await tester.pumpAndSettle();

    expect(find.text('管理文件'), findsOneWidget);
    expect(find.text('文件占用'), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-cache-tile')), findsOneWidget);
    // 统计卡片压到「一行四列 + 一行按钮」，不再占掉屏幕三分之一。
    expect(
      tester.getSize(find.byType(Card).first).height,
      lessThan(120),
      reason: '使用情况卡片要保持紧凑',
    );
  });
}
