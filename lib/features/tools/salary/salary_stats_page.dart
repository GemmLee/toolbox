import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../core/insurance.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/storage/app_files.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/mini_segmented.dart';
import 'city_rules.dart';
import 'mortgage_models.dart';
import 'mortgage_store.dart';
import 'salary_records.dart';
import 'salary_settings.dart';
import 'salary_stats.dart';
import 'salary_trend_chart.dart';

/// 曲线看什么：工资收入，或与工资计算器同口径的个人五险一金累计。
enum _ChartMetric { income, balance }

/// 工资口径：记录始终按税前保存，切到税后只在出图时用当前设置换算。
enum _TaxMode { gross, net }

/// 房贷和工资曲线的关系。
enum _MortgageMode {
  /// 不显示房贷。
  off('不叠加'),

  /// 把月供作为一条独立虚线叠在图上。
  overlay('叠加月供'),

  /// 不画月供，画「扣掉房贷后的剩余工资」。
  deducted('扣除房贷'),
  ;

  const _MortgageMode(this.label);

  final String label;
}

/// 工资统计：按日/按月记录工资、按年记录年终奖，查看月/年两种尺度的
/// 税前 / 税后收入与社保账户余额曲线。
class SalaryStatsPage extends StatefulWidget {
  const SalaryStatsPage({
    super.key,
    this.loader,
    this.saver,
    this.exporter,
    this.cityId,
    this.personalRates,
    this.socialBase = 0,
    this.fundBase = 0,
    this.specialDeduction = 0,
    this.embedded = false,
    this.mortgageRevision,
  });

  /// 注入点：测试用内存实现，避免 FakeAsync 下跑真实 SharedPreferences /
  /// 文件 I/O。
  final Future<List<SalaryRecord>> Function()? loader;
  final Future<void> Function(List<SalaryRecord>)? saver;
  final Future<String> Function(List<SalaryRecord>)? exporter;

  final String? cityId;
  final Map<String, double>? personalRates;
  final double socialBase;
  final double fundBase;
  final double specialDeduction;

  /// 作为工资计算器的页签内嵌：不套 Scaffold，工具按钮压到内容顶部。
  final bool embedded;

  /// 房贷方案保存 / 切换时自增，页面据此重读方案并重算叠加曲线。
  final Listenable? mortgageRevision;

  @override
  State<SalaryStatsPage> createState() => _SalaryStatsPageState();
}

class _SalaryStatsPageState extends State<SalaryStatsPage>
    with AutomaticKeepAliveClientMixin {
  List<SalaryRecord> _records = <SalaryRecord>[];
  bool _loading = true;
  SalaryScale _scale = SalaryScale.month;
  _ChartMetric _metric = _ChartMetric.income;
  _TaxMode _taxMode = _TaxMode.gross;
  _MortgageMode _mortgageMode = _MortgageMode.off;
  bool _zeroBased = true;
  late int _selectedYear = DateTime.now().year;

  /// 已保存的房贷方案与当前选中的那份（没有方案时为空）。
  List<MortgagePlan> _mortgagePlans = <MortgagePlan>[];
  MortgagePlan? _mortgage;

  CityRules get _city => CityRules.byId(_settings?.cityId ?? widget.cityId);

  /// 「到手工资」页签最近一次生效的口径；没打开过时退回构造参数 / 城市默认。
  SalarySettings? get _settings => SalarySettings.current.value;

  Map<String, double> get _rates =>
      _settings?.personalRates ??
      widget.personalRates ??
      <String, double>{
        for (final item in kInsuranceItems)
          item.id: _city.personalRate(item.id),
      };

  double get _socialBase => _settings?.socialBase ?? widget.socialBase;

  double get _fundBase => _settings?.fundBase ?? widget.fundBase;

  double get _specialDeduction =>
      _settings?.specialDeduction ?? widget.specialDeduction;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadRecords();
    _loadMortgage();
    widget.mortgageRevision?.addListener(_loadMortgage);
    SalarySettings.current.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.mortgageRevision?.removeListener(_loadMortgage);
    SalarySettings.current.removeListener(_onSettingsChanged);
    super.dispose();
  }

  /// 房贷方案只在「工资 × 税后」下参与出图，读一次缓存足够。
  Future<void> _loadMortgage() async {
    final plans = await MortgageStore.load();
    final selected = await MortgageStore.loadSelectedId();
    if (!mounted) return;
    MortgagePlan? plan;
    for (final item in plans) {
      if (item.id == selected) {
        plan = item;
        break;
      }
    }
    plan ??= plans.isEmpty ? null : plans.first;
    setState(() {
      _mortgagePlans = plans;
      _mortgage = plan;
      if (plan == null && _mortgageMode != _MortgageMode.off) {
        _mortgageMode = _MortgageMode.off;
      }
    });
  }

  Future<void> _loadRecords() async {
    final records = await (widget.loader ?? SalaryRecordStore.load)();
    if (!mounted) return;
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  Future<void> _write(List<SalaryRecord> records) async {
    await (widget.saver ?? SalaryRecordStore.save)(records);
    if (!mounted) return;
    setState(() => _records = records);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final points = _points;
    final theme = Theme.of(context);
    final color = _metric == _ChartMetric.income
        ? theme.colorScheme.primary
        : const Color(0xFFF0A22E);
    final legend = _metric == _ChartMetric.income ? tr('工资收入') : tr('社保账户余额');
    // 12 月均线只在「按月 × 工资」的曲线上有意义；余额是累计值，不画。
    final movingAverage =
        _metric == _ChartMetric.income && _scale == SalaryScale.month
            ? SalaryStats.movingAverage(points)
            : null;
    final visible = _visibleRecords;
    final extraLines = _extraLines(points);

    final content = _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: <Widget>[
              _controlBar(),
              const SizedBox(height: 10),
              _chartCard(
                context,
                points,
                color,
                legend,
                movingAverage,
                extraLines,
              ),
              const SizedBox(height: 10),
              _recordSection(context, visible),
              const SizedBox(height: 8),
              SmallHint(
                text: tr('工资记录按税前填写，仅保存在本机；税后按当前五险一金与个税设置估算'),
              ),
            ],
          );

    final addButton = SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: FilledButton.icon(
        key: const ValueKey('salary-stats-add'),
        onPressed: _addRecord,
        icon: const Icon(Icons.add, size: 20),
        label: Text(tr('添加工资记录')),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
        ),
      ),
    );

    if (widget.embedded) {
      // 作为工资计算器的页签：外层已经有 AppBar，这里只保留内容 + 底部按钮。
      return Column(
        children: <Widget>[
          Expanded(child: content),
          addButton,
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('工资统计')),
        actions: <Widget>[
          IconButton(
            key: const ValueKey('salary-stats-zero-axis'),
            tooltip: _zeroBased ? tr('纵轴从 0 起') : tr('纵轴自适应'),
            icon: Icon(
              _zeroBased ? Icons.straighten : Icons.unfold_more,
              size: 20,
            ),
            onPressed: () => setState(() => _zeroBased = !_zeroBased),
          ),
          IconButton(
            key: const ValueKey('salary-stats-export'),
            tooltip: tr('保存到存储空间'),
            icon: const Icon(Icons.save_outlined, size: 20),
            onPressed: _loading ? null : () => _exportRecords(visible),
          ),
        ],
      ),
      body: content,
      bottomNavigationBar: addButton,
    );
  }

  /// 房贷曲线：只在「工资 × 税后」下提供，和用户看到的到手工资同口径。
  List<SalaryChartLine> _extraLines(List<SalaryPoint> points) {
    final plan = _mortgage;
    if (plan == null ||
        _mortgageMode == _MortgageMode.off ||
        _metric != _ChartMetric.income ||
        _taxMode != _TaxMode.net) {
      return const <SalaryChartLine>[];
    }
    final result = MortgageCalculator.compute(plan);
    if (_mortgageMode == _MortgageMode.overlay) {
      return <SalaryChartLine>[
        SalaryChartLine(
          label: tr('房贷月供'),
          values: <double?>[
            for (final point in points)
              result.installmentAt(point.key)?.payment,
          ],
          color: const Color(0xFFE0574C),
          dashed: true,
        ),
      ];
    }
    // 扣除模式：公积金月供从账户余额扣，不从工资扣，所以只减商贷部分。
    return <SalaryChartLine>[
      SalaryChartLine(
        label: tr('扣除房贷后剩余'),
        values: <double?>[
          for (final point in points)
            point.value - (result.installmentAt(point.key)?.commercial ?? 0),
        ],
        color: const Color(0xFF2E9BD6),
        dashed: false,
      ),
    ];
  }

  List<SalaryPoint> get _points {
    if (_metric == _ChartMetric.balance) {
      // 选了房贷方案（叠加或扣除）时，公积金月供从账户余额里扣。
      final plan = _mortgageMode == _MortgageMode.off ? null : _mortgage;
      final result = plan == null ? null : MortgageCalculator.compute(plan);
      return SalaryStats.socialBalanceSeries(
        _records,
        scale: _scale,
        city: _city,
        personalRates: _rates,
        socialBase: _socialBase,
        fundBase: _fundBase,
        fundDeduction: result == null ? null : (key) => result.fundAt(key),
      );
    }
    final net = _taxMode == _TaxMode.net;
    return SalaryStats.incomeSeries(
      _records,
      _scale,
      transform: net
          ? (gross) => SalaryStats.netOfGross(
                gross: gross,
                city: _city,
                personalRates: _rates,
                socialBase: _socialBase,
                fundBase: _fundBase,
                specialDeduction: _specialDeduction,
              )
          : null,
    );
  }

  /// 指标与尺度压成一行两个小胶囊，不再各占一整行。
  Widget _controlBar() {
    return Row(
      children: <Widget>[
        MiniSegmented<_ChartMetric>(
          key: const ValueKey('salary-stats-metric'),
          options: <MiniSegmentedOption<_ChartMetric>>[
            MiniSegmentedOption<_ChartMetric>(
              value: _ChartMetric.income,
              label: tr('工资变化'),
            ),
            MiniSegmentedOption<_ChartMetric>(
              value: _ChartMetric.balance,
              label: tr('社保余额'),
            ),
          ],
          selected: _metric,
          onChanged: (value) => setState(() => _metric = value),
        ),
        const Spacer(),
        // 内嵌为页签时没有 AppBar，两个工具按钮压到这一行右边。
        if (widget.embedded) ...<Widget>[
          _barIcon(
            key: const ValueKey('salary-stats-zero-axis'),
            icon: _zeroBased ? Icons.straighten : Icons.unfold_more,
            tooltip: _zeroBased ? tr('纵轴从 0 起') : tr('纵轴自适应'),
            onPressed: () => setState(() => _zeroBased = !_zeroBased),
          ),
          _barIcon(
            key: const ValueKey('salary-stats-export'),
            icon: Icons.save_outlined,
            tooltip: tr('保存到存储空间'),
            onPressed: _loading ? null : () => _exportRecords(_visibleRecords),
          ),
        ],
        MiniSegmented<SalaryScale>(
          key: const ValueKey('salary-stats-scale'),
          options: <MiniSegmentedOption<SalaryScale>>[
            MiniSegmentedOption<SalaryScale>(
              value: SalaryScale.month,
              label: tr('按月'),
            ),
            MiniSegmentedOption<SalaryScale>(
              value: SalaryScale.year,
              label: tr('按年'),
            ),
          ],
          selected: _scale,
          onChanged: (value) => setState(() => _scale = value),
        ),
      ],
    );
  }

  Widget _barIcon({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      icon: Icon(icon, size: 19),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );
  }

  Widget _chartCard(
    BuildContext context,
    List<SalaryPoint> points,
    Color color,
    String legend,
    List<double?>? movingAverage,
    List<SalaryChartLine> extraLines,
  ) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  _scale == SalaryScale.month ? tr('月度趋势') : tr('年度趋势'),
                  style: titleStyle,
                ),
                const SizedBox(width: 10),
                // 税前/税后只影响出图，做成标题旁的小胶囊即可。
                if (_metric == _ChartMetric.income)
                  MiniSegmented<_TaxMode>(
                    key: const ValueKey('salary-stats-tax-mode'),
                    height: 26,
                    fontSize: 12,
                    options: <MiniSegmentedOption<_TaxMode>>[
                      MiniSegmentedOption<_TaxMode>(
                        value: _TaxMode.gross,
                        label: tr('税前'),
                      ),
                      MiniSegmentedOption<_TaxMode>(
                        value: _TaxMode.net,
                        label: tr('税后'),
                      ),
                    ],
                    selected: _taxMode,
                    onChanged: (value) => setState(() => _taxMode = value),
                  ),
                const Spacer(),
                if (points.isNotEmpty)
                  Text(
                    '¥${formatMoney(points.last.value, digits: 0)}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                    key: const ValueKey('salary-stats-latest'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            SalaryTrendChart(
              points: points,
              color: color,
              legend: legend,
              zeroBased: _zeroBased,
              movingAverage: movingAverage,
              extraLines: extraLines,
            ),
            if (_metric == _ChartMetric.income && _taxMode == _TaxMode.net)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SmallHint(
                  text: tr('税后 = 税前 − 个人五险一金 − 个税（月度估算），记录仍按税前填写'),
                ),
              ),
            if (_mortgagePlans.isNotEmpty &&
                _metric == _ChartMetric.income &&
                _taxMode == _TaxMode.net)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: MiniSegmented<_MortgageMode>(
                        key: const ValueKey('salary-stats-mortgage-mode'),
                        height: 26,
                        fontSize: 11,
                        options: <MiniSegmentedOption<_MortgageMode>>[
                          for (final mode in _MortgageMode.values)
                            MiniSegmentedOption<_MortgageMode>(
                              value: mode,
                              label: tr(mode.label),
                            ),
                        ],
                        selected: _mortgageMode,
                        onChanged: (value) =>
                            setState(() => _mortgageMode = value),
                      ),
                    ),
                  ],
                ),
              ),
            if (_scale == SalaryScale.month && points.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SmallHint(text: tr('最多显示最近 36 个月')),
              ),
          ],
        ),
      ),
    );
  }

  /// 年度下拉选项：记录里出现过的年份 + 当前年（保证默认项永远可选）。
  List<int> get _years {
    final years = <int>{DateTime.now().year, ..._records.map((r) => r.year)};
    final sorted = years.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  int get _year {
    final years = _years;
    return years.contains(_selectedYear) ? _selectedYear : years.first;
  }

  List<SalaryRecord> get _visibleRecords => _records
      .where((r) => r.year == _year)
      .toList()
      .reversed
      .take(50)
      .toList();

  Widget _recordSection(BuildContext context, List<SalaryRecord> visible) {
    final theme = Theme.of(context);
    final years = _years;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Row(
              children: <Widget>[
                Text(
                  tr('工资记录'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${visible.length}',
                  key: const ValueKey('salary-stats-count'),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          // 年份做成一排小胶囊：比下拉少一次点击，也能一眼看到有哪些年的记录。
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (final year in years)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _yearChip(context, year),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
              child: Text(
                tr('这一年还没有记录，点下方按钮添加'),
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (final record in visible)
            ListTile(
              key: ValueKey('salary-record-${record.id}'),
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text(
                '${tr(salaryRecordKindLabel(record.kind))} · ${record.period}',
              ),
              subtitle: record.note.isEmpty ? null : Text(record.note),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('¥${formatMoney(record.amount, digits: 0)}'),
                  IconButton(
                    key: ValueKey('salary-record-delete-${record.id}'),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: tr('删除'),
                    visualDensity: VisualDensity.compact,
                    constraints:
                        const BoxConstraints(minWidth: 34, minHeight: 34),
                    onPressed: () => _write(
                      _records.where((e) => e.id != record.id).toList(),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _yearChip(BuildContext context, int year) {
    final scheme = Theme.of(context).colorScheme;
    final active = year == _year;
    return Material(
      color: active
          ? scheme.primary.withOpacity(0.16)
          : scheme.onSurface.withOpacity(0.06),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        key: ValueKey('salary-stats-year-$year'),
        borderRadius: BorderRadius.circular(999),
        onTap: () => setState(() => _selectedYear = year),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          child: Text(
            trf('{year} 年', {'year': year}),
            style: TextStyle(
              fontSize: 12.5,
              height: 1.1,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// 把当前年度的记录写成「存储空间 › 个人信息 › 工资记录_YYYY.json」。
  Future<String> _defaultExport(List<SalaryRecord> records) async {
    final content = const JsonEncoder.withIndent('  ').convert(
      <String, dynamic>{
        'version': 1,
        'year': _year,
        'exportedAt': DateTime.now().toIso8601String(),
        'records': records.map((e) => e.toJson()).toList(),
      },
    );
    final stored = await AppStore.saveText(
      category: AppStoreCategory.profile,
      name: '工资记录_$_year.json',
      content: content,
      overwrite: true,
    );
    return stored.name;
  }

  Future<void> _exportRecords(List<SalaryRecord> records) async {
    try {
      final name = await (widget.exporter ?? _defaultExport)(records);
      if (!mounted) return;
      showToast(context, trf('已保存 {name} 到存储空间', {'name': name}));
    } catch (_) {
      if (!mounted) return;
      showToast(context, tr('保存失败，请检查存储空间权限'));
    }
  }

  Future<void> _addRecord() async {
    final record = await showDialog<SalaryRecord>(
      context: context,
      builder: (_) => const _RecordSheet(),
    );
    if (record == null || !mounted) return;
    // 补录往年工资时把列表切到那一年，否则新记录会被年度筛选挡住。
    setState(() => _selectedYear = record.year);
    await _write(<SalaryRecord>[..._records, record]
      ..sort((a, b) => a.period.compareTo(b.period)));
  }
}

/// 添加记录弹窗：控制器由自己的 State 持有并释放，避免 await showDialog 后
/// 立刻 dispose 触发 "used after being disposed"。
class _RecordSheet extends StatefulWidget {
  const _RecordSheet();

  @override
  State<_RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<_RecordSheet> {
  SalaryRecordKind _kind = SalaryRecordKind.monthly;
  late final TextEditingController _period =
      TextEditingController(text: _defaultPeriod(_kind));
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _period.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  static String _defaultPeriod(SalaryRecordKind kind) {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    return switch (kind) {
      SalaryRecordKind.monthly => '${now.year}-$month',
      SalaryRecordKind.daily =>
        '${now.year}-$month-${now.day.toString().padLeft(2, '0')}',
      SalaryRecordKind.bonus => '${now.year}',
    };
  }

  bool _validPeriod(String text) => switch (_kind) {
        SalaryRecordKind.monthly =>
          RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(text),
        SalaryRecordKind.daily => RegExp(
            r'^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$',
          ).hasMatch(text),
        SalaryRecordKind.bonus => RegExp(r'^\d{4}$').hasMatch(text),
      };

  void _switchKind(SalaryRecordKind kind) {
    setState(() {
      _kind = kind;
      _period.text = _defaultPeriod(kind);
      _error = null;
    });
  }

  void _submit() {
    final period = _period.text.trim();
    final amount = double.tryParse(_amount.text.replaceAll(',', '').trim());
    if (!_validPeriod(period)) {
      setState(() => _error = tr('日期格式不对'));
      return;
    }
    if (amount == null || amount <= 0) {
      setState(() => _error = tr('请填写大于 0 的金额'));
      return;
    }
    Navigator.of(context).pop(
      SalaryRecord(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        kind: _kind,
        period: period,
        amount: amount,
        note: _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('添加工资记录')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SegmentedButton<SalaryRecordKind>(
              segments: <ButtonSegment<SalaryRecordKind>>[
                ButtonSegment<SalaryRecordKind>(
                  value: SalaryRecordKind.daily,
                  label: Text(tr('按日')),
                ),
                ButtonSegment<SalaryRecordKind>(
                  value: SalaryRecordKind.monthly,
                  label: Text(tr('按月')),
                ),
                ButtonSegment<SalaryRecordKind>(
                  value: SalaryRecordKind.bonus,
                  label: Text(tr('年终奖')),
                ),
              ],
              selected: <SalaryRecordKind>{_kind},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => _switchKind(selection.first),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('salary-record-period'),
              controller: _period,
              decoration: InputDecoration(
                labelText: switch (_kind) {
                  SalaryRecordKind.monthly => tr('月份（YYYY-MM）'),
                  SalaryRecordKind.daily => tr('日期（YYYY-MM-DD）'),
                  SalaryRecordKind.bonus => tr('年份（YYYY）'),
                },
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('salary-record-amount'),
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: tr('金额（元）'),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('salary-record-note'),
              controller: _note,
              decoration: InputDecoration(
                labelText: tr('备注（可选）'),
                isDense: true,
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('取消')),
        ),
        FilledButton(
          key: const ValueKey('salary-record-save'),
          onPressed: _submit,
          child: Text(tr('保存')),
        ),
      ],
    );
  }
}
