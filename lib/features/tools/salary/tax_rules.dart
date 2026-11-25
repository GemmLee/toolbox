// 个人所得税规则（居民个人工资薪金，2019 年起施行）。
//
// 采用累计预扣法：累计应纳税所得额对应年度综合所得税率表。
// 月度简易估算则用「月应纳税所得额 × 12」套用同一张表后除以 12，
// 等价于月度税率表速算，适合快速心算。

class TaxBracket {
  const TaxBracket({
    required this.upper,
    required this.rate,
    required this.quickDeduction,
  });

  /// 本级上限（元），最后一档使用 double.infinity。
  final double upper;

  /// 税率，0.03 表示 3%。
  final double rate;

  /// 速算扣除数（元）。
  final double quickDeduction;

  String get label => '${(rate * 100).toStringAsFixed(0)}%';
}

const double kMonthlyBasicDeduction = 5000;

const List<TaxBracket> kAnnualTaxBrackets = <TaxBracket>[
  TaxBracket(upper: 36000, rate: 0.03, quickDeduction: 0),
  TaxBracket(upper: 144000, rate: 0.10, quickDeduction: 2520),
  TaxBracket(upper: 300000, rate: 0.20, quickDeduction: 16920),
  TaxBracket(upper: 420000, rate: 0.25, quickDeduction: 31920),
  TaxBracket(upper: 660000, rate: 0.30, quickDeduction: 52920),
  TaxBracket(upper: 960000, rate: 0.35, quickDeduction: 85920),
  TaxBracket(upper: double.infinity, rate: 0.45, quickDeduction: 181920),
];

/// 按年度综合所得税率表计算应纳税额。
double annualTaxOf(double taxableAnnual) {
  if (taxableAnnual <= 0) return 0;
  final bracket = bracketOf(taxableAnnual);
  final tax = taxableAnnual * bracket.rate - bracket.quickDeduction;
  return tax <= 0 ? 0 : tax;
}

TaxBracket bracketOf(double taxableAnnual) {
  if (taxableAnnual <= 0) return kAnnualTaxBrackets.first;
  for (final bracket in kAnnualTaxBrackets) {
    if (taxableAnnual <= bracket.upper) return bracket;
  }
  return kAnnualTaxBrackets.last;
}

/// 累计预扣法：第 [month] 月应预扣税额。
///
/// [monthlyTaxable] 为当月应纳税所得额（已扣除五险一金、专项附加扣除、
/// 基本减除费用），假设全年每月金额相同。
double cumulativeTaxForMonth({
  required double monthlyTaxable,
  required int month,
}) {
  if (monthlyTaxable <= 0 || month <= 0) return 0;
  final current = annualTaxOf(monthlyTaxable * month);
  final previous = month <= 1 ? 0.0 : annualTaxOf(monthlyTaxable * (month - 1));
  final tax = current - previous;
  return tax <= 0 ? 0 : tax;
}

/// 月度简易估算：按月度税率表速算。
double monthlyEstimatedTax(double monthlyTaxable) {
  if (monthlyTaxable <= 0) return 0;
  return annualTaxOf(monthlyTaxable * 12) / 12;
}
