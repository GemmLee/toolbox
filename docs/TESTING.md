# 测试指南

`flutter test` 当前 285 项、27 个测试文件。测试按「测什么」分层，而不是按源码目录镜像——
一个工具的判分逻辑和它的页面交互分开放，这样单测不需要 `pumpWidget`，widget 测试也不必重复跑算法。

## 1. 目录结构

```
test/
├── unit/                       纯逻辑与数据层，不渲染页面
│   ├── app_store_test.dart     存储空间：分类落盘、去重命名、重命名/删除、adopt
│   ├── profile_store_test.dart 个人信息镜像：保存写出 个人信息.json、清空删文件、老数据补写
│   ├── tool_order_test.dart    工具排序：持久化、重置、未知 id 容错、排序页交互
│   ├── theme_test.dart         24 套主题色的 WCAG 对比度与深浅层次
│   ├── salary_calculator_test.dart、watermark_test.dart、skill_export_test.dart
│   ├── chess/
│   │   ├── chess_rules_test.dart   规则引擎 + 揭棋明士 + 走法差分
│   │   └── chess_ai_test.dart      AI 搜索与耗时预算
│   └── tools/                  各工具的算法/解析：measure、light、quiz、assistant、typhoon、news、device_status
├── widget/                     页面渲染与交互
│   ├── app_smoke_test.dart     多尺寸下各页可渲染、主题/语言/字号即时生效
│   ├── quiz_test.dart          刷题助手：首页 → 题库详情五分页 → 练习/答题卡 → 报告
│   ├── chess_test.dart         对局页点击走子、摆子模式、揭棋吃子栏
│   ├── assistant_test.dart、assistant_platform_test.dart、user_page_test.dart、
│   │   qr_page_test.dart、device_status_page_test.dart、typhoon_map_test.dart、app_storage_page_test.dart
├── golden/
│   ├── preview_golden_test.dart  总览/用户/深色/主题色/刷题五张关键页截图
│   └── preview/*.png             基线图（人工比对用）
└── support/
    └── test_env.dart          共享夹具：mock 偏好 + 重置设置单例 + 固定中文
```

## 2. 共享夹具（`test/support/test_env.dart`）

每个用例开工前的三件事原先散抄在十几个文件里，现在只有一处：

```dart
installCleanEnv();            // 注册 setUp/tearDown：mock 空偏好 + resetForTest + 固定简体中文
installCleanEnv(prefs: {...}); // 需要预置偏好时
mockPrefs();                  // 只换 mock 偏好（用例自己要控制后续步骤）
await useChineseUi();         // 只重置设置单例并固定中文
await restoreSystemLanguage();// tearDown 收尾：语言跟随系统
```

- 需要额外准备（临时目录、开数据库）的用例，用 `mockPrefs()` + `useChineseUi()` 自行拼装，
  不要复制 `setUp` 里的三行。
- `installCleanEnv()` 必须在 `main()` 或 `group()` 体内调用，**不能**塞进 `setUp(() { ... })` 里
  （那会在运行时注册钩子）。

## 3. 硬性约定

1. **先初始化 binding**：`setUp` 里就要碰 `SharedPreferences` 时，`main()` 开头必须有
   `TestWidgetsFlutterBinding.ensureInitialized()`。`testWidgets` 会自动初始化，纯 `test` 不会。
2. **sqflite 用 `databaseFactoryFfiNoIsolate`**：默认 ffi 工厂在独立 isolate 里跑，
   widget 测试的 fake-async 下永不返回，必须换成 no-isolate 版本。
3. **语言固定中文**：测试宿主 locale 是 en，不断言中文文案前必须 `useChineseUi()`，
   否则 `find.text('工资与基数')` 全部落空。
4. **单例要复位**：`SettingsController` / `ToolRegistry` / `QuizServices` 都是全局的，
   `setUp` 用 `resetForTest()`，`tearDown` 摘掉注入的假实现（如 `QuizServices.reset()`）。
5. **修 bug 必须补一条在修复前会失败的用例**，并把「为什么会这样」写进 `reason:`。
6. **数值断言带 reason**：几何 / 投影 / 校准类断言写成
   `expect(actual, closeTo(expected, 0.5), reason: '捏合以中心为锚点，偏差应小于半格')`，
   失败时能直接定位到语义而不是一串浮点数。

## 4. 金图（golden）

```bash
flutter test test/golden/preview_golden_test.dart                 # 与基线比对
flutter test test/golden/preview_golden_test.dart --update-goldens # 改完 UI 后重建基线
```

- 基图在 `test/golden/preview/`，覆盖总览浅色 / 用户页 / 总览深色 / 换主题色 / 刷题首页。
- 中文渲染需要 `FontLoader` 注入系统字体；当前字体路径写死 `C:/Windows/Fonts/NotoSansSC-VF.ttf`，
  **非 Windows 机器需要改路径或跳过金图**。
- 改动视觉系统（配色、圆角、间距）后先看 PNG 再决定是否 `--update-goldens`，不要把「压坏了」的图当基线提交。

## 5. 踩坑速查（都踩过）

| 现象 | 原因与对策 |
| --- | --- |
| 页面一直转圈 / `pumpAndSettle` 超时 | widget 测试的 fake-async 下 `dart:io` 的 Future 永不完成。页面要么接受可注入的 loader，要么把文件当镜像而非数据源 |
| `await controller.stop()` 卡住不返回 | 内部 `subscription.cancel()` 在 fake-async 下不会完成；用 `tester.runAsync(...)` 走真实事件循环 |
| `Null check operator used on a null value`（`SharedPreferences.getInstance`） | 重复的 `setUp` 把 mock 重置到半初始化状态；保证每个文件只有一处 `installCleanEnv()`/`mockPrefs()` |
| `find.byType(FilledButton)` 找不到 | `FilledButton.icon` 返回私有子类，用 `byWidgetPredicate((w) => w is FilledButton)` |
| `find.text('3.50')` 找不到 | 读数在 `Text.rich` 里（`Text.data` 为 null），拆成独立 `Text` 既好断言也方便局部样式 |
| 列表后半段断言失败 | 默认测试视口 800×600 装不下，先放大 `tester.view.physicalSize` 或 `ensureVisible` |
| 复制后 SnackBar 不出现 | 测试环境没有剪贴板实现，`Clipboard.setData` 抛 `MissingPluginException`；用 `setMockMethodCallHandler(SystemChannels.platform, ...)` 记录调用 |
| 打开刷题助手渲染成红屏 | 测试环境没有 sqflite 插件，属预期，不代表布局溢出 |

## 6. 覆盖率边界

- 平台通道（设备状态、电池、环境光、麦克风）在测试里一律注入假实现，真实通道只在真机验证。
- 网络请求走 `http.Client` 注入，测试用 `MockClient` 构造响应 / 异常 / 分段流，不联网。
- 台风地图、棋盘、量角器这类自绘 UI 只断言关键几何与交互（点击坐标换算），不做像素级比对，
  像素级交给金图。
