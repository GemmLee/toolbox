import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/salary/city_rules.dart';
import 'package:toolbox/features/tools/salary/salary_records.dart';
import 'package:toolbox/features/tools/salary/salary_stats.dart';

SalaryRecord _r(SalaryRecordKind kind, String period, double amount) =>
    SalaryRecord(
      id: '$period-${amount.toStringAsFixed(0)}',
      kind: kind,
      period: period,
      amount: amount,
    );

void main() {
  final city = CityRules.byId('ningbo');
  const rates = <String, double>{
    'pension': 8,
    'medical': 2,
    'unemployment': 0.5,
    'injury': 0,
    'maternity': 0,
    'fund': 12,
  };

  final sample = <SalaryRecord>[
    _r(SalaryRecordKind.monthly, '2026-01', 10000),
    _r(SalaryRecordKind.daily, '2026-01-15', 500),
    _r(SalaryRecordKind.daily, '2026-03-02', 8000),
    _r(SalaryRecordKind.bonus, '2026', 12000),
  ];

  group('收入曲线', () {
    test('按日汇总到月份、缺月补零、年终奖记在 12 月', () {
      final points = SalaryStats.incomeSeries(sample, SalaryScale.month);
      expect(points.first.key, '2026-01');
      expect(points.first.value, 10500);
      expect(points[1].key, '2026-02');
      expect(points[1].value, 0);
      expect(points[2].value, 8000);
      expect(points.last.key, '2026-12');
      expect(points.last.value, 12000);
    });

    test('年尺度按年汇总全部记录', () {
      final points = SalaryStats.incomeSeries(sample, SalaryScale.year);
      expect(points.length, 1);
      expect(points.single.value, 30500);
    });

    test('月尺度最多保留最近 36 个月', () {
      final records = <SalaryRecord>[
        _r(SalaryRecordKind.monthly, '2020-01', 100),
        _r(SalaryRecordKind.monthly, '2026-11', 200),
      ];
      final points = SalaryStats.incomeSeries(records, SalaryScale.month);
      expect(points.length, 36);
      expect(points.last.key, '2026-11');
    });

    test('脏数据（空日期 / 非正金额）不进曲线', () {
      expect(
        SalaryStats.incomeSeries(
          <SalaryRecord>[
            _r(SalaryRecordKind.monthly, '', 100),
            _r(SalaryRecordKind.monthly, '2026-01', -5),
          ],
          SalaryScale.month,
        ),
        isEmpty,
      );
    });
  });

  group('社保账户余额', () {
    test('逐月累计个人缴纳额，年终奖不计入缴费', () {
      final points = SalaryStats.socialBalanceSeries(
        sample,
        scale: SalaryScale.month,
        city: city,
        personalRates: rates,
      );
      expect(points.length, 3);
      expect(points.first.value, closeTo(2362.5, 0.01));
      expect(points[1].value, closeTo(2362.5, 0.01));
      expect(points.last.value, closeTo(4162.5, 0.01));
    });

    test('年尺度取每年年末余额', () {
      final points = SalaryStats.socialBalanceSeries(
        sample,
        scale: SalaryScale.year,
        city: city,
        personalRates: rates,
      );
      expect(points.length, 1);
      expect(points.single.key, '2026');
      expect(points.single.value, closeTo(4162.5, 0.01));
    });

    test('指定社保/公积金基数时按固定基数缴纳', () {
      final contribution = SalaryStats.personalContribution(
        gross: 12000,
        city: city,
        personalRates: rates,
        socialBase: 8000,
        fundBase: 9000,
      );
      // 8000 × 10.5% + 9000 × 12% = 840 + 1080
      expect(contribution, closeTo(1920, 0.01));
    });
  });

  group('按历史工资推算社保基数', () {
    test('优先取上年度月平均工资（含年终奖）', () {
      final records = <SalaryRecord>[
        for (var m = 1; m <= 12; m++)
          _r(SalaryRecordKind.monthly, '2025-${m.toString().padLeft(2, '0')}',
              10000),
        _r(SalaryRecordKind.bonus, '2025', 20000),
        _r(SalaryRecordKind.monthly, '2026-01', 12000),
      ];
      final suggestion = SalaryStats.suggestBase(records, city);
      expect(suggestion, isNotNull);
      expect(suggestion!.year, 2025);
      expect(suggestion.averageMonthly, closeTo(11666.67, 0.01));
      expect(suggestion.socialBase, closeTo(11666.67, 0.01));
    });

    test('上一年没有记录时退回最近有记录的一年，并受城市上限约束', () {
      final suggestion = SalaryStats.suggestBase(
        <SalaryRecord>[_r(SalaryRecordKind.monthly, '2025-01', 1000000)],
        city,
      );
      expect(suggestion!.year, 2025);
      expect(suggestion.socialBase, city.socialBaseMax);
      expect(suggestion.fundBase, city.fundBaseMax);
    });

    test('没有记录返回 null', () {
      expect(SalaryStats.suggestBase(<SalaryRecord>[], city), isNull);
    });
  });

  group('税后曲线与平均线', () {
    test('税后金额按五险一金与个税扣除，且明显高于 0', () {
      final net = SalaryStats.netOfGross(
        gross: 12000,
        city: city,
        personalRates: rates,
        specialDeduction: 1000,
      );
      expect(net, lessThan(12000));
      expect(net, greaterThan(8000));

      final grossSeries = SalaryStats.incomeSeries(
        <SalaryRecord>[_r(SalaryRecordKind.monthly, '2026-01', 12000)],
        SalaryScale.year,
      );
      final netSeries = SalaryStats.incomeSeries(
        <SalaryRecord>[_r(SalaryRecordKind.monthly, '2026-01', 12000)],
        SalaryScale.year,
        transform: (v) => SalaryStats.netOfGross(
          gross: v,
          city: city,
          personalRates: rates,
        ),
      );
      expect(netSeries.single.value, lessThan(grossSeries.single.value));
    });

    test('平均线从第一条有记录算起，忽略前面的 0 月', () {
      final points = <SalaryPoint>[
        const SalaryPoint('2025-01', '2025/1', 0),
        const SalaryPoint('2025-02', '2025/2', 10000),
        const SalaryPoint('2025-03', '2025/3', 0),
        const SalaryPoint('2025-04', '2025/4', 14000),
      ];
      expect(SalaryStats.averageOf(points), 12000);
      expect(SalaryStats.averageOf(<SalaryPoint>[]), isNull);
      expect(
        SalaryStats.averageOf(<SalaryPoint>[
          const SalaryPoint('2025-01', '2025/1', 0),
        ]),
        isNull,
      );
    });

    test('12 月均线：满 12 个月才有值，前面不足 12 个点为 null', () {
      final points = <SalaryPoint>[
        for (var i = 1; i <= 14; i++)
          SalaryPoint(
            '2025-${i.toString().padLeft(2, '0')}',
            '2025/$i',
            10000.0 + i * 100,
          ),
      ];
      final ma = SalaryStats.movingAverage(points);
      expect(ma.length, points.length);
      expect(ma.take(11).every((v) => v == null), isTrue);
      // 第 12 个点 = 前 12 个月的平均（10100 … 11200）。
      expect(ma[11], 10650);
      expect(ma[13], 10850);
    });

    test('12 月均线：有记录的月份不足 12 个时整条线为空', () {
      final points = <SalaryPoint>[
        for (var i = 1; i <= 24; i++)
          SalaryPoint(
            '2025-${(i % 12 + 1).toString().padLeft(2, '0')}',
            '2025/$i',
            i <= 3 ? 10000 : 0,
          ),
      ];
      expect(points.length, greaterThan(12));
      expect(SalaryStats.movingAverage(points).every((v) => v == null), isTrue);
      expect(
        SalaryStats.movingAverage(<SalaryPoint>[]).isEmpty,
        isTrue,
      );
    });
  });

  group('记录序列化', () {
    test('JSON 往返保留类型、周期与金额', () {
      const record = SalaryRecord(
        id: 'a',
        kind: SalaryRecordKind.bonus,
        period: '2025',
        amount: 30000,
        note: '年终',
      );
      final restored = SalaryRecord.fromJson(record.toJson());
      expect(restored.kind, SalaryRecordKind.bonus);
      expect(restored.period, '2025');
      expect(restored.amount, 30000);
      expect(restored.note, '年终');
      expect(restored.monthKey, '2025-12');
    });
  });
}
