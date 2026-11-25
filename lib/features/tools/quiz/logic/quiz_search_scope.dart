import '../../../../core/storage/local_store.dart';
import '../data/quiz_models.dart';

/// 各搜索入口的题库范围记忆。
///
/// 每个入口保留自己的 key（悬浮窗还要附带索引/主题等偏好），
/// 另用 [lastKey] 记住"最近一次选择"，新入口首次进入时可以直接沿用。
class QuizSearchScope {
  const QuizSearchScope._();

  /// 全局搜索页自己的范围 key。
  static const String searchKey = 'quiz_search_scope';

  /// 最近一次在任意搜索入口选择题库的范围。
  static const String lastKey = 'quiz_search_last_scope';

  /// 兼容老版本只存单个 bankId 的格式。
  static Set<String> idsFrom(Map<String, dynamic>? saved) {
    if (saved == null) return const <String>{};
    final rawIds = saved['bankIds'];
    final legacyId = saved['bankId']?.toString();
    return <String>{
      if (rawIds is List) ...rawIds.map((e) => '$e'),
      if (legacyId != null && legacyId.isNotEmpty) legacyId,
    };
  }

  /// 题库被删后把失效 id 剔除，避免一进页面就搜不到东西。
  static Set<String> validIds(Set<String> ids, List<Bank> banks) =>
      ids.where((id) => banks.any((b) => b.id == id)).toSet();

  /// 读取最近一次选择；没有记录时返回空集合（即全部题库）。
  static Future<Set<String>> lastIds() async =>
      idsFrom(await LocalStore.readMap(lastKey));

  /// 任意入口确认题库范围后调用，供其它入口下次进入时默认沿用。
  static Future<void> remember(Set<String> ids) =>
      LocalStore.writeMap(lastKey, <String, dynamic>{
        'bankIds': ids.toList(growable: false),
      });
}
