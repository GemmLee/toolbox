import 'package:flutter/material.dart';

import 'app.dart';
import 'core/platform/file_import_bridge.dart';
import 'core/settings/settings_controller.dart';
import 'core/storage/cache_auto_clean.dart';
import 'core/tool_registry.dart';
import 'features/tools/builtin_tools.dart';
import 'features/tools/device_status/battery_history.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBuiltinTools();
  await ToolRegistry.loadOrder();
  await ToolRegistry.loadFolded();
  await SettingsController.instance.load();
  // 第三方 App 打开 / 分享的文件在 Dart 引擎启动前就已落到私有目录；
  // 这里先归档，HomeShell 首帧后会自动打开阅读器。
  try {
    await FileImportBridge.instance.initialize();
  } catch (_) {
    // 原生通道不可用时不影响正常启动。
  }
  runApp(const ToolboxApp());
  // 系统运行时缓存每 7 天自动清一次，只清可再生项；失败不影响启动。
  CacheAutoClean.runIfDue().catchError((Object _) => 0);
  // 电量曲线长期采样：进程存活期间每 15 分钟一点，打开工具 / 回到前台再补点。
  BatteryHistory.startAutoSample();
}
