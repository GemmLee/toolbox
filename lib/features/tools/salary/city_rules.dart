/// 城市社保/公积金规则。
///
/// 扩展方式：在 [CityRules.all] 中追加一条 [CityRules] 即可，计算器的城市
/// 下拉框、默认比例、基数上下限会自动生效。
///
/// 说明：内置基数为公开口径的参考值（每年 7 月左右调整），页面内允许用户
/// 覆盖基数与比例，因此不影响特殊情况的准确性。
class CityRules {
  const CityRules({
    required this.id,
    required this.name,
    required this.socialBaseMin,
    required this.socialBaseMax,
    required this.fundBaseMin,
    required this.fundBaseMax,
    required this.personalRates,
    required this.employerRates,
  });

  final String id;
  final String name;

  /// 社保缴费基数下限/上限（元/月），0 表示不限制。
  final double socialBaseMin;
  final double socialBaseMax;

  /// 公积金缴存基数下限/上限（元/月），0 表示不限制。
  final double fundBaseMin;
  final double fundBaseMax;

  /// key 为险种 id（见 `core/insurance.dart`），value 为百分比数值，如 8 表示 8%。
  final Map<String, double> personalRates;
  final Map<String, double> employerRates;

  double personalRate(String itemId) => personalRates[itemId] ?? 0;

  double employerRate(String itemId) => employerRates[itemId] ?? 0;

  /// 把任意基数限制在城市允许区间内。
  double clampSocialBase(double base) =>
      _clamp(base, socialBaseMin, socialBaseMax);

  double clampFundBase(double base) => _clamp(base, fundBaseMin, fundBaseMax);

  static double _clamp(double value, double min, double max) {
    var result = value;
    if (min > 0 && result < min) result = min;
    if (max > 0 && result > max) result = max;
    return result;
  }

  static const String defaultCityId = 'ningbo';

  static const CityRules custom = CityRules(
    id: 'custom',
    name: '自定义',
    socialBaseMin: 0,
    socialBaseMax: 0,
    fundBaseMin: 0,
    fundBaseMax: 0,
    personalRates: <String, double>{
      'pension': 8,
      'medical': 2,
      'unemployment': 0.5,
      'injury': 0,
      'maternity': 0,
      'fund': 12,
    },
    employerRates: <String, double>{
      'pension': 16,
      'medical': 9.5,
      'unemployment': 0.5,
      'injury': 0.2,
      'maternity': 0,
      'fund': 12,
    },
  );

  static const List<CityRules> all = <CityRules>[
    CityRules(
      id: 'ningbo',
      name: '宁波',
      socialBaseMin: 4462,
      socialBaseMax: 24930,
      fundBaseMin: 2490,
      fundBaseMax: 38520,
      personalRates: <String, double>{
        'pension': 8,
        'medical': 2,
        'unemployment': 0.5,
        'injury': 0,
        'maternity': 0,
        'fund': 12,
      },
      employerRates: <String, double>{
        'pension': 16,
        'medical': 9,
        'unemployment': 0.5,
        'injury': 0.2,
        'maternity': 0,
        'fund': 12,
      },
    ),
    CityRules(
      id: 'hangzhou',
      name: '杭州',
      socialBaseMin: 4812,
      socialBaseMax: 24930,
      fundBaseMin: 2490,
      fundBaseMax: 39530,
      personalRates: <String, double>{
        'pension': 8,
        'medical': 2,
        'unemployment': 0.5,
        'injury': 0,
        'maternity': 0,
        'fund': 12,
      },
      employerRates: <String, double>{
        'pension': 14,
        'medical': 9.9,
        'unemployment': 0.5,
        'injury': 0.2,
        'maternity': 0,
        'fund': 12,
      },
    ),
    CityRules(
      id: 'shanghai',
      name: '上海',
      socialBaseMin: 7384,
      socialBaseMax: 36921,
      fundBaseMin: 2690,
      fundBaseMax: 36921,
      personalRates: <String, double>{
        'pension': 8,
        'medical': 2,
        'unemployment': 0.5,
        'injury': 0,
        'maternity': 0,
        'fund': 7,
      },
      employerRates: <String, double>{
        'pension': 16,
        'medical': 9.5,
        'unemployment': 0.5,
        'injury': 0.16,
        'maternity': 1,
        'fund': 7,
      },
    ),
    CityRules(
      id: 'shenzhen',
      name: '深圳',
      socialBaseMin: 4492,
      socialBaseMax: 27501,
      fundBaseMin: 2360,
      fundBaseMax: 43659,
      personalRates: <String, double>{
        'pension': 8,
        'medical': 2,
        'unemployment': 0.3,
        'injury': 0,
        'maternity': 0,
        'fund': 12,
      },
      employerRates: <String, double>{
        'pension': 14,
        'medical': 5.2,
        'unemployment': 0.7,
        'injury': 0.4,
        'maternity': 0.5,
        'fund': 12,
      },
    ),
    CityRules(
      id: 'beijing',
      name: '北京',
      socialBaseMin: 6821,
      socialBaseMax: 35283,
      fundBaseMin: 2420,
      fundBaseMax: 35283,
      personalRates: <String, double>{
        'pension': 8,
        'medical': 2,
        'unemployment': 0.5,
        'injury': 0,
        'maternity': 0,
        'fund': 12,
      },
      employerRates: <String, double>{
        'pension': 16,
        'medical': 9,
        'unemployment': 0.5,
        'injury': 0.4,
        'maternity': 0,
        'fund': 12,
      },
    ),
    CityRules(
      id: 'guangzhou',
      name: '广州',
      socialBaseMin: 4546,
      socialBaseMax: 26421,
      fundBaseMin: 2300,
      fundBaseMax: 39579,
      personalRates: <String, double>{
        'pension': 8,
        'medical': 2,
        'unemployment': 0.2,
        'injury': 0,
        'maternity': 0,
        'fund': 12,
      },
      employerRates: <String, double>{
        'pension': 15,
        'medical': 5.35,
        'unemployment': 0.8,
        'injury': 0.2,
        'maternity': 0,
        'fund': 12,
      },
    ),
    CityRules(
      id: 'xian',
      name: '西安',
      socialBaseMin: 4559,
      socialBaseMax: 22795,
      fundBaseMin: 2160,
      fundBaseMax: 27770,
      personalRates: <String, double>{
        'pension': 8,
        'medical': 2,
        'unemployment': 0.3,
        'injury': 0,
        'maternity': 0,
        'fund': 12,
      },
      employerRates: <String, double>{
        'pension': 16,
        'medical': 8,
        'unemployment': 0.7,
        'injury': 0.2,
        'maternity': 1,
        'fund': 12,
      },
    ),
    custom,
  ];

  static CityRules byId(String? id) {
    if (id == null) return all.first;
    for (final city in all) {
      if (city.id == id) return city;
    }
    return all.first;
  }
}
