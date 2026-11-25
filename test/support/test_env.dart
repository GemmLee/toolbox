/// 测试共用夹具。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/core/settings/settings_controller.dart';

/// 注册一组「干净环境」的 setUp / tearDown。
///
/// 这几件事原先在十几个测试文件里各抄一遍，且时常漏掉其中一项：
/// 1. 给 `SharedPreferences` 一份空的 mock 内存库；
/// 2. 重置 `SettingsController` 单例，避免上一个用例改过的主题/语言漏过来；
/// 3. 把界面语言固定成简体中文——测试宿主 locale 是 en，
///    不固定就断言不到中文文案。
///
/// 调用前需要 `TestWidgetsFlutterBinding.ensureInitialized()`（widget 用例已自动初始化）。
/// 若某个文件还要在 setUp 里做别的事（建临时目录、开数据库），
/// 直接用 [mockPrefs] + [useChineseUi] + [restoreSystemLanguage] 自行拼装。
void installCleanEnv({
  Map<String, Object> prefs = const <String, Object>{},
  bool resetSettings = true,
}) {
  setUp(() async {
    SharedPreferences.setMockInitialValues(prefs);
    if (resetSettings) SettingsController.instance.resetForTest();
    await SettingsController.instance.setLanguage(AppLanguage.simplifiedChinese);
  });
  tearDown(restoreSystemLanguage);
}

/// 只把 `SharedPreferences` 换成一个空的 mock 内存库。
void mockPrefs([Map<String, Object> initial = const <String, Object>{}]) {
  SharedPreferences.setMockInitialValues(initial);
}

/// 重置设置单例并把界面语言固定为简体中文。
Future<void> useChineseUi() async {
  SettingsController.instance.resetForTest();
  await SettingsController.instance.setLanguage(AppLanguage.simplifiedChinese);
}

/// 把语言恢复成「跟随系统」，避免污染同文件内的后续用例。
Future<void> restoreSystemLanguage() =>
    SettingsController.instance.setLanguage(AppLanguage.system);
