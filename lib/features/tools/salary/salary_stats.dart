import 'dart:math' as math;

import '../../../core/insurance.dart';
import 'city_rules.dart';
import 'salary_calculator.dart';
import 'salary_models.dart';
import 'salary_records.dart';

/// 横轴尺度：按月看波动、按年看走势，两张曲线共用同一组切换。
enum SalaryScale { month, year }

class SalaryPoint {
  const SalaryPoint(this.key, this.label, this.value);

  /// '2026-03' 或 '2026'。
  final String key;
  final String label;
  final double value;
}

/// 由历史工资推算出的社保/公积金基数，回填到工资计算器。
class SalaryBaseSuggestion {
  const SalaryBaseSuggestion({
    required this.year,
    required this.averageMonthly,
    required this.socialBase,
    required this.fundBase,
  });

  /// 实际取用的年份（优先上一年，没有记录则退回最近有记录的一年）。
  final int year;
  final double averageMonthly;
  final double socialBase;
  final double fundBase;
}

/// 工资统计的纯计算层：不碰 UI、不碰存储，便于单测覆盖边界。
class SalaryStats {
  SalaryStats._();

  static const int maxMonths = 36;

  /// 收入曲线：按日记录累加到所在月、按月记录直接入账、年终奖记在当年 12 月。
  /// 月尺度会补齐中间月份（没记录按 0），最多保留最近 [maxMonths] 个月。
  ///
  /// [transform] 可把每期税前总额换成税后到手（见 [netOfGross]）；记录本身
  /// 始终按税前存储，切换只在出图时换算。
  static List<SalaryPoint> incomeSeries(
    List<SalaryRecord> records,
    SalaryScale scale, {
    int maxMonths = SalaryStats.maxMonths,
    double Function(double gross)? transform,
  }) {
    final valid = _valid(records);
    if (valid.isEmpty) return <SalaryPoint>[];
    double amount(double v) => transform == null
        ? v
        : _round2(transform(v)).clamp(0, double.infinity).toDouble();
    final byMonth = <String, double>{};
    final byYear = <String, double>{};
    for (final r in valid) {
      byMonth[r.monthKey] = (byMonth[r.monthKey] ?? 0) + r.amount;
      byYear[r.yearKey] = (byYear[r.yearKey] ?? 0) + r.amount;
    }
    if (scale == SalaryScale.year) {
      final keys = byYear.keys.toList()..sort();
      return <SalaryPoint>[
        for (final key in keys) SalaryPoint(key, key, amount(byYear[key]!)),
      ];
    }
    final keys = byMonth.keys.toList()..sort();
    final months = _monthKeys(keys.first, keys.last);
    final all = <SalaryPoint>[
      for (final key in months)
        SalaryPoint(
          key,
          '${_yearOf(key)}/${_monthOf(key)}',
          amount(byMonth[key] ?? 0),
        ),
    ];
    return _tail(all, maxMonths);
  }

  /// 税前月工资 → 税后到手（月度估算口径，与工资计算器「月度估算」一致）。
  ///
  /// 单位缴纳比例不影响个人到手，这里只借用计算器的个人侧；年终奖已并入
  /// 当月收入一起计税，属于图表用的简化估算，不用于实际报税。
  static double netOfGross({
    required double gross,
    required CityRules city,
    required Map<String, double> personalRates,
    double socialBase = 0,
    double fundBase = 0,
    double specialDeduction = 0,
  }) {
    if (gross <= 0) return 0;
    return SalaryCalculator.compute(
      SalaryInput(
        gross: gross,
        socialBase: socialBase,
        fundBase: fundBase,
        city: city,
        personalRates: personalRates,
        employerRates: personalRates,
        specialDeduction: specialDeduction,
        month: 1,
        cumulative: false,
      ),
    ).net;
  }

  /// 平均工资：只算有记录的期（value > 0），也就是从第一条有记录开始，
  /// 前面补齐的 0 月不会把平均拉低。无记录时返回 null，图上不画平均线。
  static double? averageOf(List<SalaryPoint> points) {
    var sum = 0.0;
    var count = 0;
    for (final point in points) {
      if (point.value <= 0) continue;
      sum += point.value;
      count++;
    }
    return count == 0 ? null : _round2(sum / count);
  }

  /// 12 个月均线：每个点取「它自己往前 12 个点」的平均，长度与输入一致。
  ///
  /// 有记录的月份不足 12 个时整条线为空（全 null），图上不画、图例显示「无」；
  /// 补齐的 0 月照常参与平均，与曲线本身同口径。
  static List<double?> movingAverage(
    List<SalaryPoint> points, {
    int window = 12,
  }) {
    final result = List<double?>.filled(points.length, null);
    if (window <= 1 || points.length < window) return result;
    final recorded = points.where((p) => p.value > 0).length;
    if (recorded < window) return result;
    var sum = 0.0;
    for (var i = 0; i < points.length; i++) {
      sum += points[i].value;
      if (i >= window) sum -= points[i - window].value;
      if (i >= window - 1) result[i] = _round2(sum / window);
    }
    return result;
  }

  /// 社保及公积金账户累计曲线：每期按当月工资（不含年终奖）计算个人缴纳额，
  /// 逐期累加；基数沿用工资计算器里的输入，未填则跟随工资并受城市上下限约束。
  static List<SalaryPoint> socialBalanceSeries(
    List<SalaryRecord> records, {
    required SalaryScale scale,
    required CityRules city,
    required Map<String, double> personalRates,
    double socialBase = 0,
    double fundBase = 0,
    double initialBalance = 0,
    int maxMonths = SalaryStats.maxMonths,
    double Function(String monthKey)? fundDeduction,
  }) {
    final wages =
        _valid(records).where((r) => r.kind != SalaryRecordKind.bonus).toList();
    if (wages.isEmpty) return <SalaryPoint>[];
    final byMonth = <String, double>{};
    for (final r in wages) {
      byMonth[r.monthKey] = (byMonth[r.monthKey] ?? 0) + r.amount;
    }
    final keys = byMonth.keys.toList()..sort();
    var balance = initialBalance;
    final monthly = <SalaryPoint>[];
    for (final key in _monthKeys(keys.first, keys.last)) {
      final gross = byMonth[key] ?? 0;
      if (gross > 0) {
        balance += personalContribution(
          gross: gross,
          city: city,
          personalRates: personalRates,
          socialBase: socialBase,
          fundBase: fundBase,
        );
      }
      // 公积金贷款月供从账户余额扣：不管这个月有没有工资记录都要扣，
      // 余额允许为负（账户被掏空），图上能直接看出什么时候见底。
      if (fundDeduction != null) balance -= fundDeduction(key);
      monthly.add(
        SalaryPoint(
          key,
          '${_yearOf(key)}/${_monthOf(key)}',
          _round2(balance),
        ),
      );
    }
    if (scale == SalaryScale.month) return _tail(monthly, maxMonths);
    final byYear = <String, SalaryPoint>{};
    for (final point in monthly) {
      final year = point.key.substring(0, 4);
      byYear[year] = SalaryPoint(year, year, point.value);
    }
    final result = byYear.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return result;
  }

  /// 个人五险一金缴纳额合计，与工资计算器的 personalTotal 同口径。
  static double personalContribution({
    required double gross,
    required CityRules city,
    required Map<String, double> personalRates,
    double socialBase = 0,
    double fundBase = 0,
  }) {
    final sb = city.clampSocialBase(socialBase > 0 ? socialBase : gross);
    final fb = city.clampFundBase(fundBase > 0 ? fundBase : gross);
    var total = 0.0;
    for (final item in kInsuranceItems) {
      final base = item.useFundBase ? fb : sb;
      final rate = (personalRates[item.id] ?? city.personalRate(item.id))
          .clamp(0.0, 100.0);
      total += base * rate / 100;
    }
    return _round2(total);
  }

  /// 社保基数通常取上年度月平均工资（含年终奖），再按城市上下限修正。
  /// 上一年没有记录时退回最近有记录的一年，并在结果里标明实际年份。
  static SalaryBaseSuggestion? suggestBase(
    List<SalaryRecord> records,
    CityRules city, {
    int? year,
  }) {
    final valid = _valid(records);
    if (valid.isEmpty) return null;
    final latest = valid.map((r) => r.year).reduce((a, b) => math.max(a, b));
    var target = year ?? latest - 1;
    var total = _totalOfYear(valid, target);
    if (total <= 0) {
      target = latest;
      total = _totalOfYear(valid, target);
    }
    if (total <= 0) return null;
    final avg = total / 12;
    return SalaryBaseSuggestion(
      year: target,
      averageMonthly: _round2(avg),
      socialBase: _round2(city.clampSocialBase(avg)),
      fundBase: _round2(city.clampFundBase(avg)),
    );
  }

  static double _totalOfYear(List<SalaryRecord> records, int year) => records
      .where((r) => r.year == year)
      .fold<double>(0, (sum, r) => sum + r.amount);

  static List<SalaryRecord> _valid(List<SalaryRecord> records) => records
      .where((r) => r.year > 0 && r.monthKey.isNotEmpty && r.amount > 0)
      .toList();

  /// 含首尾的连续月份，最多 600 个，避免脏数据造出超长列表。
  static List<String> _monthKeys(String first, String last) {
    var y = _yearOf(first);
    var m = _monthOf(first);
    final endY = _yearOf(last);
    final endM = _monthOf(last);
    final keys = <String>[];
    while ((y < endY || (y == endY && m <= endM)) && keys.length < 600) {
      keys.add('${y.toString().padLeft(4, '0')}-'
          '${m.toString().padLeft(2, '0')}');
      m++;
      if (m > 12) {
        m = 1;
        y++;
      }
    }
    return keys;
  }

  static List<SalaryPoint> _tail(List<SalaryPoint> points, int max) =>
      points.length > max ? points.sublist(points.length - max) : points;

  static int _yearOf(String key) => int.tryParse(key.substring(0, 4)) ?? 0;

  static int _monthOf(String key) =>
      key.length >= 7 ? int.tryParse(key.substring(5, 7)) ?? 1 : 1;

  static double _round2(double v) => (v * 100).roundToDouble() / 100;
}
