/// 台风播报模块的页面入口。
///
/// 对外只暴露两个页面（列表 / 详情），实现分别在同目录的
/// `typhoon_list_page.dart` 与 `typhoon_detail_page.dart`；
/// 该文件保留为统一入口，调用方无需关心内部拆分。
library;

export 'typhoon_detail_page.dart';
export 'typhoon_list_page.dart';
