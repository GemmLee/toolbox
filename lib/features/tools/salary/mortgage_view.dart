import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/formatters.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/collapse_card.dart';
import '../../../core/widgets/mini_segmented.dart';
import 'mortgage_models.dart';
import 'mortgage_store.dart';

/// 房贷每月还款额：组合贷里公积金那部分从公积金账户扣，不占工资。
enum _ScheduleScale { year, month }

/// 房贷计算：总价、首付、组合贷比例、利率与期限 → 月供 / 剩余贷款。
///
/// 作为工资计算器的第三个页签内嵌使用，所以这里不套 Scaffold，
/// 只产出可滚动内容；页面属性（标题、切换条）由外层 shell 提供。
class MortgageView extends StatefulWidget {
  const MortgageView({
    super.key,
    this.loader,
    this.saver,
    this.onChanged,
  });

  /// 注入点：测试用内存实现，避免 FakeAsync 下跑真实 SharedPreferences。
  final Future<List<MortgagePlan>> Function()? loader;
  final Future<void> Function(List<MortgagePlan>)? saver;

  /// 方案变化（保存 / 选中 / 删除）时通知外层，工资统计据此重绘曲线。
  final VoidCallback? onChanged;

  @override
  State<MortgageView> createState() => MortgageViewState();
}

class MortgageViewState extends State<MortgageView> {
  final TextEditingController _totalPrice =
      TextEditingController(text: '1500000');
  final TextEditingController _downPayment =
      TextEditingController(text: '450000');
  final TextEditingController _commercialRate =
      TextEditingController(text: '3.1');
  final TextEditingController _fundRate = TextEditingController(text: '2.6');

  /// 年限与公积金占比都按「年 / %」手动输入，不再靠选择或拖动。
  final TextEditingController _years = TextEditingController(text: '30');
  final TextEditingController _fundShare =
      TextEditingController(text: '30');
  final TextEditingController _name = TextEditingController();

  List<MortgagePlan> _plans = <MortgagePlan>[];
  String _draftId = '';
  DateTime _start = DateTime(DateTime.now().year, DateTime.now().month);
  MortgageRepayment _repayment = MortgageRepayment.equalInstallment;
  _ScheduleScale _scale = _ScheduleScale.year;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _totalPrice.dispose();
    _downPayment.dispose();
    _commercialRate.dispose();
    _fundRate.dispose();
    _years.dispose();
    _fundShare.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final plans = await (widget.loader ?? MortgageStore.load)();
    final selected = await MortgageStore.loadSelectedId();
    if (!mounted) return;
    var current = plans.where((p) => p.id == selected).toList();
    if (current.isEmpty && plans.isNotEmpty) {
      current = <MortgagePlan>[plans.first];
    }
    setState(() {
      _plans = plans;
      _loading = false;
      if (current.isNotEmpty) _applyPlan(current.first);
    });
  }

  double get _price => double.tryParse(_totalPrice.text.trim()) ?? 0;

  double get _down => double.tryParse(_downPayment.text.trim()) ?? 0;

  double get _loan => (_price - _down).clamp(0, double.infinity).toDouble();

  double get _downRatio => _price <= 0 ? 0 : (_down / _price).clamp(0, 1);

  /// 年限限 1~40 年：避免手滑输入极大的数把摊销表撑爆。
  int get _yearsValue =>
      (int.tryParse(_years.text.trim()) ?? 30).clamp(1, 40);

  /// 界面按百分比输入，模型仍存 0~1 的占比，兼容已保存的方案。
  double get _fundShareValue =>
      (double.tryParse(_fundShare.text.trim()) ?? 30).clamp(0, 100) / 100;

  MortgagePlan get _draft => MortgagePlan(
        id: _draftId.isEmpty ? 'draft' : _draftId,
        name: _name.text.trim().isEmpty
            ? trf('房贷 {v} 万', {'v': (_loan / 10000).round()})
            : _name.text.trim(),
        start: _start,
        totalPrice: _price,
        downPayment: _down,
        years: _yearsValue,
        commercialRate: double.tryParse(_commercialRate.text.trim()) ?? 0,
        fundRate: double.tryParse(_fundRate.text.trim()) ?? 0,
        fundShare: _fundShareValue,
        repayment: _repayment,
      );

  MortgageResult get _result => MortgageCalculator.compute(_draft);

  void _applyPlan(MortgagePlan plan) {
    _draftId = plan.id;
    _name.text = plan.name;
    _start = plan.start;
    _years.text = '${plan.years}';
    _fundShare.text = (plan.fundShare * 100).toStringAsFixed(0);
    _repayment = plan.repayment;
    _totalPrice.text = plan.totalPrice.toStringAsFixed(0);
    _downPayment.text = plan.downPayment.toStringAsFixed(0);
    _commercialRate.text = _trim(plan.commercialRate);
    _fundRate.text = _trim(plan.fundRate);
  }

  static String _trim(double value) {
    final text = value.toStringAsFixed(3);
    return text.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  void _update(VoidCallback change) {
    setState(change);
  }

  Future<void> _savePlan() async {
    if (_price <= 0) {
      showToast(context, tr('请先填写房屋总价'));
      return;
    }
    // 新方案第一次保存时生成稳定 id，之后原地更新，不会越存越多。
    final id = (_draftId.isEmpty || _draftId == 'draft')
        ? DateTime.now().millisecondsSinceEpoch.toString()
        : _draftId;
    final plan = MortgagePlan(
      id: id,
      name: _name.text.trim().isEmpty
          ? trf('房贷 {v} 万', {'v': (_loan / 10000).round()})
          : _name.text.trim(),
      start: _start,
      totalPrice: _price,
      downPayment: _down,
      years: _yearsValue,
      commercialRate: double.tryParse(_commercialRate.text.trim()) ?? 0,
      fundRate: double.tryParse(_fundRate.text.trim()) ?? 0,
      fundShare: _fundShareValue,
      repayment: _repayment,
    );
    final next = <MortgagePlan>[
      for (final item in _plans)
        if (item.id != id) item,
      plan,
    ];
    await (widget.saver ?? MortgageStore.save)(next);
    await MortgageStore.saveSelectedId(id);
    if (!mounted) return;
    setState(() {
      _plans = next;
      _draftId = id;
      _name.text = plan.name;
    });
    widget.onChanged?.call();
    showToast(context, tr('房贷方案已保存'));
  }

  Future<void> _deletePlan() async {
    if (_plans.isEmpty) {
      showToast(context, tr('还没有保存的方案'));
      return;
    }
    if (_draftId.isEmpty || _draftId == 'draft') {
      showToast(context, tr('当前方案还没保存'));
      return;
    }
    final next = _plans.where((p) => p.id != _draftId).toList();
    await (widget.saver ?? MortgageStore.save)(next);
    await MortgageStore.saveSelectedId(null);
    if (!mounted) return;
    setState(() {
      _plans = next;
      _draftId = '';
    });
    widget.onChanged?.call();
    showToast(context, tr('已删除该方案'));
  }

  void _newPlan() {
    setState(() {
      _draftId = '';
      _name.clear();
      _totalPrice.text = '1500000';
      _downPayment.text = '450000';
      _commercialRate.text = '3.1';
      _fundRate.text = '2.6';
      _years.text = '30';
      _fundShare.text = '30';
      _repayment = MortgageRepayment.equalInstallment;
      _start = DateTime(DateTime.now().year, DateTime.now().month);
    });
    widget.onChanged?.call();
    showToast(context, tr('已新建空白方案'));
  }

  Future<void> _pickStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: tr('选择放款日期'),
    );
    if (picked == null) return;
    _update(() => _start = DateTime(picked.year, picked.month));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final result = _result;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: <Widget>[
        _planBar(),
        const SizedBox(height: 10),
        _inputCard(),
        const SizedBox(height: 10),
        _resultCard(result),
        const SizedBox(height: 10),
        _scheduleCard(result),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const ValueKey('mortgage-save'),
          onPressed: _savePlan,
          icon: const Icon(Icons.save_outlined, size: 18),
          label: Text(tr('保存当前方案')),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
          ),
        ),
      ],
    );
  }

  /// 顶部：已有方案下拉 + 新建 / 删除。
  Widget _planBar() {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: DropdownButtonFormField<String>(
            key: const ValueKey('mortgage-plan-picker'),
            value: _plans.any((p) => p.id == _draftId) ? _draftId : null,
            isExpanded: true,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              labelText: tr('已保存方案'),
            ),
            hint: Text(tr('新建方案')),
            items: _plans
                .map(
                  (plan) => DropdownMenuItem<String>(
                    value: plan.id,
                    child: Text(
                      plan.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (id) {
              if (id == null) return;
              final plan = _plans.firstWhere((p) => p.id == id);
              setState(() => _applyPlan(plan));
              MortgageStore.saveSelectedId(id);
              widget.onChanged?.call();
            },
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          key: const ValueKey('mortgage-new'),
          tooltip: tr('新建方案'),
          visualDensity: VisualDensity.compact,
          onPressed: _newPlan,
          icon: const Icon(Icons.add, size: 20),
        ),
        IconButton(
          key: const ValueKey('mortgage-delete'),
          tooltip: tr('删除当前方案'),
          visualDensity: VisualDensity.compact,
          color: theme.colorScheme.error,
          // 没有方案时也保持可点：点一下给明确提示，而不是「按了没反应」。
          onPressed: _deletePlan,
          icon: const Icon(Icons.delete_outline, size: 20),
        ),
      ],
    );
  }

  Widget _inputCard() {
    final theme = Theme.of(context);
    return SectionCard(
      title: tr('贷款信息'),
      dense: true,
      trailing: IconButton(
        key: const ValueKey('mortgage-pick-date'),
        tooltip: tr('放款日期'),
        visualDensity: VisualDensity.compact,
        onPressed: _pickStart,
        icon: const Icon(Icons.event_outlined, size: 18),
      ),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                trf('放款 {date}', {
                  'date':
                      '${_start.year}-${_start.month.toString().padLeft(2, '0')}',
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Text(
              trf('首付 {v}%', {'v': (_downRatio * 100).toStringAsFixed(1)}),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        NumberField(
          controller: _totalPrice,
          label: tr('房屋总价'),
          suffix: tr('元'),
          outerPadding: const EdgeInsets.only(bottom: 8),
          onChanged: (_) => _update(() {}),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: NumberField(
                controller: _downPayment,
                label: tr('首付金额'),
                suffix: tr('元'),
                onChanged: (_) => _update(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Column(
              children: <Widget>[
                for (final ratio in <double>[0.2, 0.3, 0.5])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _ratioChip(ratio),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: NumberField(
                controller: _commercialRate,
                label: tr('商贷年利率'),
                suffix: '%',
                onChanged: (_) => _update(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: NumberField(
                controller: _fundRate,
                label: tr('公积金年利率'),
                suffix: '%',
                onChanged: (_) => _update(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: NumberField(
                key: const ValueKey('mortgage-years'),
                controller: _years,
                label: tr('贷款年限'),
                suffix: tr('年'),
                hint: '1-40',
                onChanged: (_) => _update(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: NumberField(
                key: const ValueKey('mortgage-fund-share'),
                controller: _fundShare,
                label: tr('公积金占比'),
                suffix: '%',
                hint: '0-100',
                onChanged: (_) => _update(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Text(tr('还款方式'), style: theme.textTheme.bodySmall),
            const SizedBox(width: 10),
            MiniSegmented<MortgageRepayment>(
              key: const ValueKey('mortgage-repayment'),
              height: 28,
              fontSize: 12,
              options: <MiniSegmentedOption<MortgageRepayment>>[
                for (final mode in MortgageRepayment.values)
                  MiniSegmentedOption<MortgageRepayment>(
                    value: mode,
                    label: tr(mode.label),
                  ),
              ],
              selected: _repayment,
              onChanged: (value) => _update(() => _repayment = value),
            ),
          ],
        ),
        Text(
          trf('商业贷款 {a} · 公积金贷款 {b}', {
            'a': '¥${formatMoney(_loan * (1 - _fundShareValue), digits: 0)}',
            'b': '¥${formatMoney(_loan * _fundShareValue, digits: 0)}',
          }),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _ratioChip(double ratio) {
    final scheme = Theme.of(context).colorScheme;
    final active = (_downRatio - ratio).abs() < 0.005;
    return Material(
      color: active
          ? scheme.primary.withOpacity(0.16)
          : scheme.onSurface.withOpacity(0.06),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          if (_price <= 0) return;
          _update(() {
            _downPayment.text = (_price * ratio).toStringAsFixed(0);
          });
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Text(
            '${(ratio * 100).round()}%',
            style: TextStyle(
              fontSize: 11,
              color: active ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  /// 与「到手工资」那张主题色卡片同一套样式：同样的圆角 / 渐变 / 阴影、
  /// 同样的大号金额与三栏指标，唯一区别是右侧多了商贷 / 公积金两行拆分。
  Widget _resultCard(MortgageResult result) {
    final scheme = Theme.of(context).colorScheme;
    // 渐变块在深色主题下偏深、在蜜蜂黄 / 黄昏沙丘这类浅色主题下偏亮，
    // 前景色必须按主色亮度实时取，不能写死 onSurface（浅色主色上会看不清）。
    final onCard = AppTheme.readableOn(scheme.primary);
    final month = _monthKeyOf(result, 1);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            scheme.primary,
            Color.lerp(scheme.primary, Colors.black, 0.22)!,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withOpacity(0.28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      result.fixedPayment ? tr('每月还款') : tr('首月还款'),
                      style: TextStyle(
                        color: onCard.withOpacity(0.82),
                        fontSize: 13,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: <Widget>[
                        Text(
                          '¥',
                          style: TextStyle(
                            color: onCard,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            formatMoney(result.firstPayment, digits: 0),
                            key: const ValueKey('mortgage-monthly'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: onCard,
                              fontSize: 34,
                              fontWeight: FontWeight.w700,
                              height: 1.1,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (!result.fixedPayment)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          trf('末月 {v}，逐月递减', {
                            'v':
                                '¥${formatMoney(result.lastPayment, digits: 0)}',
                          }),
                          style: TextStyle(
                            color: onCard.withOpacity(0.8),
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // 组合贷拆分：月供总额的右下方上下两行，不占指标行。
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  _split(tr('商贷'), result.commercialAt(month), onCard),
                  const SizedBox(height: 4),
                  _split(tr('公积金'), result.fundAt(month), onCard),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              _metric(tr('贷款总额'), result.loanAmount, onCard),
              _metric(tr('总利息'), result.totalInterest, onCard),
              _metric(tr('总还款'), result.totalPayment, onCard),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              // 本金占还款总额的比例：数值越高，利息负担越轻。
              value: result.totalPayment <= 0
                  ? 0
                  : (result.loanAmount / result.totalPayment).clamp(0, 1),
              minHeight: 5,
              backgroundColor: onCard.withOpacity(0.22),
              valueColor: AlwaysStoppedAnimation<Color>(onCard),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            result.totalPayment <= 0
                ? tr('填写房屋总价后显示本金占比')
                : trf('本金占比 {v}%', {
                    'v': (result.loanAmount / result.totalPayment * 100)
                        .toStringAsFixed(1),
                  }),
            style: TextStyle(color: onCard.withOpacity(0.82), fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            tr('公积金月供由公积金账户扣，不占工资'),
            style: TextStyle(color: onCard.withOpacity(0.72), fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// 第 n 期对应的自然月（放款次月为第 1 期）。
  static String _monthKeyOf(MortgageResult result, int index) {
    final start = result.plan.start;
    final total = start.year * 12 + (start.month - 1) + index;
    final year = total ~/ 12;
    final month = total % 12 + 1;
    return '${year.toString().padLeft(4, '0')}-'
        '${month.toString().padLeft(2, '0')}';
  }

  Widget _metric(String label, double value, Color onCard) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(color: onCard.withOpacity(0.72), fontSize: 11),
          ),
          const SizedBox(height: 3),
          Text(
            '¥${formatMoney(value, digits: 0)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: onCard,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// 商贷 / 公积金单行拆分：右对齐，两行的金额右边缘会对齐。
  Widget _split(String label, double value, Color onCard) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(color: onCard.withOpacity(0.72), fontSize: 11),
        ),
        const SizedBox(width: 5),
        Text(
          '¥${formatMoney(value, digits: 0)}',
          style: TextStyle(
            color: onCard,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  /// 还款计划：按年看年末剩余本金，按月看前 12 期。
  Widget _scheduleCard(MortgageResult result) {
    final theme = Theme.of(context);
    final rows = <List<String>>[];
    if (_scale == _ScheduleScale.year) {
      for (var year = 0; year * 12 < result.installments.length; year++) {
        final slice = result.installments
            .skip(year * 12)
            .take(12)
            .toList(growable: false);
        if (slice.isEmpty) break;
        final paid = slice.fold<double>(0, (sum, item) => sum + item.payment);
        rows.add(<String>[
          trf('第 {n} 年', {'n': year + 1}),
          '¥${formatMoney(paid, digits: 0)}',
          '¥${formatMoney(slice.last.remaining, digits: 0)}',
        ]);
      }
    } else {
      for (final item in result.installments.take(12)) {
        rows.add(<String>[
          trf('第 {n} 期', {'n': item.index}),
          '¥${formatMoney(item.payment, digits: 0)}',
          '¥${formatMoney(item.remaining, digits: 0)}',
        ]);
      }
    }
    return CollapseCard(
      title: tr('还款计划'),
      dense: true,
      initiallyExpanded: true,
      actions: <Widget>[
        MiniSegmented<_ScheduleScale>(
          height: 24,
          fontSize: 11,
          options: <MiniSegmentedOption<_ScheduleScale>>[
            MiniSegmentedOption<_ScheduleScale>(
              value: _ScheduleScale.year,
              label: tr('按年'),
            ),
            MiniSegmentedOption<_ScheduleScale>(
              value: _ScheduleScale.month,
              label: tr('按月'),
            ),
          ],
          selected: _scale,
          onChanged: (value) => setState(() => _scale = value),
        ),
      ],
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(flex: 3, child: _th(tr('期数'))),
            Expanded(flex: 4, child: _th(tr('还款'), alignEnd: true)),
            Expanded(flex: 4, child: _th(tr('剩余贷款'), alignEnd: true)),
          ],
        ),
        const Divider(height: 14),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: Text(row[0], style: theme.textTheme.bodySmall),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    row[1],
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    row[2],
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_scale == _ScheduleScale.month)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SmallHint(
              text: trf('共 {n} 期，这里只列前 12 期', {
                'n': result.installments.length,
              }),
            ),
          ),
      ],
    );
  }

  Widget _th(String text, {bool alignEnd = false}) {
    return Text(
      text,
      textAlign: alignEnd ? TextAlign.end : TextAlign.start,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
    );
  }
}
