import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/formatters.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/insurance.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/collapse_card.dart';
import '../../../core/widgets/mini_segmented.dart';
import '../../../core/widgets/rate_section.dart';
import '../../profile/profile_model.dart';
import '../../profile/profile_pension_page.dart';
import '../../profile/profile_repository.dart';
import 'city_rules.dart';
import 'pension_view.dart';
import 'salary_calculator.dart';
import 'salary_input_cache.dart';
import 'salary_models.dart';
import 'salary_settings.dart';
import 'salary_stats_page.dart';

import 'mortgage_view.dart';
import 'salary_tab_switch.dart';

/// 工资计算器：三个独立页签（到手工资 / 工资统计 / 房贷计算）。
///
/// 顶部切换条选中项展开成胶囊、其余缩成圆球，页面本身可以直接左右滑动；
/// 三页各自保留自己的滚动位置与输入，切走再切回不会重置。
class SalaryPage extends StatefulWidget {
  const SalaryPage({super.key});

  @override
  State<SalaryPage> createState() => _SalaryPageState();
}

class _SalaryPageState extends State<SalaryPage> {
  final PageController _page = PageController();

  /// 房贷方案保存 / 切换后自增：工资统计页据此重算叠加曲线。
  final ValueNotifier<int> _mortgageRevision = ValueNotifier<int>(0);

  int _index = 0;

  @override
  void dispose() {
    _page.dispose();
    _mortgageRevision.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    if (index == _index) return;
    _page.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // label 存简体中文源文案：标题在这里统一 tr()，页签内部也用同一个 key
    // 过 tr()，避免切换语言后标题变了、圆球胶囊还停在旧语言。
    final items = <SalaryTabItem>[
      const SalaryTabItem(icon: Icons.payments_outlined, label: '到手工资'),
      const SalaryTabItem(icon: Icons.show_chart_outlined, label: '工资统计'),
      const SalaryTabItem(icon: Icons.home_outlined, label: '房贷计算'),
    ];
    return Scaffold(
      appBar: AppBar(
        // 标题固定为工具名：三个页签共用同一个页面，标题跟着页签变会让人
        // 以为是三个不同工具；当前页签由下方切换条表达。
        title: Text(
          tr('工资计算器'),
          key: const ValueKey('salary-page-title'),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: SalaryTabSwitch(
            items: items,
            index: _index,
            onChanged: _goTo,
          ),
        ),
      ),
      body: PageView(
        controller: _page,
        onPageChanged: (index) => setState(() => _index = index),
        children: <Widget>[
          const SalaryCalculatorView(),
          SalaryStatsPage(
            embedded: true,
            mortgageRevision: _mortgageRevision,
          ),
          MortgageView(
            onChanged: () => _mortgageRevision.value++,
          ),
        ],
      ),
    );
  }
}

/// 到手工资：五险一金、个税与到手工资。
///
/// 输入：城市、税前月薪、社保/公积金基数（留空跟随工资）、各项缴纳比例
/// （默认取城市口径，可手改，也可从个人信息导入）、专项附加扣除。
/// 输出：逐项个人/单位缴纳额、个税、到手工资、单位用工成本与年度预估。
class SalaryCalculatorView extends StatefulWidget {
  const SalaryCalculatorView({super.key});

  @override
  State<SalaryCalculatorView> createState() => _SalaryCalculatorViewState();
}

class _SalaryCalculatorViewState extends State<SalaryCalculatorView>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _gross = TextEditingController(text: '12000');
  final TextEditingController _socialBase = TextEditingController();
  final TextEditingController _fundBase = TextEditingController();
  final TextEditingController _specialDeduction = TextEditingController();

  final Map<String, TextEditingController> _personal =
      <String, TextEditingController>{
    for (final item in kInsuranceItems) item.id: TextEditingController(),
  };
  final Map<String, TextEditingController> _employer =
      <String, TextEditingController>{
    for (final item in kInsuranceItems) item.id: TextEditingController(),
  };

  String _cityId = CityRules.defaultCityId;
  bool _cumulative = true;
  int _month = DateTime.now().month;
  bool _ratesCustomized = false;
  UserProfile _profile = UserProfile();

  CityRules get _city => CityRules.byId(_cityId);

  /// 页签内常驻：切到别的页再回来，输入与滚动位置都保留。
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _fillRatesFromCity(_city);
    _restoreInputs();
  }

  @override
  void dispose() {
    _gross.dispose();
    _socialBase.dispose();
    _fundBase.dispose();
    _specialDeduction.dispose();
    for (final controller in _personal.values) {
      controller.dispose();
    }
    for (final controller in _employer.values) {
      controller.dispose();
    }
    super.dispose();
  }

  double _number(TextEditingController controller) =>
      double.tryParse(controller.text.trim()) ?? 0;

  /// 打开页面时优先恢复上次编辑的输入缓存；没有缓存才读个人信息。
  /// 缓存是「临时输入」，个人信息是「用户主动保存的档案」，两者不互相覆盖。
  Future<void> _restoreInputs() async {
    final snapshot = await SalaryInputCache.load();
    final profile = await ProfileRepository.load();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      if (snapshot != null && snapshot.cityId.isNotEmpty) {
        _applySnapshot(snapshot);
      } else if (!profile.isEmpty) {
        _applyProfile(profile);
      }
    });
    _persist();
  }

  void _applySnapshot(SalaryInputSnapshot snapshot) {
    _cityId = snapshot.cityId;
    _gross.text = snapshot.valueOf(SalaryInputSnapshot.grossKey);
    _socialBase.text = snapshot.valueOf(SalaryInputSnapshot.socialBaseKey);
    _fundBase.text = snapshot.valueOf(SalaryInputSnapshot.fundBaseKey);
    _specialDeduction.text =
        snapshot.valueOf(SalaryInputSnapshot.specialDeductionKey);
    for (final item in kInsuranceItems) {
      _personal[item.id]!.text =
          snapshot.valueOf(SalaryInputSnapshot.personalKey(item.id));
      _employer[item.id]!.text =
          snapshot.valueOf(SalaryInputSnapshot.employerKey(item.id));
    }
    _cumulative = snapshot.cumulative;
    _month = snapshot.month.clamp(1, 12);
    _ratesCustomized = snapshot.ratesCustomized;
  }

  /// 每次输入/选项变化都把当前状态写回缓存，关掉页面再进来原样恢复。
  SalaryInputSnapshot _snapshot() => SalaryInputSnapshot(
        cityId: _cityId,
        values: <String, String>{
          SalaryInputSnapshot.grossKey: _gross.text,
          SalaryInputSnapshot.socialBaseKey: _socialBase.text,
          SalaryInputSnapshot.fundBaseKey: _fundBase.text,
          SalaryInputSnapshot.specialDeductionKey: _specialDeduction.text,
          for (final item in kInsuranceItems)
            SalaryInputSnapshot.personalKey(item.id): _personal[item.id]!.text,
          for (final item in kInsuranceItems)
            SalaryInputSnapshot.employerKey(item.id): _employer[item.id]!.text,
        },
        cumulative: _cumulative,
        month: _month,
        ratesCustomized: _ratesCustomized,
      );

  void _persist() {
    unawaited(SalaryInputCache.save(_snapshot()));
    // 同一套口径给「工资统计」页签用：切过去就能按当前城市 / 比例出图。
    SalarySettings.current.value = SalarySettings(
      cityId: _cityId,
      personalRates: <String, double>{
        for (final item in kInsuranceItems)
          item.id: _number(_personal[item.id]!),
      },
      socialBase: _number(_socialBase),
      fundBase: _number(_fundBase),
      specialDeduction: _number(_specialDeduction),
    );
  }

  /// 需同时刷新计算结果的输入变更：setState 后顺手写缓存。
  void _update(VoidCallback mutate) {
    setState(mutate);
    _persist();
  }

  /// 从「养老与税优信息」页返回后只刷新个人资料，
  /// 不覆盖用户正在计算器里临时修改的工资与比例。
  Future<void> _openPensionProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProfilePensionPage()),
    );
    final profile = await ProfileRepository.load();
    if (mounted) setState(() => _profile = profile);
  }

  void _applyProfile(UserProfile profile) {
    _cityId = profile.cityId;
    final city = CityRules.byId(_cityId);
    if (profile.gross != null) _gross.text = textOf(profile.gross);
    if (profile.socialBase != null) {
      _socialBase.text = textOf(profile.socialBase);
    }
    if (profile.fundBase != null) _fundBase.text = textOf(profile.fundBase);
    if (profile.specialDeduction != null) {
      _specialDeduction.text = textOf(profile.specialDeduction);
    }
    _setRatesFromProfile(profile, city);
    _ratesCustomized = kInsuranceItems.any(
      (item) =>
          profile.personalRate(item.id) != null ||
          profile.employerRate(item.id) != null,
    );
  }

  void _setRatesFromProfile(UserProfile profile, CityRules city) {
    for (final item in kInsuranceItems) {
      final personal = profile.personalRate(item.id);
      final employer = profile.employerRate(item.id);
      _personal[item.id]!.text = personal != null
          ? textOf(personal)
          : formatRate(city.personalRate(item.id));
      _employer[item.id]!.text = employer != null
          ? textOf(employer)
          : formatRate(city.employerRate(item.id));
    }
  }

  void _fillRatesFromCity(CityRules city) {
    for (final item in kInsuranceItems) {
      _personal[item.id]!.text = formatRate(city.personalRate(item.id));
      _employer[item.id]!.text = formatRate(city.employerRate(item.id));
    }
  }

  void _onCityChanged(String cityId) {
    _update(() {
      _cityId = cityId;
      if (!_ratesCustomized) _fillRatesFromCity(_city);
    });
  }

  void _restoreCityRates() {
    _update(() {
      _ratesCustomized = false;
      _fillRatesFromCity(_city);
    });
    showToast(context, trf('已恢复{city}默认比例', {'city': tr(_city.name)}));
  }

  /// 把当前输入写成「存储空间 › 个人信息 › 个人信息.json」（结构化 v2）。
  Future<void> _saveAsProfile() async {
    final data = Map<String, dynamic>.from(_profile.toJson())
      ..remove('schemaVersion');
    UserProfile.putCity(data, _cityId);
    UserProfile.putNumber(data, 'gross', _gross.text);
    UserProfile.putNumber(data, 'socialBase', _socialBase.text);
    UserProfile.putNumber(data, 'fundBase', _fundBase.text);
    UserProfile.putNumber(
      data,
      UserProfile.specialDeductionKey,
      _specialDeduction.text,
    );
    for (final item in kInsuranceItems) {
      UserProfile.putNumber(
        data,
        UserProfile.personalRateKey(item.id),
        _personal[item.id]!.text,
      );
      UserProfile.putNumber(
        data,
        UserProfile.employerRateKey(item.id),
        _employer[item.id]!.text,
      );
    }
    final profile = UserProfile(data);
    await ProfileRepository.save(profile);
    _persist();
    if (!mounted) return;
    setState(() => _profile = profile);
    showToast(context, tr('已保存到存储空间 › 个人信息.json'));
  }

  /// 工资统计页不再单独打开：这里是页签之一，直接复用外层 shell 的导航。
  SalaryResult get _result {
    final city = _city;
    return SalaryCalculator.compute(
      SalaryInput(
        gross: _number(_gross),
        socialBase: _number(_socialBase),
        fundBase: _number(_fundBase),
        city: city,
        personalRates: <String, double>{
          for (final item in kInsuranceItems)
            item.id: _number(_personal[item.id]!),
        },
        employerRates: <String, double>{
          for (final item in kInsuranceItems)
            item.id: _number(_employer[item.id]!),
        },
        specialDeduction: _number(_specialDeduction),
        month: _month,
        cumulative: _cumulative,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final result = _result;
    return ListView(
      key: const ValueKey('salary-calculator-scroll'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        _inputSection(),
        const SizedBox(height: 10),
        _rateSection(),
        const SizedBox(height: 10),
        _taxSection(result),
        const SizedBox(height: 10),
        _summaryCard(result),
        const SizedBox(height: 10),
        _detailSection(result),
        const SizedBox(height: 10),
        PensionView(
          cityId: _cityId,
          gross: _number(_gross),
          socialBase: result.socialBaseUsed,
          personalTotal: result.personalTotal,
          profile: _profile,
          onOpenProfile: _openPensionProfile,
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const ValueKey('salary-save-profile'),
          onPressed: _saveAsProfile,
          icon: const Icon(Icons.save_outlined, size: 18),
          label: Text(tr('保存到个人信息文件')),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
          ),
        ),
      ],
    );
  }

  Widget _inputSection() {
    final city = _city;
    final range = city.socialBaseMax > 0
        ? trf('城市区间 {min} – {max} 元', {
            'min': formatMoney(city.socialBaseMin, digits: 0),
            'max': formatMoney(city.socialBaseMax, digits: 0),
          })
        : tr('该城市不限基数区间');
    return CollapseCard(
      title: tr('工资与基数'),
      dense: true,
      actions: [
        InfoHint(text: tr('基数留空则跟随税前月薪，并按城市上下限自动收敛')),
      ],
      children: [
        DropdownButtonFormField<String>(
          value: _cityId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: tr('缴纳城市'),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          items: CityRules.all
              .map(
                (item) => DropdownMenuItem<String>(
                  value: item.id,
                  child: Text(tr(item.name)),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) _onCityChanged(value);
          },
        ),
        const SizedBox(height: 8),
        NumberField(
          controller: _gross,
          label: tr('税前月工资'),
          suffix: tr('元'),
          outerPadding: const EdgeInsets.only(bottom: 8),
          onChanged: (_) => _update(() {}),
        ),
        NumberField(
          controller: _socialBase,
          label: tr('社保缴费基数'),
          suffix: tr('元'),
          helper: range,
          outerPadding: const EdgeInsets.only(bottom: 8),
          onChanged: (_) => _update(() {}),
        ),
        NumberField(
          controller: _fundBase,
          label: tr('公积金缴费基数'),
          suffix: tr('元'),
          helper: _city.fundBaseMax > 0
              ? trf('公积金区间 {min} – {max} 元', {
                  'min': formatMoney(_city.fundBaseMin, digits: 0),
                  'max': formatMoney(_city.fundBaseMax, digits: 0),
                })
              : null,
          onChanged: (_) => _update(() {}),
          outerPadding: EdgeInsets.zero,
        ),
      ],
    );
  }

  Widget _rateSection() {
    return RateSection(
      title: tr('五险一金比例'),
      dense: true,
      personal: _personal,
      employer: _employer,
      onChanged: () {
        _ratesCustomized = true;
        _update(() {});
      },
      actions: _ratesCustomized
          ? [
              TextButton(
                onPressed: _restoreCityRates,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(tr('用城市默认')),
              ),
            ]
          : null,
    );
  }

  Widget _taxSection(SalaryResult result) {
    final theme = Theme.of(context);
    return SectionCard(
      title: tr('个税设置'),
      dense: true,
      trailing: InfoHint(
        text: '${tr('全国统一税率表，起征点 5,000 元/月')}\n'
            '${tr('子女教育、房贷、赡养老人等合计')}\n'
            '${tr('不含五险一金与 5,000 元基本减除费用')}',
      ),
      children: [
        // 口径与月份同一行：两者本来就是「这次按哪个月、用哪种算法」的一组。
        Row(
          children: [
            MiniSegmented<bool>(
              options: [
                MiniSegmentedOption<bool>(
                  value: true,
                  label: tr('累计预扣'),
                  key: const ValueKey('salary-tax-cumulative'),
                ),
                MiniSegmentedOption<bool>(
                  value: false,
                  label: tr('月度估算'),
                  key: const ValueKey('salary-tax-monthly'),
                ),
              ],
              selected: _cumulative,
              onChanged: (value) => _update(() => _cumulative = value),
            ),
            const Spacer(),
            if (_cumulative)
              DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _month,
                  isDense: true,
                  borderRadius: BorderRadius.circular(12),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                  items: List<DropdownMenuItem<int>>.generate(
                    12,
                    (index) => DropdownMenuItem<int>(
                      value: index + 1,
                      child: Text(trf('{n} 月', {'n': index + 1})),
                    ),
                  ),
                  onChanged: (value) {
                    if (value != null) _update(() => _month = value);
                  },
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        NumberField(
          controller: _specialDeduction,
          label: tr('每月专项附加扣除'),
          suffix: tr('元'),
          onChanged: (_) => _update(() {}),
          outerPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 6),
        Text(
          _cumulative
              ? trf('第 {m} 月适用 {rate} 档，累计应纳税所得额 {v} 元', {
                  'm': _month,
                  'rate': result.bracket.label,
                  'v': formatMoney(result.taxableYtd, digits: 0),
                })
              : trf('按 {rate} 档速算，当月应纳税所得额 {v} 元', {
                  'rate': result.bracket.label,
                  'v': formatMoney(result.taxableMonthly, digits: 0),
                }),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _summaryCard(SalaryResult result) {
    final scheme = Theme.of(context).colorScheme;
    // 渐变块可能偏深（深色主题）也可能偏亮（蜜蜂黄 / 黄昏沙丘等浅色主题色），
    // 文字统一按主色亮度取前景，避免深色块上出现白字/黑字看不清。
    final onCard = AppTheme.readableOn(scheme.primary);
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
        children: [
          Text(
            tr('预计到手工资'),
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
            children: [
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
                  formatMoney(result.net),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: onCard,
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _metric(tr('税前'), result.gross, onCard),
              _metric(tr('个人扣除'), result.deductionTotal, onCard),
              _metric(tr('单位成本'), result.employerCost, onCard),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: result.takeHomeRate.clamp(0, 1),
              minHeight: 5,
              backgroundColor: onCard.withOpacity(0.22),
              valueColor: AlwaysStoppedAnimation<Color>(onCard),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            trf('到手率 {v}%', {
              'v': (result.takeHomeRate * 100).toStringAsFixed(1),
            }),
            style: TextStyle(
              color: onCard.withOpacity(0.82),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, double value, Color onCard) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: onCard.withOpacity(0.72),
              fontSize: 11,
            ),
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

  Widget _detailSection(SalaryResult result) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final adjusted = result.socialBaseAdjusted || result.fundBaseAdjusted;
    return SectionCard(
      title: tr('缴纳明细'),
      dense: true,
      subtitle: trf('个人合计 ¥{a} · 单位合计 ¥{b}', {
        'a': formatMoney(result.personalTotal),
        'b': formatMoney(result.employerTotal),
      }),
      children: [
        if (adjusted) ...[
          HintBanner(
            text: trf('已按{city}基数区间调整：社保基数 ¥{a}、公积金基数 ¥{b}。', {
              'city': tr(_city.name),
              'a': formatMoney(result.socialBaseUsed, digits: 0),
              'b': formatMoney(result.fundBaseUsed, digits: 0),
            }),
            icon: Icons.tune,
          ),
          const SizedBox(height: 10),
        ],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withOpacity(0.55),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(flex: 3, child: _th(tr('项目'))),
              Expanded(flex: 4, child: _th(tr('基数'))),
              Expanded(flex: 3, child: _th(tr('个人'), alignEnd: true)),
              Expanded(flex: 3, child: _th(tr('单位'), alignEnd: true)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        for (final line in result.lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    tr(line.item.name),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    formatMoney(line.base, digits: 0),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    formatMoney(line.personal),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    formatMoney(line.employer),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 18),
        StatRow(
          label: tr('个人五险一金合计'),
          value: '¥${formatMoney(result.personalTotal)}',
        ),
        StatRow(
          label: tr('单位五险一金合计'),
          value: '¥${formatMoney(result.employerTotal)}',
        ),
        StatRow(
          label: tr('个人所得税'),
          value: '¥${formatMoney(result.tax)}',
          secondary: _cumulative
              ? trf('累计预扣法 · 第 {m} 月 · {rate} 档', {
                  'm': result.month,
                  'rate': result.bracket.label,
                })
              : trf('月度估算 · {rate} 档', {'rate': result.bracket.label}),
        ),
        StatRow(
          label: tr('单位用工成本'),
          value: '¥${formatMoney(result.employerCost)}',
        ),
        const Divider(height: 18),
        StatRow(
          label: tr('年度预估（12 个月）'),
          value: '¥${formatMoney(result.annualNet, digits: 0)}',
          secondary: trf('全年个税 ¥{a} · 全年单位成本 ¥{b}', {
            'a': formatMoney(result.annualTax, digits: 0),
            'b': formatMoney(result.annualEmployerCost, digits: 0),
          }),
          emphasize: true,
          valueColor: scheme.primary,
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
