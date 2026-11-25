import '../../core/insurance.dart';
import '../tools/salary/city_rules.dart';

/// 个人信息。
///
/// 用 Map 承载并携带版本号，新增字段时无需迁移旧数据；页面上未填写的项
/// 不写入 Map，计算时即视为「忽略」。未知字段会在保存时原样保留。
class UserProfile {
  UserProfile([Map<String, dynamic>? data])
      : _data = <String, dynamic>{...?data};

  /// 文件里的结构化格式版本。v1 是全部字段平铺在顶层，v2 拆成
  /// salary / pension 两段并把缴纳比例收进嵌套 Map。
  static const int schemaVersion = 2;

  final Map<String, dynamic> _data;

  static const String _cityKey = 'city';
  static const String _grossKey = 'gross';
  static const String _socialBaseKey = 'socialBase';
  static const String _fundBaseKey = 'fundBase';

  // 养老测算 / 个人养老金税优所需字段（全部选填，未填则用页面内的估值）。
  static const String annualSalaryKey = 'annualSalary';
  static const String currentAgeKey = 'currentAge';
  static const String retireAgeKey = 'retireAge';
  static const String paidYearsKey = 'paidYears';
  static const String accountBalanceKey = 'accountBalance';
  static const String salaryGrowthKey = 'salaryGrowthPct';
  static const String personalPensionKey = 'personalPension';
  static const String specialDeductionKey = 'specialDeduction';
  static const String customPensionBaseKey = 'customPensionBase';

  static String personalRateKey(String itemId) => 'personal.$itemId';

  static String employerRateKey(String itemId) => 'employer.$itemId';

  /// 运行时存储（SharedPreferences）仍用扁平 Map，页面各处直接按键读写，
  /// 不需要迁移。
  Map<String, dynamic> toJson() => <String, dynamic>{
        ..._data,
        'schemaVersion': schemaVersion,
      };

  /// 存储空间「个人信息.json」的内容：按用途分组，便于人读与外部编辑。
  ///
  /// 未知字段收进 `extra`，不会被保存流程丢掉；时间字段只影响文件，
  /// 不参与相等性比较。
  Map<String, dynamic> toStorageJson({DateTime? now}) {
    final salary = <String, dynamic>{};
    final pension = <String, dynamic>{};
    final personalRates = <String, dynamic>{};
    final employerRates = <String, dynamic>{};
    final extra = <String, dynamic>{};
    _data.forEach((key, value) {
      if (key == 'schemaVersion' || key == 'updatedAt') return;
      if (key.startsWith('personal.')) {
        personalRates[key.substring('personal.'.length)] = value;
      } else if (key.startsWith('employer.')) {
        employerRates[key.substring('employer.'.length)] = value;
      } else if (_pensionKeys.contains(key)) {
        pension[key] = value;
      } else if (_salaryKeys.contains(key)) {
        salary[key] = value;
      } else {
        extra[key] = value;
      }
    });
    return <String, dynamic>{
      'schemaVersion': schemaVersion,
      'updatedAt': (now ?? DateTime.now()).toIso8601String(),
      'salary': <String, dynamic>{
        ...salary,
        'personalRates': personalRates,
        'employerRates': employerRates,
      },
      'pension': pension,
      if (extra.isNotEmpty) 'extra': extra,
    };
  }

  /// 解析存储空间里的个人信息文件，同时兼容 v1 扁平格式。
  factory UserProfile.fromStorageJson(Map<String, dynamic> json) {
    final data = <String, dynamic>{};
    final salary = json['salary'];
    if (salary is Map) {
      salary.forEach((key, value) {
        if (key == 'personalRates' || key == 'employerRates') return;
        data[key.toString()] = value;
      });
      final personal = salary['personalRates'];
      if (personal is Map) {
        personal.forEach((key, value) => data['personal.$key'] = value);
      }
      final employer = salary['employerRates'];
      if (employer is Map) {
        employer.forEach((key, value) => data['employer.$key'] = value);
      }
    }
    final pension = json['pension'];
    if (pension is Map) {
      pension.forEach((key, value) => data[key.toString()] = value);
    }
    final extra = json['extra'];
    if (extra is Map) {
      extra.forEach((key, value) => data[key.toString()] = value);
    }
    // v1：所有字段直接挂在顶层。分组已解析过的键优先，避免被旧值覆盖。
    json.forEach((key, value) {
      if (key == 'schemaVersion' ||
          key == 'updatedAt' ||
          key == 'salary' ||
          key == 'pension' ||
          key == 'extra') {
        return;
      }
      data.putIfAbsent(key.toString(), () => value);
    });
    return UserProfile(data);
  }

  static const Set<String> _salaryKeys = <String>{
    _cityKey,
    _grossKey,
    _socialBaseKey,
    _fundBaseKey,
    specialDeductionKey,
  };

  static const Set<String> _pensionKeys = <String>{
    annualSalaryKey,
    currentAgeKey,
    retireAgeKey,
    paidYearsKey,
    accountBalanceKey,
    salaryGrowthKey,
    personalPensionKey,
    customPensionBaseKey,
  };

  String get cityId => _string(_cityKey) ?? CityRules.defaultCityId;

  CityRules get city => CityRules.byId(cityId);

  double? get gross => _number(_grossKey);

  double? get socialBase => _number(_socialBaseKey);

  double? get fundBase => _number(_fundBaseKey);

  /// 年薪估计值（元/年）。留空时计算器用「税前月薪 × 12」。
  double? get annualSalary => _number(annualSalaryKey);

  double? get currentAge => _number(currentAgeKey);
  double? get retireAge => _number(retireAgeKey);
  double? get paidYears => _number(paidYearsKey);

  /// 个人账户已累计储存额（元）。
  double? get accountBalance => _number(accountBalanceKey);

  /// 年薪增长率（百分数，3 表示 3%）。
  double? get salaryGrowthPct => _number(salaryGrowthKey);

  /// 个人养老金年度计划缴纳额（元，上限 12000）。
  double? get personalPension => _number(personalPensionKey);

  /// 每月专项附加扣除（元/月）。
  double? get specialDeduction => _number(specialDeductionKey);

  /// 覆盖所在城市的养老金计发基数（元/月）。
  double? get customPensionBase => _number(customPensionBaseKey);

  double get currentAgeOrDefault => currentAge ?? 35;
  double get retireAgeOrDefault => retireAge ?? 60;
  double get paidYearsOrDefault => paidYears ?? 10;
  double get salaryGrowth => (salaryGrowthPct ?? 3) / 100;
  double get personalPensionOrDefault =>
      (personalPension ?? 12000).clamp(0, 12000).toDouble();
  double get specialDeductionOrDefault => specialDeduction ?? 0;

  /// 是否填过任意一项养老/税优信息。
  bool get hasPensionInfo => <String>[
        annualSalaryKey,
        currentAgeKey,
        retireAgeKey,
        paidYearsKey,
        accountBalanceKey,
        salaryGrowthKey,
        personalPensionKey,
        specialDeductionKey,
        customPensionBaseKey,
      ].any((key) => _data[key] != null);

  double? personalRate(String itemId) => _number(personalRateKey(itemId));

  double? employerRate(String itemId) => _number(employerRateKey(itemId));

  /// 是否填写过任意一项。
  bool get isEmpty {
    if (_data.isEmpty) return true;
    return _data.keys.every((key) => key == 'schemaVersion');
  }

  /// 已填写的字段数量，用于总览页展示。
  int get filledCount => _data.keys
      .where((key) => key != 'schemaVersion' && _data[key] != null)
      .length;

  /// 有意填写的比例项（未填写的险种返回 null，计算时回退城市默认值）。
  Map<String, double?> personalRates() => <String, double?>{
        for (final item in kInsuranceItems) item.id: personalRate(item.id),
      };

  Map<String, double?> employerRates() => <String, double?>{
        for (final item in kInsuranceItems) item.id: employerRate(item.id),
      };

  String? _string(String key) {
    final value = _data[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  double? _number(String key) {
    final value = _data[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  /// 把输入框文本写入 Map：能解析为数字才保留，否则删除该键（= 忽略）。
  static void putNumber(
    Map<String, dynamic> data,
    String key,
    String? text,
  ) {
    final raw = text?.replaceAll(',', '').trim() ?? '';
    if (raw.isEmpty) {
      data.remove(key);
      return;
    }
    final parsed = double.tryParse(raw);
    if (parsed == null) {
      data.remove(key);
      return;
    }
    data[key] = parsed;
  }

  static void putCity(Map<String, dynamic> data, String cityId) {
    data[_cityKey] = cityId;
  }
}
