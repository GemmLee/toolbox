import 'dart:math' as math;

import 'pension_policy.dart';
import 'tax_rules.dart';

/// 养老金测算输入。
class PensionInput {
  const PensionInput({
    required this.policy,
    required this.annualSalary,
    required this.monthlyBase,
    required this.currentAge,
    required this.retireAge,
    required this.paidYears,
    this.accountBalance = 0,
    this.salaryGrowth = 0.03,
    this.customPensionBase,
  });

  /// 城市养老政策。
  final PensionPolicy policy;

  /// 年薪估计值（元/年）。
  final double annualSalary;

  /// 当前社保缴费基数（元/月）。
  final double monthlyBase;

  final double currentAge;
  final double retireAge;

  /// 已缴费年限（含视同缴费年限）。
  final double paidYears;

  /// 个人账户当前累计储存额；<= 0 时按已缴年限估算。
  final double accountBalance;

  /// 年薪年增长率（0.03 表示 3%）。
  final double salaryGrowth;

  /// 覆盖城市内置计发基数（自定义城市用）。
  final double? customPensionBase;
}

/// 养老金测算结果。
class PensionResult {
  const PensionResult({
    required this.pensionBase,
    required this.contributionIndex,
    required this.paidYears,
    required this.futureYears,
    required this.totalYears,
    required this.monthsFactor,
    required this.basicPension,
    required this.accountBalanceAtRetire,
    required this.accountPension,
    required this.monthlyPension,
    required this.replacementRate,
    required this.personalPaidTotal,
    required this.paybackYears,
    required this.monthlySalaryAtRetire,
  });

  final double pensionBase;

  /// 本人平均缴费指数（0.6–3.0）。
  final double contributionIndex;
  final double paidYears;
  final double futureYears;
  final double totalYears;

  /// 个人账户计发月数。
  final double monthsFactor;

  /// 基础养老金（元/月）。
  final double basicPension;

  /// 退休时个人账户累计储存额。
  final double accountBalanceAtRetire;

  /// 个人账户养老金（元/月）。
  final double accountPension;

  /// 预计月养老金合计。
  final double monthlyPension;

  /// 养老金替代率（相对退休前月薪）。
  final double replacementRate;

  /// 个人累计缴纳的养老保险费（本金，不含利息）。
  final double personalPaidTotal;

  /// 领取后回本年限（仅按个人本金估算）。
  final double paybackYears;

  /// 退休前预计月薪。
  final double monthlySalaryAtRetire;
}

/// 个人养老金（第三支柱）税优输入。
class TaxBenefitInput {
  const TaxBenefitInput({
    required this.annualSalary,
    this.monthlyPersonalInsurance = 0,
    this.specialDeductionMonthly = 0,
    this.otherAnnualDeduction = 0,
    this.cap = 12000,
  });

  /// 年薪估计值（元/年）。
  final double annualSalary;

  /// 每月个人缴纳的五险一金合计（元/月）。
  final double monthlyPersonalInsurance;

  /// 每月专项附加扣除（元/月）。
  final double specialDeductionMonthly;

  /// 其它年度税前扣除（如商业健康险等）。
  final double otherAnnualDeduction;

  /// 个人养老金年度缴纳上限，现行政策为 12000 元。
  final double cap;
}

/// 某个缴纳档位的税优结果。
class TaxBenefitOption {
  const TaxBenefitOption({
    required this.amount,
    required this.taxSaved,
    required this.withdrawalTax,
    required this.netBenefit,
  });

  /// 年度缴纳额。
  final double amount;

  /// 当年少缴的个税。
  final double taxSaved;

  /// 领取环节按 3% 单独计税的税额。
  final double withdrawalTax;

  /// 净税优（已扣领取环节税负）。
  final double netBenefit;
}

/// 税优测算结果。
class TaxBenefitResult {
  const TaxBenefitResult({
    required this.taxableAnnual,
    required this.marginalRate,
    required this.options,
    required this.recommended,
    required this.maxNetBenefit,
    required this.cap,
    required this.bracketDropAmount,
    required this.nextRate,
  });

  /// 未缴纳个人养老金时的年应纳税所得额。
  final double taxableAnnual;

  /// 当前边际税率（0.03 = 3%）。
  final double marginalRate;

  final List<TaxBenefitOption> options;
  final TaxBenefitOption recommended;
  final double maxNetBenefit;
  final double cap;

  /// 把边际税率降到下一档所需的缴纳额；null 表示在 12000 元限额内做不到。
  final double? bracketDropAmount;

  /// 降档后的税率；无降档可能时为 null。
  final double? nextRate;

  bool get worthIt => maxNetBenefit > 0;
}

/// 养老金领取测算与个人养老金税优，纯函数实现。
class PensionCalculator {
  PensionCalculator._();

  /// 城镇职工基本养老金估算。
  ///
  /// 基础养老金 = 计发基数 × (1 + 平均缴费指数) / 2 × 缴费年限 × 1%
  /// 个人账户养老金 = 退休时个人账户累计储存额 ÷ 计发月数
  /// 未计入过渡性养老金、地方增发与每年待遇调整，结果偏保守。
  static PensionResult pension(PensionInput input) {
    final base =
        (input.customPensionBase != null && input.customPensionBase! > 0)
            ? input.customPensionBase!
            : input.policy.pensionBase;
    final monthlySalary = _positive(input.annualSalary) / 12;
    final monthBase = input.monthlyBase > 0 ? input.monthlyBase : monthlySalary;
    final index =
        (monthBase / (base <= 0 ? 1 : base)).clamp(0.6, 3.0).toDouble();

    final retireAge = input.retireAge.clamp(40, 70).toDouble();
    final currentAge = input.currentAge.clamp(18, retireAge).toDouble();
    final futureYears = _round2(retireAge - currentAge);
    final paidYears =
        _nonNegative(input.paidYears).clamp(0, retireAge - 18).toDouble();
    final totalYears = paidYears + futureYears;
    final growth = input.salaryGrowth.clamp(-0.05, 0.15).toDouble();
    final rate = input.policy.accountRate;

    // 已有个人账户余额：用户填了就用，否则按已缴年限 × 8% 粗估。
    const personalRate = 0.08;
    var balance = input.accountBalance > 0
        ? input.accountBalance
        : _round2(monthBase * personalRate * 12 * paidYears);
    var personalPaid = _round2(monthBase * personalRate * 12 * paidYears);
    var futureBase = monthBase;
    for (var year = 0; year < futureYears.floor(); year++) {
      futureBase *= 1 + growth;
      final contribution = _round2(futureBase * personalRate * 12);
      personalPaid = _round2(personalPaid + contribution);
      balance = _round2(balance * (1 + rate) + contribution);
    }
    // 不足整年的剩余月份按折算时长计一次息与缴费。
    final rest = futureYears - futureYears.floor();
    if (rest > 0) {
      final contribution =
          _round2(futureBase * (1 + growth) * personalRate * 12 * rest);
      personalPaid = _round2(personalPaid + contribution);
      balance = _round2(balance * (1 + rate * rest) + contribution);
    }

    final months = pensionMonthsOf(retireAge);
    final basic = _round2(base * (1 + index) / 2 * totalYears * 0.01);
    final account = _round2(balance / months);
    final monthly = _round2(basic + account);
    final salaryAtRetire =
        (monthlySalary * math.pow(1 + growth, futureYears)).toDouble();
    final replacement = salaryAtRetire <= 0 ? 0.0 : monthly / salaryAtRetire;
    final payback = monthly <= 0 ? 0.0 : personalPaid / (monthly * 12);

    return PensionResult(
      pensionBase: base,
      contributionIndex: index,
      paidYears: paidYears,
      futureYears: futureYears,
      totalYears: totalYears,
      monthsFactor: months,
      basicPension: basic,
      accountBalanceAtRetire: balance,
      accountPension: account,
      monthlyPension: monthly,
      replacementRate: replacement,
      personalPaidTotal: personalPaid,
      paybackYears: payback,
      monthlySalaryAtRetire: salaryAtRetire,
    );
  }

  /// 个人养老金年度缴纳策略与对应免税金额。
  ///
  /// 缴纳额在综合所得中据实扣除（现行上限 12000 元/年），领取时按 3%
  /// 单独计税，因此净税优 = 当年少缴个税 − 缴纳额 × 3%。
  static TaxBenefitResult taxBenefit(TaxBenefitInput input) {
    final annualSalary = _positive(input.annualSalary);
    final insurance = _nonNegative(input.monthlyPersonalInsurance) * 12;
    final special = _nonNegative(input.specialDeductionMonthly) * 12;
    final other = _nonNegative(input.otherAnnualDeduction);
    final taxable = _round2(
      (annualSalary - insurance - special - other - kMonthlyBasicDeduction * 12)
          .clamp(0, double.infinity)
          .toDouble(),
    );
    final cap = input.cap > 0 ? input.cap : 12000.0;
    final baselineTax = annualTaxOf(taxable);
    final bracket = bracketOf(taxable);

    final amounts = <double>{
      0,
      cap * 0.25,
      cap * 0.5,
      cap * 0.75,
      cap,
    }.toList()
      ..sort();
    final options = <TaxBenefitOption>[];
    for (final amount in amounts) {
      final after = annualTaxOf(
        (taxable - amount).clamp(0, double.infinity).toDouble(),
      );
      final saved = _round2(baselineTax - after);
      final withdrawal = _round2(amount * 0.03);
      options.add(
        TaxBenefitOption(
          amount: _round2(amount),
          taxSaved: saved,
          withdrawalTax: withdrawal,
          netBenefit: _round2(saved - withdrawal),
        ),
      );
    }
    var best = options.first;
    for (final option in options) {
      if (option.netBenefit > best.netBenefit + 0.005) best = option;
    }

    // 降档临界点：应纳税所得额刚好落到下一档上限所需的扣除额。
    double? dropAmount;
    double? nextRate;
    final lower = <TaxBracket>[
      for (final b in kAnnualTaxBrackets)
        if (b.upper < taxable) b,
    ];
    if (lower.isNotEmpty) {
      final target = lower.last.upper;
      final need = taxable - target;
      if (need > 0 && need <= cap) {
        dropAmount = _round2(need);
        nextRate = lower.last.rate;
      }
    }

    return TaxBenefitResult(
      taxableAnnual: taxable,
      marginalRate: bracket.rate,
      options: options,
      recommended: best,
      maxNetBenefit: best.netBenefit,
      cap: cap,
      bracketDropAmount: dropAmount,
      nextRate: nextRate,
    );
  }

  static double _round2(double value) => (value * 100).roundToDouble() / 100;

  static double _nonNegative(double value) =>
      value.isFinite && value > 0 ? value : 0;

  static double _positive(double value) => _nonNegative(value);
}
