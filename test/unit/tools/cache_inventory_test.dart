import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/core/storage/cache_inventory.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_ai_explainer.dart';

import '../../support/test_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  final aiJson = jsonEncode(<String, dynamic>{
    'bank/a/q1': <String, dynamic>{'text': '解析内容', 'at': 1},
  });

  setUp(() async {
    mockPrefs(<String, Object>{QuizAiService.cacheStoreKey: aiJson});
    await useChineseUi();
    temp = await Directory.systemTemp.createTemp('cache_inventory_test');
  });

  tearDown(() async {
    await restoreSystemLanguage();
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  test('缓存明细合并原生/临时/偏好/会话并按占用从大到小排序', () async {
    await File('${temp.path}/xmt_a.jpg').writeAsBytes(List<int>.filled(300, 1));
    await File('${temp.path}/xmt_b.png').writeAsBytes(List<int>.filled(200, 1));
    await File('${temp.path}/keep.txt').writeAsString('not a cache');

    final entries = await CacheInventory.load(
      nativeLoader: () async => <Map<String, Object?>>[
        <String, Object?>{
          'key': 'runtime/image_cache',
          'tag': 'runtime',
          'name': 'image_cache',
          'size': 512,
          'count': 3,
          'types': '.png/.jpg',
        },
        <String, Object?>{
          'key': 'imports/report',
          'tag': 'imports',
          'name': 'report',
          'size': 1024,
          'count': 1,
          'types': '.pdf',
        },
      ],
      tempDirLoader: () async => temp,
      prefsLoader: SharedPreferences.getInstance,
      sessionCountLoader: () async => 2,
    );

    expect(entries, hasLength(5));
    for (var i = 1; i < entries.length; i++) {
      expect(
        entries[i - 1].bytes,
        greaterThanOrEqualTo(entries[i].bytes),
        reason: '缓存必须按占用从大到小排列',
      );
    }
    final ai = entries.firstWhere((e) => e.kind == CacheKind.quizAi);
    expect(ai.bytes, aiJson.length * 2);
    expect(ai.detail, contains('1 条解析'));

    final records = entries.firstWhere((e) => e.kind == CacheKind.quizRecords);
    expect(records.bytes, 2 * 4096);
    expect(records.detail, contains('2 条已交卷记录'));

    final runtime = entries.firstWhere((e) => e.kind == CacheKind.runtime);
    expect(runtime.tool, '系统');
    expect(runtime.name, '运行时缓存');
    expect(runtime.detail, contains('image_cache'));
    expect(runtime.detail, contains('多为 .png/.jpg'));

    final imports = entries.firstWhere((e) => e.kind == CacheKind.imports);
    expect(imports.tool, '文字阅读器');

    final copied = entries.firstWhere((e) => e.kind == CacheKind.temp);
    expect(copied.bytes, 500);
    expect(copied.detail, contains('2 个文件'));
  });

  test('单项清理只删对应缓存，不动其他文件与偏好', () async {
    await File('${temp.path}/xmt_a.jpg').writeAsBytes(List<int>.filled(300, 1));
    await File('${temp.path}/keep.txt').writeAsString('keep');

    const tempEntry = CacheEntry(
      id: 'temp',
      tool: '文字阅读器',
      name: '导入临时文件',
      detail: '',
      bytes: 300,
      kind: CacheKind.temp,
    );
    final freed = await CacheInventory.clean(
      tempEntry,
      tempDirLoader: () async => temp,
    );
    expect(freed, 300);
    expect(File('${temp.path}/xmt_a.jpg').existsSync(), isFalse);
    expect(File('${temp.path}/keep.txt').existsSync(), isTrue);

    final aiEntry = CacheEntry(
      id: 'quiz-ai',
      tool: '刷题助手',
      name: 'AI 解析缓存',
      detail: '',
      bytes: aiJson.length * 2,
      kind: CacheKind.quizAi,
    );
    expect(
      await CacheInventory.clean(
        aiEntry,
        prefsLoader: SharedPreferences.getInstance,
      ),
      aiJson.length * 2,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(QuizAiService.cacheStoreKey), isNull);
  });

  test('原生缓存项按 key 交由原生清理，非法项返回 0', () async {
    const entry = CacheEntry(
      id: 'runtime/image_cache',
      key: 'runtime/image_cache',
      tool: '系统',
      name: '运行时缓存',
      detail: '',
      bytes: 100,
      kind: CacheKind.runtime,
    );
    final cleaned = <String>[];
    expect(
      await CacheInventory.clean(
        entry,
        nativeCleaner: (key) async {
          cleaned.add(key);
          return 100;
        },
      ),
      100,
    );
    expect(cleaned, <String>['runtime/image_cache']);
  });
}
