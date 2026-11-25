import '../../../core/storage/local_store.dart';

/// 一条工资记录的类型。
enum SalaryRecordKind {
  /// 按日：某一天拿到的工资，period 形如 2026-03-05。
  daily,

  /// 按月：某个月的工资，period 形如 2026-03。
  monthly,

  /// 年终奖：按年记录，period 形如 2026。
  bonus,
}

/// 类型展示名（简体中文源文案，页面统一过 tr()）。
String salaryRecordKindLabel(SalaryRecordKind kind) => switch (kind) {
      SalaryRecordKind.daily => '按日工资',
      SalaryRecordKind.monthly => '按月工资',
      SalaryRecordKind.bonus => '年终奖',
    };

/// 一条工资/年终奖记录，period 的具体格式由 [kind] 决定。
class SalaryRecord {
  const SalaryRecord({
    required this.id,
    required this.kind,
    required this.period,
    required this.amount,
    this.note = '',
  });

  final String id;
  final SalaryRecordKind kind;
  final String period;
  final double amount;
  final String note;

  /// 年份；格式不合法时返回 0，聚合层会直接丢掉。
  int get year =>
      period.length >= 4 ? int.tryParse(period.substring(0, 4)) ?? 0 : 0;

  /// 归属月份（年终奖记在当年 12 月）。
  String get monthKey {
    if (period.length < 4) return '';
    if (kind == SalaryRecordKind.bonus) {
      return '${period.substring(0, 4)}-12';
    }
    return period.length >= 7 ? period.substring(0, 7) : '';
  }

  String get yearKey => period.length >= 4 ? period.substring(0, 4) : '';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind.name,
        'period': period,
        'amount': amount,
        'note': note,
      };

  factory SalaryRecord.fromJson(Map<String, dynamic> json) {
    final kind = SalaryRecordKind.values.firstWhere(
      (e) => e.name == json['kind'],
      orElse: () => SalaryRecordKind.monthly,
    );
    return SalaryRecord(
      id: (json['id'] ?? '').toString(),
      kind: kind,
      period: (json['period'] ?? '').toString().trim(),
      amount: _number(json['amount']),
      note: (json['note'] ?? '').toString(),
    );
  }

  static double _number(Object? value) => switch (value) {
        final double v => v,
        final int v => v.toDouble(),
        final String v => double.tryParse(v) ?? 0,
        _ => 0,
      };
}

/// SharedPreferences 读写；页面通过注入 loader / saver 绕开真实 I/O，便于测试。
class SalaryRecordStore {
  SalaryRecordStore._();

  static const String storageKey = 'salary_stats_records';

  static Future<List<SalaryRecord>> load() async {
    final json = await LocalStore.readMap(storageKey);
    final raw = json?['records'];
    if (raw is! List) return <SalaryRecord>[];
    final records = <SalaryRecord>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final record = SalaryRecord.fromJson(Map<String, dynamic>.from(item));
      // 脏数据（空 period / 非正数金额）直接跳过，别让曲线出现 1970 年。
      if (record.year <= 0 || record.monthKey.isEmpty || record.amount <= 0) {
        continue;
      }
      records.add(record);
    }
    records.sort((a, b) => a.period.compareTo(b.period));
    return records;
  }

  static Future<void> save(List<SalaryRecord> records) =>
      LocalStore.writeMap(storageKey, <String, dynamic>{
        'records': records.map((e) => e.toJson()).toList(),
      });
}
