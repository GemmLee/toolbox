import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/salary/mortgage_models.dart';

MortgagePlan _plan({
  double totalPrice = 1000000,
  double downPayment = 0,
  int years = 30,
  double commercialRate = 4.9,
  double fundRate = 0,
  double fundShare = 0,
  MortgageRepayment repayment = MortgageRepayment.equalInstallment,
  DateTime? start,
}) =>
    MortgagePlan(
      id: 'p',
      name: '测试',
      start: start ?? DateTime(2026, 3),
      totalPrice: totalPrice,
      downPayment: downPayment,
      years: years,
      commercialRate: commercialRate,
      fundRate: fundRate,
      fundShare: fundShare,
      repayment: repayment,
    );

void main() {
  group('等额本息', () {
    test('100 万 / 30 年 / 4.9% 月供约 5307 元', () {
      final result = MortgageCalculator.compute(_plan());
      expect(result.firstPayment, closeTo(5307, 5));
      expect(result.fixedPayment, isTrue);
      expect(result.installments.length, 360);
      // 最后一期还完，剩余本金归零。
      expect(result.installments.last.remaining, lessThan(1));
      // 总还款 = 本金 + 利息（每期取两位，累计误差允许 2 元内）。
      expect(
        result.totalPayment,
        closeTo(result.loanAmount + result.totalInterest, 2),
      );
    });

    test('利率为 0 时月供就是本金均摊，利息为 0', () {
      final result = MortgageCalculator.compute(_plan(commercialRate: 0));
      expect(result.firstPayment, closeTo(1000000 / 360, 1));
      expect(result.totalInterest, 0);
    });
  });

  group('等额本金', () {
    test('首月最高、逐月递减，本金部分固定', () {
      final result = MortgageCalculator.compute(
        _plan(repayment: MortgageRepayment.equalPrincipal),
      );
      expect(result.fixedPayment, isFalse);
      expect(result.firstPayment, greaterThan(result.lastPayment));
      // 首月 = 本金均摊 + 全额利息。
      const expected = 1000000 / 360 + 1000000 * 4.9 / 100 / 12;
      expect(result.firstPayment, closeTo(expected, 2));
      final first = result.installments.first;
      expect(first.principal, closeTo(1000000 / 360, 2));
    });
  });

  group('组合贷', () {
    test('商业与公积金分别按各自利率计算再合并', () {
      final result = MortgageCalculator.compute(
        _plan(
          totalPrice: 1000000,
          downPayment: 500000,
          commercialRate: 4.9,
          fundRate: 2.6,
          fundShare: 0.6,
        ),
      );
      // 贷款 50 万，公积金 30 万、商业 20 万。
      expect(result.loanAmount, closeTo(500000, 0.01));
      expect(result.fundAmount, closeTo(300000, 0.01));
      expect(result.commercialAmount, closeTo(200000, 0.01));

      final commercial = MortgageCalculator.compute(
        _plan(
          totalPrice: 200000,
          commercialRate: 4.9,
        ),
      );
      final fund = MortgageCalculator.compute(
        _plan(
          totalPrice: 300000,
          commercialRate: 2.6,
        ),
      );
      expect(
        result.firstPayment,
        closeTo(commercial.firstPayment + fund.firstPayment, 1),
      );
      // 公积金部分单独可查：从账户余额扣的钱。
      expect(result.totalFundPayment, greaterThan(0));
    });
  });

  group('还款月份对齐', () {
    test('放款次月才是第 1 期，还完后为空', () {
      final result = MortgageCalculator.compute(_plan(years: 1));
      expect(result.installmentAt('2026-03'), isNull, reason: '放款当月不还');
      expect(result.installmentAt('2026-04')!.index, 1);
      expect(result.installmentAt('2027-03')!.index, 12);
      expect(result.installmentAt('2027-04'), isNull, reason: '12 期已还完');
    });

    test('公积金月供与商贷月供可分别取用', () {
      final result = MortgageCalculator.compute(
        _plan(
          totalPrice: 1000000,
          downPayment: 500000,
          commercialRate: 4.9,
          fundRate: 2.6,
          fundShare: 0.5,
        ),
      );
      final item = result.installmentAt('2026-04')!;
      expect(item.fund, closeTo(result.totalFundPayment / 360, 1));
      expect(item.commercial, closeTo(result.totalCommercialPayment / 360, 1));
      expect(item.payment, closeTo(item.fund + item.commercial, 0.02));
    });
  });
}
