import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/core/storage/local_store.dart';
import 'package:toolbox/features/tools/watermark/watermark_font_store.dart';

typedef FontPick = Future<({List<int> bytes, String name})?> Function();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late List<String> registered;
  late FontPick pick;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('wm_fonts_test');
    registered = <String>[];
    pick = () async => (
          bytes: List<int>.filled(16, 1),
          name: 'my-font.ttf',
        );
  });

  tearDown(() async {
    await LocalStore.remove(WatermarkFontStore.storageKey);
    if (root.existsSync()) await root.delete(recursive: true);
  });

  WatermarkFontStore store() => WatermarkFontStore(
        picker: () => pick(),
        loader: (bytes, family) async => registered.add(family),
        rootLoader: () async => root,
      );

  test('导入后落盘、注册并可重新加载', () async {
    pick = () async => (
          bytes: List<int>.filled(16, 1),
          name: '我的字体.ttf',
        );
    final sut = store();
    final font = await sut.importFont();
    expect(font, isNotNull);
    expect(font!.name, '我的字体.ttf');
    expect(font.family, startsWith(WatermarkFontStore.familyPrefix));
    expect(File(font.path).existsSync(), isTrue);
    expect(registered, <String>[font.family]);

    final loaded = await sut.load();
    expect(loaded.length, 1);
    expect(loaded.single.family, font.family);

    registered.clear();
    await sut.registerAll();
    expect(registered, <String>[font.family]);
  });

  test('删除移除文件与偏好', () async {
    final sut = store();
    final font = await sut.importFont();
    expect(font, isNotNull);
    await sut.remove(font!);
    expect(await sut.load(), isEmpty);
    expect(File(font.path).existsSync(), isFalse);
  });

  test('取消选择返回 null，非法扩展名报错', () async {
    pick = () async => null;
    expect(await store().importFont(), isNull);

    pick = () async => (
          bytes: List<int>.filled(16, 1),
          name: 'bad.txt',
        );
    await expectLater(store().importFont(), throwsA(isA<StateError>()));
  });
}
