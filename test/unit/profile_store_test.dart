import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/core/storage/app_files.dart';
import 'package:toolbox/features/profile/profile_model.dart';
import 'package:toolbox/features/profile/profile_repository.dart';
import '../support/test_env.dart';

/// 个人信息应当同时落进「存储空间 › 个人信息 › 个人信息.json」。
Future<StoredFile?> _profileFile() async {
  for (final file in await AppStore.listOf(AppStoreCategory.profile)) {
    if (file.name == ProfileRepository.fileName) return file;
  }
  return null;
}

/// 清空 / 删除是后台执行的，轮询等它落盘。
///
/// 全量测试并行跑时机器负载高，2 s 会偶尔不够（曾在 CI 跑出过一次偶发失败），
/// 这里放宽到 5 s 并用 [fail] 给出可定位的原因。
Future<void> _waitGone() async {
  for (var i = 0; i < 250; i++) {
    if (await _profileFile() == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('个人信息文件在 5 s 内没有被删除');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    mockPrefs();
    root = await Directory.systemTemp.createTemp('profile_store_test');
    AppStore.useRootForTest(root);
  });

  tearDown(() async {
    AppStore.useRootForTest(null);
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('保存个人信息会写成存储空间里的个人信息.json', () async {
    await ProfileRepository.update((data) {
      data['gross'] = 20000;
      data['city'] = 'shanghai';
    });
    // save 的文件同步是后台任务，这里显式再同步一次，断言才稳定。
    await ProfileRepository.syncMirror();

    final file = await _profileFile();
    expect(file, isNotNull);
    expect(file!.category, AppStoreCategory.profile);

    final json =
        jsonDecode(await file.file.readAsString()) as Map<String, dynamic>;
    expect(json['schemaVersion'], 2);
    final salary = json['salary'] as Map<String, dynamic>;
    expect(salary['gross'], 20000);
    expect(salary['city'], 'shanghai');
  });

  test('结构化个人信息文件可以读回，并兼容 v1 扁平格式', () async {
    final original = UserProfile(<String, dynamic>{
      'city': 'hangzhou',
      'gross': 18000,
      'specialDeduction': 1500,
      'personal.pension': 8,
      'currentAge': 32,
    });
    final parsed = UserProfile.fromStorageJson(original.toStorageJson());
    expect(parsed.cityId, 'hangzhou');
    expect(parsed.gross, 18000);
    expect(parsed.specialDeduction, 1500);
    expect(parsed.personalRate('pension'), 8);
    expect(parsed.currentAge, 32);

    final legacy = UserProfile.fromStorageJson(<String, dynamic>{
      'schemaVersion': 1,
      'gross': 9000,
      'city': 'beijing',
    });
    expect(legacy.gross, 9000);
    expect(legacy.cityId, 'beijing');
  });

  test('清空个人信息会删掉存储空间里的文件', () async {
    await ProfileRepository.update((data) => data['gross'] = 12000);
    await ProfileRepository.syncMirror();
    expect(await _profileFile(), isNotNull);

    await ProfileRepository.clear();
    await _waitGone();
    expect(await ProfileRepository.load().then((p) => p.isEmpty), isTrue);
  });

  test('档案被清空时不会留下空的 JSON 文件', () async {
    await ProfileRepository.update((data) => data['gross'] = 9000);
    await ProfileRepository.syncMirror();
    expect(await _profileFile(), isNotNull);

    await ProfileRepository.save(UserProfile());
    await _waitGone();
  });

  test('旧版本存在 SharedPreferences 的数据会补写进存储空间', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'user_profile': jsonEncode(<String, dynamic>{'gross': 15000}),
    });

    await ProfileRepository.load();
    await ProfileRepository.syncMirror();

    final file = await _profileFile();
    expect(file, isNotNull);
    final json =
        jsonDecode(await file!.file.readAsString()) as Map<String, dynamic>;
    expect((json['salary'] as Map)['gross'], 15000);
  });

  test('工资计算器保存的文件可被导入读回', () async {
    await AppStore.saveText(
      category: AppStoreCategory.profile,
      name: ProfileRepository.fileName,
      content: jsonEncode(UserProfile(<String, dynamic>{
        'city': 'shenzhen',
        'gross': 26000,
        'employer.medical': 9.5,
      }).toStorageJson()),
      overwrite: true,
    );
    final loaded = await ProfileRepository.loadFromFile();
    expect(loaded, isNotNull);
    expect(loaded!.cityId, 'shenzhen');
    expect(loaded.gross, 26000);
    expect(loaded.employerRate('medical'), 9.5);
  });
}
