/// 五险一金项目定义。
///
/// 新增险种只需在 [kInsuranceItems] 追加一条，计算器、个人信息页、结果明细
/// 都会自动跟随，无需改动其它代码。
class InsuranceItem {
  const InsuranceItem(
    this.id,
    this.name,
    this.shortName, {
    this.useFundBase = false,
  });

  /// 稳定标识，会持久化到本地，不要随意修改。
  final String id;
  final String name;
  final String shortName;

  /// true 表示使用公积金基数，false 表示使用社保基数。
  final bool useFundBase;
}

const List<InsuranceItem> kInsuranceItems = <InsuranceItem>[
  InsuranceItem('pension', '养老保险', '养老'),
  InsuranceItem('medical', '医疗保险', '医疗'),
  InsuranceItem('unemployment', '失业保险', '失业'),
  InsuranceItem('injury', '工伤保险', '工伤'),
  InsuranceItem('maternity', '生育保险', '生育'),
  InsuranceItem('fund', '住房公积金', '公积金', useFundBase: true),
];

