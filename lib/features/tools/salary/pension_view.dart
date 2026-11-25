import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../profile/profile_model.dart';
import 'city_rules.dart';
import 'pension_calculator.dart';
import 'pension_policy.dart';

/// 工资计算器里的「养老金领取测算 + 个人养老金税优」两张卡。
///
/// 城市政策按当前选中城市切换；个人参数优先取个人信息，未填的用本页
/// 工资与默认值估算，保证不填任何资料也能看到结果。
class PensionView extends StatelessWidget {
  const PensionView({
    super.key,
    required this.cityId,
    required this.gross,
    required this.socialBase,
    required this.personalTotal,
    required this.profile,
    required this.onOpenProfile,
  });

  final String cityId;
  final double gross;
  final double socialBase;
  final double personalTotal;
  final UserProfile profile;
  final VoidCallback onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final policy = PensionPolicy.byCity(cityId);
    final annualSalary = profile.annualSalary ?? gross * 12;
    final pension = PensionCalculator.pension(
      PensionInput(
        policy: policy,
        annualSalary: annualSalary,
        monthlyBase: socialBase > 0 ? socialBase : gross,
        currentAge: profile.currentAgeOrDefault,
        retireAge: profile.retireAgeOrDefault,
        paidYears: profile.paidYearsOrDefault,
        accountBalance: profile.accountBalance ?? 0,
        salaryGrowth: profile.salaryGrowth,
        customPensionBase: profile.customPensionBase,
      ),
    );
    final benefit = PensionCalculator.taxBenefit(
      TaxBenefitInput(
        annualSalary: annualSalary,
        monthlyPersonalInsurance: personalTotal,
        specialDeductionMonthly: profile.specialDeductionOrDefault,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pensionCard(context, policy, pension, annualSalary),
        const SizedBox(height: 10),
        _taxCard(context, benefit),
      ],
    );
  }

  Widget _pensionCard(
    BuildContext context,
    PensionPolicy policy,
    PensionResult r,
    double annualSalary,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final city = CityRules.byId(cityId);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.elderly_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    tr('养老金领取测算'),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                // 个人信息页已从「用户」页移除，养老参数只能在测算卡里就地打开。
                TextButton.icon(
                  key: const ValueKey('salary-open-pension-profile'),
                  onPressed: onOpenProfile,
                  icon: const Icon(Icons.tune, size: 16),
                  label: Text(tr('养老参数')),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
                InfoHint(
                  text: <String>[
                    tr(policy.note),
                    tr('按现行公式估算，未计过渡性养老金、地方增发与每年待遇调整，实际以社保经办机构核定为准。'),
                  ].join('\n\n'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              trf('{city} 2025 年计发基数 {v} 元/月 · {src}', {
                'city': tr(city.name),
                'v': formatMoney(r.pensionBase, digits: 0),
                'src': tr(policy.source),
              }),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Text(
              tr('预计每月可领养老金'),
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            Text(
              '¥ ${formatMoney(r.monthlyPension, digits: 0)}',
              key: const ValueKey('pension-monthly'),
              style: theme.textTheme.headlineSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              trf('基础养老金 {a} 元 + 个人账户养老金 {b} 元', {
                'a': formatMoney(r.basicPension, digits: 0),
                'b': formatMoney(r.accountPension, digits: 0),
              }),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const Divider(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _metric(context, tr('累计缴费年限'),
                    '${r.totalYears.toStringAsFixed(0)} ${tr('年')}'),
                _metric(context, tr('平均缴费指数'),
                    r.contributionIndex.toStringAsFixed(2)),
                _metric(context, tr('计发月数'), r.monthsFactor.toStringAsFixed(0)),
                _metric(context, tr('养老金替代率'),
                    '${(r.replacementRate * 100).toStringAsFixed(1)}%'),
              ],
            ),
            const SizedBox(height: 8),
            _line(context, tr('年薪估计值'),
                '¥ ${formatMoney(annualSalary, digits: 0)} / ${tr('年')}'),
            _line(
              context,
              tr('退休时个人账户累计'),
              '¥ ${formatMoney(r.accountBalanceAtRetire, digits: 0)}',
            ),
            _line(
              context,
              tr('个人累计缴费本金'),
              '¥ ${formatMoney(r.personalPaidTotal, digits: 0)}',
            ),
            _line(
              context,
              tr('领取后回本年限'),
              '${r.paybackYears.toStringAsFixed(1)} ${tr('年')}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _taxCard(BuildContext context, TaxBenefitResult b) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final best = b.recommended;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.savings_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    tr('个人养老金税优'),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                InfoHint(
                  text: <String>[
                    _strategyText(b),
                    tr('缴纳额在综合所得中据实扣除，现行上限 12,000 元/年；领取时按 3% 单独计税，故净税优已扣该税负。'),
                  ].join('\n\n'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              trf('当前边际税率 {r} · 年应纳税所得额 {v} 元', {
                'r': '${(b.marginalRate * 100).toStringAsFixed(0)}%',
                'v': formatMoney(b.taxableAnnual, digits: 0),
              }),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withOpacity(0.45),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    b.worthIt
                        ? trf('建议年度缴纳 {v} 元', {
                            'v': formatMoney(best.amount, digits: 0),
                          })
                        : tr('当前税率下暂无税优空间，建议暂不缴纳'),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    trf('当年免税（少缴个税） {a} 元 · 领取环节税 {b} 元 · 净税优 {c} 元', {
                      'a': formatMoney(best.taxSaved, digits: 0),
                      'b': formatMoney(best.withdrawalTax, digits: 0),
                      'c': formatMoney(best.netBenefit, digits: 0),
                    }),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              tr('年度缴纳策略对比'),
              style: theme.textTheme.labelMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            _optionsTable(context, b),
          ],
        ),
      ),
    );
  }

  String _strategyText(TaxBenefitResult b) {
    if (!b.worthIt) {
      return tr('当前边际税率不高于领取环节 3%，缴纳只能起到强制储蓄作用，不能带来净节税；可先观望或待收入提高后再缴。');
    }
    final drop = b.bracketDropAmount;
    final next = b.nextRate;
    final threshold = (drop != null && next != null)
        ? trf('若只缴 {v} 元即可把边际税率降到 {r}，可按该金额作为最低缴纳档；', {
            'v': formatMoney(drop, digits: 0),
            'r': '${(next * 100).toStringAsFixed(0)}%',
          })
        : '';
    return '$threshold${tr('建议年内分月缴存（如每月 1,000 元），并在 12 月 31 日前存满额度，以便次年汇算清缴时据实扣除；收入越高、边际税率越高，顶格缴纳越划算。')}';
  }

  Widget _optionsTable(BuildContext context, TaxBenefitResult b) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    TextStyle head() => theme.textTheme.labelSmall!.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        );
    return Table(
      columnWidths: const <int, TableColumnWidth>{
        0: FlexColumnWidth(1.1),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: <TableRow>[
        TableRow(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          children: [
            _cell(context, tr('年缴纳额'), head()),
            _cell(context, tr('当年免税'), head(), end: true),
            _cell(context, tr('净税优'), head(), end: true),
          ],
        ),
        for (final option in b.options)
          TableRow(
            decoration: option.amount == b.recommended.amount && b.worthIt
                ? BoxDecoration(color: scheme.primary.withOpacity(0.08))
                : null,
            children: [
              _cell(
                context,
                formatMoney(option.amount, digits: 0),
                theme.textTheme.bodySmall!.copyWith(
                  fontWeight: option.amount == b.recommended.amount
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
              ),
              _cell(context, formatMoney(option.taxSaved, digits: 0),
                  theme.textTheme.bodySmall!,
                  end: true),
              _cell(context, formatMoney(option.netBenefit, digits: 0),
                  theme.textTheme.bodySmall!,
                  end: true),
            ],
          ),
      ],
    );
  }

  Widget _cell(BuildContext context, String text, TextStyle style,
      {bool end = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
      child: Text(
        text,
        textAlign: end ? TextAlign.end : TextAlign.start,
        style: style,
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          Text(
            value,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
