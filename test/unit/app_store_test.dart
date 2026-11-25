import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:toolbox/core/storage/app_files.dart';

/// 应用存储空间：分类目录、命名去重、重命名与删除。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('app_store_test');
    AppStore.useRootForTest(root);
  });

  tearDown(() async {
    AppStore.useRootForTest(null);
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('按分类落盘并可整体列出', () async {
    final file = await AppStore.saveText(
      category: AppStoreCategory.quiz,
      name: '题库.json',
      content: '{"a":1}',
    );
    expect(file.path, endsWith(p.join('quiz', '题库.json')));
    expect(file.name, '题库.json');

    await AppStore.saveText(
      category: AppStoreCategory.profile,
      name: '背景-1.jpg',
      content: 'img',
    );

    final all = await AppStore.list();
    expect(all.length, 2);
    expect((await AppStore.listOf(AppStoreCategory.quiz)).single.name, '题库.json');
    expect(await AppStore.usedBytes(AppStoreCategory.profile), 3);
  });

  test('同名自动加后缀，不覆盖已有文件', () async {
    await AppStore.saveText(
        category: AppStoreCategory.assistant, name: 'a.json', content: '1');
    final second = await AppStore.saveText(
        category: AppStoreCategory.assistant, name: 'a.json', content: '2');
    expect(second.name, 'a(2).json');
    expect((await AppStore.list()).length, 2);
  });

  test('非法字符被清理', () {
    // 先取 basename 去掉目录，再把路径 / 通配等非法字符换成下划线
    expect(AppStore.sanitizeName('a/b:c*?.json'), 'b_c__.json');
    expect(AppStore.sanitizeName('   '), '文件');
  });

  test('重命名与删除', () async {
    final file = await AppStore.saveText(
        category: AppStoreCategory.other, name: 'old.txt', content: 'x');
    final renamed = await AppStore.rename(file, 'new.txt');
    expect(renamed.name, 'new.txt');
    expect(File(file.path).existsSync(), isFalse);

    await expectLater(
      AppStore.rename(renamed, 'new.txt'),
      completes,
      reason: '改成同名直接返回，不报错',
    );

    await AppStore.saveText(
        category: AppStoreCategory.other, name: 'other.txt', content: 'y');
    await expectLater(
      AppStore.rename(renamed, 'other.txt'),
      throwsA(isA<FileSystemException>()),
    );

    await AppStore.delete(renamed);
    expect((await AppStore.list()).length, 1);
  });

  test('adopt 把外部文件复制进存储空间', () async {
    final source = File(p.join(root.path, 'incoming.json'));
    await source.writeAsString('{"x":1}');
    final stored = await AppStore.adopt(
      category: AppStoreCategory.quiz,
      source: source,
      name: '导入.json',
    );
    expect(stored.name, '导入.json');
    expect(await AppStore.readText(stored), '{"x":1}');
    expect(source.existsSync(), isTrue, reason: '原文件保留');
  });

  test('分类归属：个人信息独立，其余归存储文件', () {
    expect(AppStoreCategory.profile.group, '个人信息');
    expect(AppStoreCategory.quiz.group, '存储文件');
    expect(AppStoreCategory.assistant.group, '存储文件');
    expect(AppStoreCategory.other.group, '存储文件');
  });
}
