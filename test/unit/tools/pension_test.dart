import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/salary/pension_calculator.dart';
import 'package:toolbox/features/tools/salary/pension_policy.dart';

import '../../support/test_env.dart';

void main() {
  installCleanEnv();

  group('城市养老政策与计发月数', () {
    test('内置 2025 年各地计发基数', () {
      expect(PensionPolicy.byCity('shanghai').pensionBase, 12434);
      expect(PensionPolicy.byCity('beijing').pensionBase, 12049);
      expect(PensionPolicy.byCity('shenzhen').pensionBase, 11293);
      expect(PensionPolicy.byCity('guangzhou').pensionBase, 9493);
      expect(PensionPolicy.byCity('hangzhou').pensionBase, 8433);
      expect(PensionPolicy.byCity('ningbo').pensionBase, 8433);
      expect(PensionPolicy.byCity('xian').pensionBase, 7881);
      // 深圳单列，高于广东其他地区
      expect(PensionPolicy.byCity('shenzhen').pensionBase,
          greaterThan(PensionPolicy.byCity('guangzhou').pensionBase));
      expect(PensionPolicy.all.length, 8);
    });

    test('未知城市回退到第一条，自定义计发基数可覆盖', () {
      final policy = PensionPolicy.byCity('not-exists');
      expect(policy.cityId, PensionPolicy.all.first.cityId);
      final r = PensionCalculator.pension(
        PensionInput(
          policy: policy,
          annualSalary: 120000,
          monthlyBase: 10000,
          currentAge: 35,
          retireAge: 60,
          paidYears: 10,
          salaryGrowth: 0,
          customPensionBase: 20000,
        ),
      );
      expect(r.pensionBase, 20000);
      expect(r.contributionIndex, closeTo(0.6, 0.001));
    });

    test('计发月数按退休年龄查表并插值', () {
      expect(pensionMonthsOf(50), 195);
      expect(pensionMonthsOf(55), 170);
      expect(pensionMonthsOf(60), 139);
      expect(pensionMonthsOf(65), 101);
      expect(pensionMonthsOf(57.5), closeTo(154.5, 0.001));
      expect(pensionMonthsOf(30), 233);
      expect(pensionMonthsOf(80), 56);
    });
  });

  group('养老金领取测算', () {
    PensionInput input(String city) => PensionInput(
          policy: PensionPolicy.byCity(city),
          annualSalary: 240000,
          monthlyBase: 20000,
          currentAge: 35,
          retireAge: 60,
          paidYears: 10,
          salaryGrowth: 0.03,
        );

    test('月养老金 = 基础养老金 + 个人账户养老金', () {
      final r = PensionCalculator.pension(input('shanghai'));
      expect(r.monthlyPension,
          closeTo(r.basicPension + r.accountPension, 0.02));
      expect(r.totalYears, 35);
      expect(r.futureYears, 25);
      expect(r.monthsFactor, 139);
      expect(r.monthlyPension, greaterThan(0));
      expect(r.replacementRate, inInclusiveRange(0, 1));
      expect(r.paybackYears, greaterThan(0));
    });

    test('计发基数越高的城市，测算养老金越高', () {
      final shanghai = PensionCalculator.pension(input('shanghai'));
      final xian = PensionCalculator.pension(input('xian'));
      expect(shanghai.basicPension, greaterThan(xian.basicPension));
      expect(shanghai.monthlyPension, greaterThan(xian.monthlyPension));
    });

    test('缴费年限越长，养老金越高', () {
      final a = PensionCalculator.pension(input('ningbo'));
      final b = PensionCalculator.pension(
        PensionInput(
          policy: PensionPolicy.byCity('ningbo'),
          annualSalary: 240000,
          monthlyBase: 20000,
          currentAge: 30,
          retireAge: 60,
          paidYears: 20,
          salaryGrowth: 0.03,
        ),
      );
      expect(b.totalYears, greaterThan(a.totalYears));
      expect(b.monthlyPension, greaterThan(a.monthlyPension));
    });

    test('填了个人账户余额时优先采用', () {
      final noBalance = PensionCalculator.pension(input('beijing'));
      final withBalance = PensionCalculator.pension(
        PensionInput(
          policy: PensionPolicy.byCity('beijing'),
          annualSalary: 240000,
          monthlyBase: 20000,
          currentAge: 35,
          retireAge: 60,
          paidYears: 10,
          salaryGrowth: 0.03,
          accountBalance: 500000,
        ),
      );
      expect(withBalance.accountBalanceAtRetire,
          greaterThan(noBalance.accountBalanceAtRetire));
      expect(withBalance.accountPension,
          greaterThan(noBalance.accountPension));
    });

    test('空输入不产生 NaN / 负数', () {
      final r = PensionCalculator.pension(
        PensionInput(
          policy: PensionPolicy.byCity('ningbo'),
          annualSalary: 0,
          monthlyBase: 0,
          currentAge: 35,
          retireAge: 60,
          paidYears: 0,
        ),
      );
      expect(r.monthlyPension.isFinite, isTrue);
      expect(r.monthlyPension, greaterThanOrEqualTo(0));
      expect(r.replacementRate.isFinite, isTrue);
      expect(r.paybackYears.isFinite, isTrue);
    });
  });

  group('个人养老金税优', () {
    test('高边际税率建议顶格缴纳，免税金额按税率计算', () {
      final r = PensionCalculator.taxBenefit(
        const TaxBenefitInput(
          annualSalary: 300000,
          monthlyPersonalInsurance: 0,
        ),
      );
      expect(r.taxableAnnual, 240000);
      expect(r.marginalRate, 0.20);
      expect(r.recommended.amount, 12000);
      expect(r.recommended.taxSaved, closeTo(2400, 0.01));
      expect(r.recommended.withdrawalTax, closeTo(360, 0.01));
      expect(r.recommended.netBenefit, closeTo(2040, 0.01));
      expect(r.worthIt, isTrue);
      expect(r.options.length, 5);
      expect(r.options.first.amount, 0);
      expect(r.options.first.taxSaved, 0);
      for (final option in r.options) {
        expect(option.netBenefit,
            closeTo(option.taxSaved - option.withdrawalTax, 0.01));
      }
    });

    test('低收入者（3% 档）缴纳没有净税优', () {
      final r = PensionCalculator.taxBenefit(
        const TaxBenefitInput(annualSalary: 60000),
      );
      expect(r.taxableAnnual, 0);
      expect(r.worthIt, isFalse);
      expect(r.recommended.amount, 0);
      expect(r.maxNetBenefit, 0);
    });

    test('跨税率档时给出降档临界点，不盲目顶格', () {
      final r = PensionCalculator.taxBenefit(
        const TaxBenefitInput(annualSalary: 100000),
      );
      expect(r.taxableAnnual, 40000);
      expect(r.marginalRate, 0.10);
      expect(r.bracketDropAmount, 4000);
      expect(r.nextRate, 0.03);
      // 超过降档点后边际节税 3%，与领取税 3% 持平，净收益不再增加
      expect(r.recommended.amount, lessThan(12000));
      expect(r.recommended.amount, greaterThan(0));
    });

    test('五险一金与专项附加扣除会压低应税所得额', () {
      final plain = PensionCalculator.taxBenefit(
        const TaxBenefitInput(annualSalary: 200000),
      );
      final deducted = PensionCalculator.taxBenefit(
        const TaxBenefitInput(
          annualSalary: 200000,
          monthlyPersonalInsurance: 3000,
          specialDeductionMonthly: 2000,
        ),
      );
      expect(deducted.taxableAnnual,
          closeTo(plain.taxableAnnual - 60000, 0.01));
      expect(deducted.recommended.taxSaved,
          lessThanOrEqualTo(plain.recommended.taxSaved));
    });

    test('空输入不产生负数税额', () {
      final r = PensionCalculator.taxBenefit(
        const TaxBenefitInput(annualSalary: 0),
      );
      expect(r.taxableAnnual, 0);
      expect(r.recommended.amount, 0);
      expect(r.options.every((o) => o.taxSaved >= 0), isTrue);
    });
  });
}
