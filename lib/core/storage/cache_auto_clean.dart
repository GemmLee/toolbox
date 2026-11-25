import 'cache_inventory.dart';
import 'local_store.dart';

/// 系统运行时缓存的定期自动清理。
///
/// 只处理 cacheDir / externalCacheDir / 导入临时副本 / xmt_ 临时文件这类
/// 可再生数据；题库、笔记、用户文件或偏好设置不在这里，也不会被触碰。
/// 清理失败不记录时间，下次启动会再试。
class CacheAutoClean {
  CacheAutoClean._();

  static const String _lastKey = 'cache_auto_clean_last';

  /// 距上次清理超过这个间隔才自动执行一次。
  static const Duration interval = Duration(days: 7);

  static Future<int> runIfDue({
    DateTime Function()? now,
    Future<List<CacheEntry>> Function()? inventoryLoader,
    Future<int> Function(CacheEntry entry)? cleaner,
  }) async {
    final current = (now ?? DateTime.now)();
    final map = await LocalStore.readMap(_lastKey);
    final ts = (map?['last'] as num?)?.toInt();
    if (ts != null) {
      final age = current.difference(DateTime.fromMillisecondsSinceEpoch(ts));
      if (age >= Duration.zero && age < interval) return 0;
    }

    final entries = await (inventoryLoader ?? CacheInventory.load)();
    var freed = 0;
    for (final entry in entries) {
      if (entry.kind != CacheKind.runtime &&
          entry.kind != CacheKind.imports &&
          entry.kind != CacheKind.temp) {
        continue;
      }
      try {
        freed += cleaner == null
            ? await CacheInventory.clean(entry)
            : await cleaner(entry);
      } catch (_) {
        // 单项清理失败不影响其它项。
      }
    }

    try {
      await LocalStore.writeMap(_lastKey, <String, dynamic>{
        'last': current.millisecondsSinceEpoch,
      });
    } catch (_) {
      // 记录失败只会导致下次重复清理，不影响数据。
    }
    return freed;
  }
}
