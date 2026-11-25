import '../../../core/insurance.dart';
import 'salary_models.dart';
import 'tax_rules.dart';

/// 五险一金 + 个税计算核心，纯函数实现，便于单元测试。
class SalaryCalculator {
  SalaryCalculator._();

  static SalaryResult compute(SalaryInput input) {
    final gross = _nonNegative(input.gross);
    final city = input.city;

    final socialBaseRaw = input.socialBase > 0 ? input.socialBase : gross;
    final fundBaseRaw = input.fundBase > 0 ? input.fundBase : gross;

    final socialBase = _round2(city.clampSocialBase(socialBaseRaw));
    final fundBase = _round2(city.clampFundBase(fundBaseRaw));

    final lines = <ContributionLine>[];
    for (final item in kInsuranceItems) {
      final base = item.useFundBase ? fundBase : socialBase;
      final personalRate = _clampRate(input.personalRate(item.id));
      final employerRate = _clampRate(input.employerRate(item.id));
      lines.add(
        ContributionLine(
          item: item,
          base: base,
          personalRate: personalRate,
          employerRate: employerRate,
          personal: _round2(base * personalRate / 100),
          employer: _round2(base * employerRate / 100),
        ),
      );
    }

    final personalTotal = _round2(
      lines.fold<double>(0, (sum, line) => sum + line.personal),
    );
    final employerTotal = _round2(
      lines.fold<double>(0, (sum, line) => sum + line.employer),
    );

    final special = _nonNegative(input.specialDeduction);
    final month = input.month.clamp(1, 12);
    final taxableMonthly =
        _round2(gross - personalTotal - special - kMonthlyBasicDeduction);
    final taxableForTax = taxableMonthly > 0 ? taxableMonthly : 0.0;

    final tax = _round2(
      input.cumulative
          ? cumulativeTaxForMonth(monthlyTaxable: taxableForTax, month: month)
          : monthlyEstimatedTax(taxableForTax),
    );

    final net = _round2(gross - personalTotal - tax);
    final annualTaxable = _round2(taxableForTax * 12);
    final annualTax = _round2(annualTaxOf(annualTaxable));
    final annualNet = _round2(gross * 12 - personalTotal * 12 - annualTax);

    return SalaryResult(
      gross: gross,
      lines: lines,
      socialBaseUsed: socialBase,
      fundBaseUsed: fundBase,
      socialBaseAdjusted: (socialBase - socialBaseRaw).abs() > 0.005,
      fundBaseAdjusted: (fundBase - fundBaseRaw).abs() > 0.005,
      personalTotal: personalTotal,
      employerTotal: employerTotal,
      specialDeduction: special,
      month: month,
      cumulative: input.cumulative,
      taxableMonthly: taxableMonthly,
      taxableYtd: _round2(taxableForTax * month),
      tax: tax,
      net: net,
      bracket: bracketOf(taxableForTax * (input.cumulative ? month : 12)),
      annualTax: annualTax,
      annualNet: annualNet,
    );
  }

  static double _round2(double value) => (value * 100).roundToDouble() / 100;

  static double _nonNegative(double value) =>
      value.isFinite && value > 0 ? value : 0;

  static double _clampRate(double rate) {
    if (!rate.isFinite || rate < 0) return 0;
    return rate > 100 ? 100 : rate;
  }
}
