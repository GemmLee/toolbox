import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/salary/salary_page.dart';
import 'package:toolbox/features/tools/salary/salary_records.dart';
import 'package:toolbox/features/tools/salary/salary_stats_page.dart';

import '../support/test_env.dart';

/// 页面较长，测试视口放大到能一次构建全部卡片，避免懒加载回收导致断言落空。
void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  // 工资计算器打开统计页时走默认 loader，这里预置一份历史工资。
  final history = <Map<String, dynamic>>[
    for (var m = 1; m <= 12; m++)
      <String, dynamic>{
        'id': '2025-$m',
        'kind': 'monthly',
        'period': '2025-${m.toString().padLeft(2, '0')}',
        'amount': 10000,
        'note': '',
      },
    <String, dynamic>{
      'id': 'bonus-2025',
      'kind': 'bonus',
      'period': '2025',
      'amount': 20000,
      'note': '',
    },
    <String, dynamic>{
      'id': '2026-1',
      'kind': 'monthly',
      'period': '2026-01',
      'amount': 12000,
      'note': '',
    },
  ];
  installCleanEnv(
    prefs: <String, Object>{
      'salary_stats_records': jsonEncode(<String, dynamic>{'records': history}),
    },
  );

  testWidgets('空态可添加按月工资记录，图表与列表同步更新', (tester) async {
    _bigScreen(tester);
    var memory = <SalaryRecord>[];
    await tester.pumpWidget(MaterialApp(
      home: SalaryStatsPage(
        loader: () async => List<SalaryRecord>.of(memory),
        saver: (records) async => memory = List<SalaryRecord>.of(records),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('这一年还没有记录，点下方按钮添加'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('salary-stats-count')))
          .data,
      '0',
    );

    final year = DateTime.now().year;
    await tester.tap(find.byKey(const ValueKey('salary-stats-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('salary-record-period')),
      '$year-03',
    );
    await tester.enterText(
      find.byKey(const ValueKey('salary-record-amount')),
      '12000',
    );
    await tester.tap(find.byKey(const ValueKey('salary-record-save')));
    await tester.pumpAndSettle();

    expect(find.text('按月工资 · $year-03'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('salary-stats-count')))
          .data,
      '1',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('salary-stats-latest')))
          .data,
      '¥12,000',
    );
  });

  testWidgets('指标与月/年尺度可切换，日期非法时不写入', (tester) async {
    _bigScreen(tester);
    final memory = <SalaryRecord>[
      const SalaryRecord(
        id: '1',
        kind: SalaryRecordKind.monthly,
        period: '2025-11',
        amount: 10000,
      ),
      const SalaryRecord(
        id: '2',
        kind: SalaryRecordKind.monthly,
        period: '2026-01',
        amount: 12000,
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: SalaryStatsPage(
        loader: () async => List<SalaryRecord>.of(memory),
        saver: (_) async {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('月度趋势'), findsOneWidget);
    // 只有两个月记录，12 月均线还没攒够 12 个月：图例照常出现，数值显示「无」。
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('salary-chart-ma12'))).data,
      'MA12 /',
    );
    await tester.tap(find.text('按年'));
    await tester.pumpAndSettle();
    expect(find.text('年度趋势'), findsOneWidget);

    await tester.tap(find.text('社保余额'));
    await tester.pumpAndSettle();
    // 切到余额后图例变成「社保账户余额」。
    expect(find.text('社保账户余额'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('salary-stats-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('salary-record-period')),
      '2026/3',
    );
    await tester.enterText(
      find.byKey(const ValueKey('salary-record-amount')),
      '9000',
    );
    await tester.tap(find.byKey(const ValueKey('salary-record-save')));
    await tester.pumpAndSettle();
    expect(find.text('日期格式不对'), findsOneWidget);
    expect(memory.length, 2);
  });

  testWidgets('税前/税后与纵轴可切换，社保基数卡片已移除', (tester) async {
    _bigScreen(tester);
    await tester.pumpWidget(const MaterialApp(home: SalaryPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('salary-tab-1')));
    await tester.pumpAndSettle();
    // AppBar 标题与展开后的页签都会显示「工资统计」，共两处。
    expect(find.text('工资统计'), findsWidgets);
    expect(find.text('按历史工资推算社保基数'), findsNothing);
    expect(find.byKey(const ValueKey('salary-stats-tax-mode')), findsOneWidget);
    // 预置了 13 个月的工资，12 月均线已经出值。
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('salary-chart-ma12'))).data,
      isNot('MA12 /'),
    );

    String latest() => tester
        .widget<Text>(find.byKey(const ValueKey('salary-stats-latest')))
        .data!;
    final gross = latest();
    await tester.tap(find.text('税后'));
    await tester.pumpAndSettle();
    expect(latest(), isNot(gross), reason: '税后金额应低于税前');
    expect(find.textContaining('记录仍按税前填写'), findsOneWidget);

    // 纵轴口径收进标题栏的图标按钮，靠 tooltip 表达当前状态。
    expect(find.byTooltip('纵轴从 0 起'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('salary-stats-zero-axis')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('纵轴自适应'), findsOneWidget);
  });

  testWidgets('记录按年度筛选，可把所选年份保存到存储空间', (tester) async {
    _bigScreen(tester);
    final year = DateTime.now().year;
    final previous = year - 1;
    final memory = <SalaryRecord>[
      SalaryRecord(
        id: 'old',
        kind: SalaryRecordKind.monthly,
        period: '$previous-05',
        amount: 8000,
      ),
      SalaryRecord(
        id: 'now',
        kind: SalaryRecordKind.monthly,
        period: '$year-02',
        amount: 12000,
      ),
    ];
    List<SalaryRecord>? exported;
    await tester.pumpWidget(MaterialApp(
      home: SalaryStatsPage(
        loader: () async => List<SalaryRecord>.of(memory),
        saver: (records) async {},
        exporter: (records) async {
          exported = records;
          return '工资记录_$year.json';
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('按月工资 · $year-02'), findsOneWidget);
    expect(find.text('按月工资 · $previous-05'), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('salary-stats-count')))
          .data,
      '1',
    );

    await tester.tap(find.byKey(const ValueKey('salary-stats-export')));
    await tester.pumpAndSettle();
    expect(exported, isNotNull);
    expect(exported!.map((e) => e.year).toSet(), <int>{year});

    await tester.tap(
      find.byKey(ValueKey('salary-stats-year-$previous')),
    );
    await tester.pumpAndSettle();
    expect(find.text('按月工资 · $previous-05'), findsOneWidget);
    expect(find.text('按月工资 · $year-02'), findsNothing);
  });
}
