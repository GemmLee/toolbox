import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/salary/city_rules.dart';
import 'package:toolbox/features/tools/salary/salary_calculator.dart';
import 'package:toolbox/features/tools/salary/salary_models.dart';
import 'package:toolbox/features/tools/salary/tax_rules.dart';

const CityRules testCity = CityRules(
  id: 'test',
  name: '测试城市',
  socialBaseMin: 0,
  socialBaseMax: 0,
  fundBaseMin: 0,
  fundBaseMax: 0,
  personalRates: <String, double>{
    'pension': 8,
    'medical': 2,
    'unemployment': 0.5,
    'injury': 0,
    'maternity': 0,
    'fund': 12,
  },
  employerRates: <String, double>{
    'pension': 16,
    'medical': 9,
    'unemployment': 0.5,
    'injury': 0.2,
    'maternity': 0,
    'fund': 12,
  },
);

SalaryInput buildInput({
  double gross = 12000,
  double socialBase = 0,
  double fundBase = 0,
  double special = 0,
  int month = 1,
  bool cumulative = true,
}) {
  return SalaryInput(
    gross: gross,
    socialBase: socialBase,
    fundBase: fundBase,
    city: testCity,
    personalRates: testCity.personalRates,
    employerRates: testCity.employerRates,
    specialDeduction: special,
    month: month,
    cumulative: cumulative,
  );
}

void main() {
  group('五险一金', () {
    test('按工资逐项计算个人与单位缴纳额', () {
      final result = SalaryCalculator.compute(buildInput());
      final Map<String, ContributionLine> lines = {
        for (final line in result.lines) line.item.id: line,
      };

      expect(lines['pension']!.personal, 960);
      expect(lines['pension']!.employer, 1920);
      expect(lines['medical']!.personal, 240);
      expect(lines['unemployment']!.personal, 60);
      expect(lines['fund']!.personal, 1440);

      expect(result.personalTotal, 2700);
      expect(result.employerTotal, 4524);
    });

    test('基数为空时跟随工资，显式基数优先', () {
      final follow = SalaryCalculator.compute(buildInput(gross: 8000));
      expect(follow.socialBaseUsed, 8000);
      expect(follow.lines.first.personal, 640);

      final explicit = SalaryCalculator.compute(
        buildInput(gross: 20000, socialBase: 10000, fundBase: 8000),
      );
      expect(explicit.socialBaseUsed, 10000);
      expect(explicit.fundBaseUsed, 8000);
      expect(explicit.lines.first.personal, 800);
      expect(explicit.lines.last.personal, 960);
    });

    test('基数受城市上下限约束并标记调整', () {
      const capped = CityRules(
        id: 'capped',
        name: '上限城市',
        socialBaseMin: 4000,
        socialBaseMax: 20000,
        fundBaseMin: 2000,
        fundBaseMax: 15000,
        personalRates: <String, double>{'pension': 8, 'fund': 12},
        employerRates: <String, double>{'pension': 16, 'fund': 12},
      );
      final input = SalaryInput(
        gross: 30000,
        city: capped,
        personalRates: capped.personalRates,
        employerRates: capped.employerRates,
      );
      final result = SalaryCalculator.compute(input);
      expect(result.socialBaseUsed, 20000);
      expect(result.fundBaseUsed, 15000);
      expect(result.socialBaseAdjusted, isTrue);
      expect(result.fundBaseAdjusted, isTrue);

      final belowMin = SalaryCalculator.compute(
        SalaryInput(
          gross: 2000,
          city: capped,
          personalRates: capped.personalRates,
          employerRates: capped.employerRates,
        ),
      );
      expect(belowMin.socialBaseUsed, 4000);
      expect(belowMin.fundBaseUsed, 2000);
    });
  });

  group('个税', () {
    test('月度简易估算：月应纳税所得额 4300 对应 10% 档', () {
      // 12000 - 2700（五险一金）- 5000 = 4300
      final result =
          SalaryCalculator.compute(buildInput(cumulative: false));
      expect(result.taxableMonthly, 4300);
      expect(result.tax, 220);
      expect(result.bracket.rate, 0.10);
      expect(result.net, 9080);
    });

    test('累计预扣：跨档月份税额跳升', () {
      final january = SalaryCalculator.compute(buildInput(month: 1));
      final june = SalaryCalculator.compute(buildInput(month: 6));
      final august = SalaryCalculator.compute(buildInput(month: 8));
      final september = SalaryCalculator.compute(buildInput(month: 9));

      expect(january.tax, 129);
      expect(june.tax, 129);
      expect(august.tax, 129);
      // 累计 9 个月应纳税所得额 38700，进入 10% 档
      expect(september.tax, 318);
      expect(september.bracket.rate, 0.10);
    });

    test('专项附加扣除降低应纳税所得额', () {
      final withSpecial = SalaryCalculator.compute(
        buildInput(special: 2000, cumulative: false),
      );
      expect(withSpecial.taxableMonthly, 2300);
      expect(withSpecial.tax, 69);
      expect(withSpecial.net, 9231);
    });

    test('零收入不产生负数税额', () {
      final result = SalaryCalculator.compute(buildInput(gross: 0));
      expect(result.tax, 0);
      expect(result.net, 0);
      expect(result.personalTotal, 0);
    });

    test('累计预扣税额按累计所得分段计算', () {
      expect(
        cumulativeTaxForMonth(monthlyTaxable: 4300, month: 1),
        closeTo(129, 0.01),
      );
      expect(
        cumulativeTaxForMonth(monthlyTaxable: 4300, month: 10),
        closeTo(430, 0.01),
      );
      // 年度汇总：4300 × 12 = 51600 -> 51600 × 10% - 2520 = 2640
      expect(annualTaxOf(51600), closeTo(2640, 0.01));
    });
  });

  group('年度预估', () {
    test('12 个月到手与单位成本', () {
      final result = SalaryCalculator.compute(buildInput());
      expect(result.annualTax, 2640);
      expect(result.annualNet, closeTo(12000 * 12 - 2700 * 12 - 2640, 0.01));
      expect(result.annualEmployerCost, (12000 + 4524) * 12);
      // 默认累计预扣、1 月，个税 129 → 到手 9171
      expect(result.net, 9171);
      expect(result.takeHomeRate, closeTo(9171 / 12000, 0.0001));
    });
  });
}
