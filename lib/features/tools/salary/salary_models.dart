import '../../../core/insurance.dart';
import 'city_rules.dart';
import 'tax_rules.dart';

/// 计算入参。所有金额均为「元/月」，比例为百分数值（8 表示 8%）。
class SalaryInput {
  const SalaryInput({
    required this.gross,
    required this.city,
    required this.personalRates,
    required this.employerRates,
    this.socialBase = 0,
    this.fundBase = 0,
    this.specialDeduction = 0,
    this.month = 1,
    this.cumulative = true,
  });

  final double gross;

  /// 社保基数，<= 0 表示跟随税前工资并受城市上下限约束。
  final double socialBase;

  /// 公积金基数，<= 0 表示跟随税前工资并受城市上下限约束。
  final double fundBase;

  final CityRules city;
  final Map<String, double> personalRates;
  final Map<String, double> employerRates;

  /// 每月专项附加扣除等（不含五险一金与基本减除费用）。
  final double specialDeduction;

  /// 当前月份 1-12，仅累计预扣法使用。
  final int month;

  /// true = 累计预扣法；false = 月度简易估算。
  final bool cumulative;

  double personalRate(String itemId) => personalRates[itemId] ?? 0;

  double employerRate(String itemId) => employerRates[itemId] ?? 0;
}

/// 单项五险一金结果。
class ContributionLine {
  const ContributionLine({
    required this.item,
    required this.base,
    required this.personalRate,
    required this.employerRate,
    required this.personal,
    required this.employer,
  });

  final InsuranceItem item;
  final double base;
  final double personalRate;
  final double employerRate;
  final double personal;
  final double employer;

  double get total => personal + employer;
}

/// 计算结果。
class SalaryResult {
  const SalaryResult({
    required this.gross,
    required this.lines,
    required this.socialBaseUsed,
    required this.fundBaseUsed,
    required this.socialBaseAdjusted,
    required this.fundBaseAdjusted,
    required this.personalTotal,
    required this.employerTotal,
    required this.specialDeduction,
    required this.month,
    required this.cumulative,
    required this.taxableMonthly,
    required this.taxableYtd,
    required this.tax,
    required this.net,
    required this.bracket,
    required this.annualTax,
    required this.annualNet,
  });

  final double gross;
  final List<ContributionLine> lines;
  final double socialBaseUsed;
  final double fundBaseUsed;

  /// 输入基数被城市上下限修正过。
  final bool socialBaseAdjusted;
  final bool fundBaseAdjusted;

  final double personalTotal;
  final double employerTotal;
  final double specialDeduction;

  final int month;
  final bool cumulative;

  /// 当月应纳税所得额。
  final double taxableMonthly;

  /// 截至当月的累计应纳税所得额（累计预扣法）。
  final double taxableYtd;

  final double tax;
  final double net;
  final TaxBracket bracket;

  final double annualTax;
  final double annualNet;

  double get employerCost => gross + employerTotal;

  double get annualEmployerCost => employerCost * 12;

  double get takeHomeRate => gross <= 0 ? 0 : net / gross;

  double get deductionTotal => personalTotal + tax;
}
