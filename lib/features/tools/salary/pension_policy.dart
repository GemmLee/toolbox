/// 各城市职工基本养老保险政策参数（2025 年公开口径）。
///
/// 计发基数来自各省/市人社部门 2025 年公布的「基本养老金计发基数」：
/// 上海 12434、北京 12049、深圳 11293（单列）、广东 9493、
/// 浙江 8433、陕西 7881（元/月）。省内城市（杭州/宁波、广州）
/// 一般执行全省统一口径，深圳单列。
///
/// 这些数值每年调整，页面允许用个人信息中的「自定义计发基数」覆盖，
/// 测算结果仅为估算，不作为社保经办依据。
class PensionPolicy {
  const PensionPolicy({
    required this.cityId,
    required this.pensionBase,
    required this.avgWage,
    required this.accountRate,
    required this.note,
    required this.source,
  });

  final String cityId;

  /// 基本养老金计发基数（元/月）。
  final double pensionBase;

  /// 用于估算缴费指数的当地职工月平均工资（元/月）。
  final double avgWage;

  /// 个人账户记账利率（年化，2024 年全国公布约 2.62%）。
  final double accountRate;

  /// 地方政策要点。
  final String note;

  /// 数据来源说明。
  final String source;

  static const double kDefaultAccountRate = 0.0262;

  static const List<PensionPolicy> all = <PensionPolicy>[
    PensionPolicy(
      cityId: 'ningbo',
      pensionBase: 8433,
      avgWage: 8310,
      accountRate: kDefaultAccountRate,
      note: '浙江全省统一计发基数，宁波与杭州同口径；过渡性养老金另按视同缴费年限计发。',
      source: '浙江省 2025 年基本养老金计发基数',
    ),
    PensionPolicy(
      cityId: 'hangzhou',
      pensionBase: 8433,
      avgWage: 8310,
      accountRate: kDefaultAccountRate,
      note: '浙江全省统一计发基数，宁波与杭州同口径；过渡性养老金另按视同缴费年限计发。',
      source: '浙江省 2025 年基本养老金计发基数',
    ),
    PensionPolicy(
      cityId: 'shanghai',
      pensionBase: 12434,
      avgWage: 12434,
      accountRate: kDefaultAccountRate,
      note: '全国最高计发基数；另有过渡性养老金与增发政策，实际待遇通常高于本测算。',
      source: '上海市 2025 年基本养老金计发基数',
    ),
    PensionPolicy(
      cityId: 'shenzhen',
      pensionBase: 11293,
      avgWage: 11293,
      accountRate: kDefaultAccountRate,
      note: '深圳企业职工计发基数单列，明显高于广东其他地区；机关事业单位执行省口径。',
      source: '深圳市 2025 年企业职工基本养老金计发基数',
    ),
    PensionPolicy(
      cityId: 'beijing',
      pensionBase: 12049,
      avgWage: 12049,
      accountRate: kDefaultAccountRate,
      note: '2025 年计发基数 12049 元/月（2024 年为 11883），年内退休人员会重算补发。',
      source: '北京市 2025 年参保人员社会保险待遇通告',
    ),
    PensionPolicy(
      cityId: 'guangzhou',
      pensionBase: 9493,
      avgWage: 9493,
      accountRate: kDefaultAccountRate,
      note: '执行广东省统一计发基数（2024 年为 9307）；深圳单列，不适用本数值。',
      source: '广东省 2025 年基本养老金计发基数',
    ),
    PensionPolicy(
      cityId: 'xian',
      pensionBase: 7881,
      avgWage: 7881,
      accountRate: kDefaultAccountRate,
      note: '执行陕西省统一计发基数；艰苦边远地区另有倾斜调整。',
      source: '陕西省 2025 年基本养老金计发基数',
    ),
    PensionPolicy(
      cityId: 'custom',
      pensionBase: 8433,
      avgWage: 8433,
      accountRate: kDefaultAccountRate,
      note: '自定义城市：请在个人信息里填写当地公布的计发基数后再测算。',
      source: '默认值（浙江 2025 年口径）',
    ),
  ];

  static PensionPolicy byCity(String cityId) {
    for (final policy in all) {
      if (policy.cityId == cityId) return policy;
    }
    return all.first;
  }
}

/// 个人账户养老金计发月数表（国发〔2005〕38 号）。
///
/// 退休年龄介于表内年龄之间时线性插值，超出范围取端点。
const Map<int, double> kPensionMonths = <int, double>{
  40: 233,
  45: 216,
  50: 195,
  55: 170,
  60: 139,
  65: 101,
  70: 56,
};

/// 按退休年龄取计发月数。
double pensionMonthsOf(double retireAge) {
  final ages = kPensionMonths.keys.toList()..sort();
  if (retireAge <= ages.first) return kPensionMonths[ages.first]!;
  if (retireAge >= ages.last) return kPensionMonths[ages.last]!;
  for (var i = 0; i < ages.length - 1; i++) {
    final a = ages[i];
    final b = ages[i + 1];
    if (retireAge >= a && retireAge <= b) {
      final t = (retireAge - a) / (b - a);
      final va = kPensionMonths[a]!;
      final vb = kPensionMonths[b]!;
      return va + (vb - va) * t;
    }
  }
  return kPensionMonths[60]!;
}
