import 'dart:math' as math;

/// 还款方式。
enum MortgageRepayment {
  /// 等额本息：每月还款额固定，前期利息占比高。
  equalInstallment('等额本息'),

  /// 等额本金：每月本金固定、利息递减，月供逐月下降。
  equalPrincipal('等额本金');

  const MortgageRepayment(this.label);

  final String label;

  static MortgageRepayment fromName(String? name) =>
      MortgageRepayment.values.firstWhere(
        (e) => e.name == name,
        orElse: () => MortgageRepayment.equalInstallment,
      );
}

/// 一份房贷方案（组合贷：商业 + 公积金按 [fundShare] 拆比例）。
class MortgagePlan {
  MortgagePlan({
    required this.id,
    required this.name,
    required this.start,
    required this.totalPrice,
    required this.downPayment,
    required this.years,
    required this.commercialRate,
    required this.fundRate,
    required this.fundShare,
    required this.repayment,
  });

  final String id;
  final String name;

  /// 放款日期：只取年月，用来把月供对齐到工资统计的月份。
  final DateTime start;

  /// 房屋总价与首付金额（首付按金额存，比例在页面换算）。
  final double totalPrice;
  final double downPayment;

  /// 贷款年限。
  final int years;

  /// 年利率（%）。
  final double commercialRate;
  final double fundRate;

  /// 公积金贷款占贷款总额的比例 0~1；0 表示纯商贷，1 表示纯公积金。
  final double fundShare;

  final MortgageRepayment repayment;

  /// 贷款总额 = 总价 − 首付。
  double get loanAmount => math.max(0, totalPrice - downPayment).toDouble();

  double get commercialAmount => loanAmount * (1 - fundShare);

  double get fundAmount => loanAmount * fundShare;

  /// 首付比例（0~1），总价为 0 时按 0 处理。
  double get downPaymentRatio =>
      totalPrice <= 0 ? 0 : (downPayment / totalPrice).clamp(0, 1).toDouble();

  int get months => math.max(1, years * 12);

  MortgagePlan copyWith({
    String? name,
    DateTime? start,
    double? totalPrice,
    double? downPayment,
    int? years,
    double? commercialRate,
    double? fundRate,
    double? fundShare,
    MortgageRepayment? repayment,
  }) =>
      MortgagePlan(
        id: id,
        name: name ?? this.name,
        start: start ?? this.start,
        totalPrice: totalPrice ?? this.totalPrice,
        downPayment: downPayment ?? this.downPayment,
        years: years ?? this.years,
        commercialRate: commercialRate ?? this.commercialRate,
        fundRate: fundRate ?? this.fundRate,
        fundShare: fundShare ?? this.fundShare,
        repayment: repayment ?? this.repayment,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'start': '${start.year.toString().padLeft(4, '0')}-'
            '${start.month.toString().padLeft(2, '0')}',
        'totalPrice': totalPrice,
        'downPayment': downPayment,
        'years': years,
        'commercialRate': commercialRate,
        'fundRate': fundRate,
        'fundShare': fundShare,
        'repayment': repayment.name,
      };

  factory MortgagePlan.fromJson(Map<String, dynamic> json) {
    final rawStart = (json['start'] ?? '').toString();
    final parts = rawStart.split('-');
    final year = parts.isNotEmpty ? int.tryParse(parts.first) ?? 0 : 0;
    final month = parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1;
    return MortgagePlan(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      start:
          DateTime(year <= 0 ? DateTime.now().year : year, month.clamp(1, 12)),
      totalPrice: _number(json['totalPrice']),
      downPayment: _number(json['downPayment']),
      years: (json['years'] is int)
          ? json['years'] as int
          : int.tryParse('${json['years']}') ?? 30,
      commercialRate: _number(json['commercialRate']),
      fundRate: _number(json['fundRate']),
      fundShare: _number(json['fundShare']).clamp(0, 1).toDouble(),
      repayment: MortgageRepayment.fromName(json['repayment'] as String?),
    );
  }

  static double _number(Object? value) => switch (value) {
        final double v => v,
        final int v => v.toDouble(),
        final String v => double.tryParse(v) ?? 0,
        _ => 0,
      };
}

/// 一期还款（组合贷两部分合并后的结果）。
class MortgageInstallment {
  const MortgageInstallment({
    required this.index,
    required this.payment,
    required this.commercial,
    required this.fund,
    required this.principal,
    required this.interest,
    required this.remaining,
  });

  /// 第几期，从 1 开始。
  final int index;

  /// 本月应还总额（商业 + 公积金）。
  final double payment;

  /// 其中商业贷款部分（这部分才从工资里扣）。
  final double commercial;

  /// 其中公积金贷款部分（从公积金账户余额扣，不扣工资）。
  final double fund;

  final double principal;
  final double interest;
  final double remaining;
}

/// 房贷计算结果 + 摊销表。
class MortgageResult {
  MortgageResult({
    required this.plan,
    required this.installments,
  });

  final MortgagePlan plan;
  final List<MortgageInstallment> installments;

  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  double get loanAmount => plan.loanAmount;
  double get commercialAmount => plan.commercialAmount;
  double get fundAmount => plan.fundAmount;

  bool get isEmpty => installments.isEmpty;

  double get firstPayment =>
      installments.isEmpty ? 0 : installments.first.payment;

  double get lastPayment =>
      installments.isEmpty ? 0 : installments.last.payment;

  /// 等额本息月供固定；等额本金首末差就是「每月少还多少」。
  bool get fixedPayment => plan.repayment == MortgageRepayment.equalInstallment;

  double get totalInterest =>
      _round2(installments.fold<double>(0, (sum, item) => sum + item.interest));

  double get totalPayment =>
      _round2(installments.fold<double>(0, (sum, item) => sum + item.payment));

  /// 公积金月供总额（从账户余额扣）。
  double get totalFundPayment =>
      _round2(installments.fold<double>(0, (sum, item) => sum + item.fund));

  /// 商业贷款月供总额（从工资扣）。
  double get totalCommercialPayment => _round2(
      installments.fold<double>(0, (sum, item) => sum + item.commercial));

  /// 该自然月要还哪一期。
  ///
  /// 约定「放款次月开始还第 1 期」：放款当月不还款，所以 2026-03 放款时
  /// 2026-03 返回 null、2026-04 返回第 1 期。放款前和还完后也返回 null。
  MortgageInstallment? installmentAt(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length < 2) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (y == null || m == null) return null;
    final diff = (y - plan.start.year) * 12 + (m - plan.start.month);
    final index = diff; // 放款当月 diff = 0 → 次月 diff = 1 → 第 1 期
    if (index < 1 || index > installments.length) return null;
    return installments[index - 1];
  }

  /// 该月的商业贷款月供（从工资里扣的钱）。
  double commercialAt(String monthKey) =>
      installmentAt(monthKey)?.commercial ?? 0;

  /// 该月的公积金贷款月供（从公积金账户扣的钱）。
  double fundAt(String monthKey) => installmentAt(monthKey)?.fund ?? 0;
}

/// 纯计算层：不碰 UI 与存储，方便单测覆盖边界。
class MortgageCalculator {
  MortgageCalculator._();

  /// 计算一份方案的完整摊销表。
  ///
  /// 组合贷拆成商业 / 公积金两笔分别按各自利率与还款方式计算，再按期合并；
  /// 两笔期数相同，合并时逐期累加即可。
  static MortgageResult compute(MortgagePlan plan) {
    final months = plan.months;
    final commercial = _schedule(
      plan.commercialAmount,
      plan.commercialRate,
      months,
      plan.repayment,
    );
    final fund = _schedule(
      plan.fundAmount,
      plan.fundRate,
      months,
      plan.repayment,
    );
    final list = <MortgageInstallment>[];
    for (var i = 0; i < months; i++) {
      final c = i < commercial.length ? commercial[i] : null;
      final f = i < fund.length ? fund[i] : null;
      final payment = (c?.payment ?? 0) + (f?.payment ?? 0);
      if (payment <= 0) continue;
      list.add(
        MortgageInstallment(
          index: i + 1,
          payment: _round2(payment),
          commercial: _round2(c?.payment ?? 0),
          fund: _round2(f?.payment ?? 0),
          principal: _round2((c?.principal ?? 0) + (f?.principal ?? 0)),
          interest: _round2((c?.interest ?? 0) + (f?.interest ?? 0)),
          remaining: _round2((c?.remaining ?? 0) + (f?.remaining ?? 0)),
        ),
      );
    }
    return MortgageResult(plan: plan, installments: list);
  }

  /// 单笔贷款的摊销表（内部口径，不四舍五入，最后统一取两位）。
  static List<_RawInstallment> _schedule(
    double principal,
    double annualRate,
    int months,
    MortgageRepayment mode,
  ) {
    if (principal <= 0 || months <= 0) return const <_RawInstallment>[];
    final rate = annualRate.clamp(0, 100) / 100 / 12;
    final list = <_RawInstallment>[];
    var remaining = principal;
    if (mode == MortgageRepayment.equalInstallment) {
      final payment = rate <= 0
          ? principal / months
          : principal *
              rate *
              math.pow(1 + rate, months) /
              (math.pow(1 + rate, months) - 1);
      for (var i = 1; i <= months; i++) {
        final interest = remaining * rate;
        var principalPart = payment - interest;
        if (i == months) principalPart = remaining;
        remaining = math.max(0, remaining - principalPart).toDouble();
        list.add(_RawInstallment(
          payment: principalPart + interest,
          principal: principalPart,
          interest: interest,
          remaining: remaining,
        ));
      }
    } else {
      final principalPart = principal / months;
      for (var i = 1; i <= months; i++) {
        final interest = remaining * rate;
        final part = i == months ? remaining : principalPart;
        remaining = math.max(0, remaining - part).toDouble();
        list.add(_RawInstallment(
          payment: part + interest,
          principal: part,
          interest: interest,
          remaining: remaining,
        ));
      }
    }
    return list;
  }

  static double _round2(double v) => (v * 100).roundToDouble() / 100;
}

class _RawInstallment {
  const _RawInstallment({
    required this.payment,
    required this.principal,
    required this.interest,
    required this.remaining,
  });

  final double payment;
  final double principal;
  final double interest;
  final double remaining;
}
