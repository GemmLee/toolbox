import '../../../core/storage/local_store.dart';
import 'mortgage_models.dart';

/// 房贷方案的本地存储（SharedPreferences，JSON）。
///
/// 页面通过注入 loader / saver 绕开真实 I/O，widget 测试里不用碰磁盘。
class MortgageStore {
  MortgageStore._();

  static const String storageKey = 'salary_mortgage_plans';

  /// 当前选中的方案 id，工资统计叠加房贷时用它。
  static const String selectedKey = 'salary_mortgage_selected';

  static Future<List<MortgagePlan>> load() async {
    final json = await LocalStore.readMap(storageKey);
    final raw = json?['plans'];
    if (raw is! List) return <MortgagePlan>[];
    final plans = <MortgagePlan>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final plan = MortgagePlan.fromJson(Map<String, dynamic>.from(item));
      if (plan.id.isEmpty || plan.totalPrice <= 0) continue;
      plans.add(plan);
    }
    return plans;
  }

  static Future<void> save(List<MortgagePlan> plans) =>
      LocalStore.writeMap(storageKey, <String, dynamic>{
        'plans': plans.map((e) => e.toJson()).toList(),
      });

  static Future<String?> loadSelectedId() async {
    final json = await LocalStore.readMap(selectedKey);
    final id = json?['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  static Future<void> saveSelectedId(String? id) async {
    if (id == null || id.isEmpty) {
      await LocalStore.remove(selectedKey);
      return;
    }
    await LocalStore.writeMap(selectedKey, <String, dynamic>{'id': id});
  }
}
