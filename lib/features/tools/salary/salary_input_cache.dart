import '../../../core/storage/local_store.dart';

/// 工资计算器里用户输入的快照。
///
/// 输入框一律按「键 → 原始文本」保存（比例、基数、月薪、专项扣除都在内），
/// 这样恢复时不必反向格式化数字，也不会把用户没填完的 `12.` 吞掉。
class SalaryInputSnapshot {
  const SalaryInputSnapshot({
    required this.cityId,
    required this.values,
    this.cumulative = true,
    this.month = 1,
    this.ratesCustomized = false,
  });

  static const String grossKey = 'gross';
  static const String socialBaseKey = 'socialBase';
  static const String fundBaseKey = 'fundBase';
  static const String specialDeductionKey = 'specialDeduction';

  final String cityId;
  final Map<String, String> values;
  final bool cumulative;
  final int month;
  final bool ratesCustomized;

  String valueOf(String key) => values[key] ?? '';

  static String personalKey(String itemId) => 'personal.$itemId';
  static String employerKey(String itemId) => 'employer.$itemId';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cityId': cityId,
        'values': values,
        'cumulative': cumulative,
        'month': month,
        'ratesCustomized': ratesCustomized,
      };

  factory SalaryInputSnapshot.fromJson(Map<String, dynamic> json) {
    final raw = json['values'];
    final values = <String, String>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value != null) values[key.toString()] = value.toString();
      });
    }
    return SalaryInputSnapshot(
      cityId: (json['cityId'] ?? '').toString(),
      values: values,
      cumulative: json['cumulative'] != false,
      month: (json['month'] as num?)?.toInt() ?? 1,
      ratesCustomized: json['ratesCustomized'] == true,
    );
  }
}

/// 输入缓存：下次打开工资计算器自动恢复上次编辑的内容。
/// 与「个人信息文件」是两回事——缓存只影响本页输入框，不写进存储空间。
class SalaryInputCache {
  SalaryInputCache._();

  static const String storageKey = 'salary_calculator_inputs';

  static Future<SalaryInputSnapshot?> load() async {
    final json = await LocalStore.readMap(storageKey);
    if (json == null || json.isEmpty) return null;
    return SalaryInputSnapshot.fromJson(json);
  }

  static Future<void> save(SalaryInputSnapshot snapshot) =>
      LocalStore.writeMap(storageKey, snapshot.toJson());

  static Future<void> clear() => LocalStore.remove(storageKey);
}
