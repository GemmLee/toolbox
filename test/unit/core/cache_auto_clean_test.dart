import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/core/storage/cache_auto_clean.dart';
import 'package:toolbox/core/storage/cache_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('只清理可再生缓存，7 天内不重复清理', () async {
    final entries = <CacheEntry>[
      const CacheEntry(
        id: 'r',
        tool: '系统',
        name: '运行时缓存',
        detail: '',
        bytes: 10,
        kind: CacheKind.runtime,
        key: 'runtime/a',
      ),
      const CacheEntry(
        id: 'i',
        tool: '阅读',
        name: '导入临时副本',
        detail: '',
        bytes: 20,
        kind: CacheKind.imports,
        key: 'imports/b',
      ),
      const CacheEntry(
        id: 't',
        tool: '系统',
        name: '临时文件',
        detail: '',
        bytes: 30,
        kind: CacheKind.temp,
        key: 'xmt_c',
      ),
      const CacheEntry(
        id: 'q',
        tool: '刷题',
        name: '旧刷题记录',
        detail: '',
        bytes: 40,
        kind: CacheKind.quizRecords,
        key: 'quiz',
      ),
    ];
    final cleaned = <String>[];
    final now = DateTime(2026, 11, 19, 12);
    Future<int> cleaner(CacheEntry entry) async {
      cleaned.add(entry.id);
      return entry.bytes;
    }

    final freed = await CacheAutoClean.runIfDue(
      now: () => now,
      inventoryLoader: () async => entries,
      cleaner: cleaner,
    );
    expect(freed, 60);
    expect(cleaned, <String>['r', 'i', 't']);

    final soon = await CacheAutoClean.runIfDue(
      now: () => now.add(const Duration(days: 3)),
      inventoryLoader: () async => entries,
      cleaner: cleaner,
    );
    expect(soon, 0);
    expect(cleaned.length, 3);

    final later = await CacheAutoClean.runIfDue(
      now: () => now.add(const Duration(days: 8)),
      inventoryLoader: () async => entries,
      cleaner: cleaner,
    );
    expect(later, 60);
    expect(cleaned.length, 6);
  });

  test('单项清理失败不影响其它项，且仍记录清理时间', () async {
    final entries = <CacheEntry>[
      const CacheEntry(
        id: 'a',
        tool: '系统',
        name: '缓存',
        detail: '',
        bytes: 5,
        kind: CacheKind.runtime,
        key: 'runtime/a',
      ),
      const CacheEntry(
        id: 'b',
        tool: '系统',
        name: '缓存',
        detail: '',
        bytes: 7,
        kind: CacheKind.runtime,
        key: 'runtime/b',
      ),
    ];
    final cleaned = <String>[];
    final freed = await CacheAutoClean.runIfDue(
      now: () => DateTime(2026, 11, 19, 12),
      inventoryLoader: () async => entries,
      cleaner: (entry) async {
        if (entry.id == 'a') throw StateError('mock failure');
        cleaned.add(entry.id);
        return entry.bytes;
      },
    );
    expect(freed, 7);
    expect(cleaned, <String>['b']);
  });
}
