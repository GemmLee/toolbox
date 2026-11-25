import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/widgets/app_widgets.dart';
import '../tools/salary/pension_policy.dart';
import 'profile_model.dart';
import 'profile_repository.dart';

/// 个人信息 › 养老与税优：养老金测算和个人养老金税优所需的个人参数。
///
/// 全部选填；未填写的项由计算器按页面内的工资/城市默认值估算。
class ProfilePensionPage extends StatefulWidget {
  const ProfilePensionPage({super.key});

  @override
  State<ProfilePensionPage> createState() => _ProfilePensionPageState();
}

class _ProfilePensionPageState extends State<ProfilePensionPage> {
  final TextEditingController _annualSalary = TextEditingController();
  final TextEditingController _currentAge = TextEditingController();
  final TextEditingController _retireAge = TextEditingController();
  final TextEditingController _paidYears = TextEditingController();
  final TextEditingController _accountBalance = TextEditingController();
  final TextEditingController _salaryGrowth = TextEditingController();
  final TextEditingController _personalPension = TextEditingController();
  final TextEditingController _specialDeduction = TextEditingController();
  final TextEditingController _customPensionBase = TextEditingController();

  UserProfile _profile = UserProfile();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _annualSalary,
      _currentAge,
      _retireAge,
      _paidYears,
      _accountBalance,
      _salaryGrowth,
      _personalPension,
      _specialDeduction,
      _customPensionBase,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final profile = await ProfileRepository.load();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _annualSalary.text = textOf(profile.annualSalary);
      _currentAge.text = textOf(profile.currentAge);
      _retireAge.text = textOf(profile.retireAge);
      _paidYears.text = textOf(profile.paidYears);
      _accountBalance.text = textOf(profile.accountBalance);
      _salaryGrowth.text = textOf(profile.salaryGrowthPct);
      _personalPension.text = textOf(profile.personalPension);
      _specialDeduction.text = textOf(profile.specialDeduction);
      _customPensionBase.text = textOf(profile.customPensionBase);
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final profile = await ProfileRepository.update((data) {
      UserProfile.putNumber(
          data, UserProfile.annualSalaryKey, _annualSalary.text);
      UserProfile.putNumber(data, UserProfile.currentAgeKey, _currentAge.text);
      UserProfile.putNumber(data, UserProfile.retireAgeKey, _retireAge.text);
      UserProfile.putNumber(data, UserProfile.paidYearsKey, _paidYears.text);
      UserProfile.putNumber(
          data, UserProfile.accountBalanceKey, _accountBalance.text);
      UserProfile.putNumber(
          data, UserProfile.salaryGrowthKey, _salaryGrowth.text);
      UserProfile.putNumber(
          data, UserProfile.personalPensionKey, _personalPension.text);
      UserProfile.putNumber(
          data, UserProfile.specialDeductionKey, _specialDeduction.text);
      UserProfile.putNumber(
          data, UserProfile.customPensionBaseKey, _customPensionBase.text);
    });
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _saving = false;
    });
    FocusScope.of(context).unfocus();
    showToast(context, tr('已保存养老与税优信息'));
  }

  Future<void> _clearPension() async {
    final profile = await ProfileRepository.update((data) {
      for (final key in <String>[
        UserProfile.annualSalaryKey,
        UserProfile.currentAgeKey,
        UserProfile.retireAgeKey,
        UserProfile.paidYearsKey,
        UserProfile.accountBalanceKey,
        UserProfile.salaryGrowthKey,
        UserProfile.personalPensionKey,
        UserProfile.specialDeductionKey,
        UserProfile.customPensionBaseKey,
      ]) {
        data.remove(key);
      }
    });
    if (!mounted) return;
    setState(() {
      _profile = profile;
      for (final controller in <TextEditingController>[
        _annualSalary,
        _currentAge,
        _retireAge,
        _paidYears,
        _accountBalance,
        _salaryGrowth,
        _personalPension,
        _specialDeduction,
        _customPensionBase,
      ]) {
        controller.clear();
      }
    });
    showToast(context, tr('已清空养老信息'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final policy = PensionPolicy.byCity(_profile.cityId);
    return Scaffold(
      appBar: AppBar(title: Text(tr('养老与税优信息'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                SectionCard(
                  title: tr('所在城市养老政策'),
                  subtitle: trf('{city} · 2025 年计发基数 {v} 元/月', {
                    'city': tr(_profile.city.name),
                    'v': formatMoney(policy.pensionBase, digits: 0),
                  }),
                  trailing: InfoHint(text: tr(policy.note)),
                  children: [
                    Text(
                      tr(policy.source),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                    const SizedBox(height: 12),
                    NumberField(
                      controller: _customPensionBase,
                      label: tr('自定义计发基数（选填）'),
                      suffix: tr('元/月'),
                      outerPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SectionCard(
                  title: tr('养老金领取测算参数'),
                  children: [
                    NumberField(
                      controller: _annualSalary,
                      label: tr('年薪估计值'),
                      suffix: tr('元/年'),
                    ),
                    NumberField(
                      controller: _currentAge,
                      label: tr('当前年龄'),
                      suffix: tr('岁'),
                    ),
                    NumberField(
                      controller: _retireAge,
                      label: tr('计划退休年龄'),
                      suffix: tr('岁'),
                    ),
                    NumberField(
                      controller: _paidYears,
                      label: tr('已缴费年限'),
                      suffix: tr('年'),
                    ),
                    NumberField(
                      controller: _accountBalance,
                      label: tr('个人账户当前余额（选填）'),
                      suffix: tr('元'),
                    ),
                    NumberField(
                      controller: _salaryGrowth,
                      label: tr('年薪年增长率'),
                      suffix: '%',
                      outerPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SectionCard(
                  title: tr('个人养老金税优参数'),
                  trailing: InfoHint(
                    text: '${tr('年度缴纳上限 12,000 元，领取时按 3% 单独计税')}\n'
                        '${tr('子女教育、房贷、赡养老人等合计')}',
                  ),
                  children: [
                    NumberField(
                      controller: _personalPension,
                      label: tr('计划年度缴纳额'),
                      suffix: tr('元/年'),
                    ),
                    NumberField(
                      controller: _specialDeduction,
                      label: tr('每月专项附加扣除'),
                      suffix: tr('元/月'),
                      outerPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(_saving ? tr('保存中…') : tr('保存')),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                TextButton.icon(
                  onPressed: _saving ? null : _clearPension,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(tr('清空养老信息')),
                ),
                const SizedBox(height: 4),
                HintBanner(
                  text: tr('这些信息保存在本机「存储空间 › 个人信息」，仅供本地测算，不会上传。'),
                ),
              ],
            ),
    );
  }
}
