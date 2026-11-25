# 设计决策与踩坑记录

这里只留**以后还会被问到「为什么这么做」**的结论，不记流水账。
已修完的一次性缺陷不再列出（代码里已体现），改造轮次见文末历史表。

## 1. 决策清单

### D1 全本地，不引入账号与云同步

所有数据留在本机（SharedPreferences / sqflite / 应用存储空间），唯一的外网出口是用户自配的大模型接口、
每日新闻与台风路径这三个公开 API。

**代价**：换机要手动搬备份；没有多人协作。
**收益**：没有登录态、没有服务端成本、没有隐私面，测试也不依赖网络桩。

### D2 `core/` 与 `features/` 的单向依赖

`core/` 是基础设施，禁止 import `features/`。因此底部导航（`features/shell/tab_registry.dart`）
和内置工具注册（`features/tools/builtin_tools.dart`）都放在 `features/` 下，
`main.dart` 只做「注册工具 → 恢复顺序 → 加载设置 → runApp」。
跨工具复用的能力上移 `core/`，工具之间不互相 import。

### D3 多语言双轨：外壳用字段表，工具页用「中文即 key」

- 外壳与用户目录：`core/settings/app_l10n.dart`，字段齐全、编译期可查。
- 工具页：`core/settings/tool_texts.dart`，`tr('工资与基数')` / `trf('共 {n} 个工具', {'n': 3})`，
  表结构 `{zh_TW: {...}, en: {...}}`，缺项回退简体而不是报错。

**为什么两套**：工具页文案量大（约 690 条）、增删频繁，走字段表每次要改三处；
源中文即 key 让「写页面」和「补翻译」解耦，代价是缺 key 只会在运行时回退（因此加了一次全量 key 审计）。

### D4 个人信息：SharedPreferences 是数据源，文件只是镜像

`ProfileRepository.save()` 之后把同一份 JSON 后台同步成 `app_storage/profile/个人信息.json`，
`syncMirror()` 给老用户补写；删除文件等同清空。

**为什么不让文件当唯一数据源**：`dart:io` 的 Future 在 widget 测试的 fake-async 下永远不完成，
页面会卡在 loading / 保存转圈（试过一次，冒烟测试直接 `pumpAndSettle timed out`）。
文件镜像既满足「用户能在存储空间里看到、导出」，也保住可测性。

### D5 工具产出统一进「应用存储空间」

以前题库备份写到文档根目录、AI 题库 JSON 弹系统另存为、背景图散落在根目录。
现在一律走 `AppStore`（`app_storage/<分类>/`），在「用户 → 存储空间」可预览、导出、重命名、删除，
工具页的导入入口也用 `pickStoredFile()` 直接读这里。

### D6 刷题助手以题库为中心

`wrong_entries` / `favorites` / `sessions` 全部带 `bankId`，题库详情页分成
「题目 / 错题 / 收藏 / 考试记录 / 统计」五页；首页只列题库卡片，计数在 `listBanks()` 里聚合。
唯一的跨题库入口是「全局搜索」——避免「学习数据」这类聚合页在题库变多后失去意义。

### D7 助手会话是全局单例，且带草稿

`AssistantController.instance` 不随页面销毁，生成过程不中断；每段对话独立持有消息，
流式结果按 `streamingSessionId` 写回发起它的对话，切走不串台；
生成中每 1.5 s 把已收到的内容写进会话 `draft`，进程被杀后下次 `load()` 把草稿转成消息。

### D8 象棋：一维内核 + 规则抽象 + 概率 AI

- `CoreBoard`：90 格一维数组 + 编码棋子，`legalMoves` 过滤送将与照面，兼作 AI 搜索底座。
- `RulesEngine` 抽象出正常 / 揭棋两套实现；揭棋在 `JieqiState` 上叠加「暗子按格位棋种走子、走后翻开」
  与「明士 / 明象解除九宫 / 河界限制（`freeAE`）」，试走回退时必须还原被吃子的 `freeAE`。
- 揭棋 AI 对暗子按剩余暗子池概率做期望展开，再与 Alpha-Beta 剪枝结合；搜索跑在独立 Isolate。
- 界面上电脑吃掉的暗子只显示「暗」，玩家吃掉的照实显示（`capturedHidden` + `capturesBy`）。

### D9 采集与网络一律抽接口

`AudioCapture`（record 插件）、`LightSensor`（环境光通道）、`http.Client` 都是可注入接口。
插件在测试环境不存在，直接依赖会抛 `MissingPluginException`；抽象后单测注入假实现即可覆盖算法。

### D10 `record` 插件用 vendored 副本

`vendor/record_android/`（1.5.2，经 `dependency_overrides`）去掉了自带 buildscript classpath、
把 `compileSdk` 固定 34，因为上游要求 AGP 8.12+，本项目是 AGP 8.3 / Gradle 8.5 / Flutter 3.24.3。
升级后可删除 vendor 改回 pub.dev。

### D11 测量精度只承诺相对值

- 尺子：默认按 160dpi 名义值 63 px/cm（主流机型误差约 4%），可用银行卡短边 53.98 mm 校准；
  绘制与读长共用同一份 `pxPerCm`，误差不累积，因此不做水平压缩。
- 分贝仪：dB SPL 绝对量级取决于麦克风灵敏度，App 内无法确定，统一标「≈ 估算值」。
- 光强计：依赖设备环境光传感器，缺传感器时明确提示而不是显示 0。

### D12 台风地图离线自绘

几何数据由仓库外的 `../tools/geo/gen_typhoon_geo.py` 从阿里云 DataV.GeoAtlas（中国国界/省界）与
Natural Earth 1:50m（周边国家）生成并内置，导出 `typhoon_geo_data.dart`。
地图是**示意图**：台湾、海南与大陆同属中国并单独上色，海域只写文字，
不绘制任何争议性国界或南海断续线；省界为完整省级行政区界线虚线，不标省名。

### D13 题目 AI 解析带缓存

缓存键 `bankId/questionId/contentHash`（`SharedPreferences: quiz_ai_analysis`，上限 300 条按时间淘汰）：
同一道题只花一次 token；题目重新导入导致内容指纹变化时不会命中旧解析。

### D14 控制器所有权显式移交

答题页用 `pushReplacement` 跳报告页时把 `QuizSessionController` 的所有权交给报告页
（`ownsController`）。否则答题页 `dispose()` 会先销毁控制器，报告页的监听静默失效（自评后分数不刷新）。

## 2. 工程坑（与设计无关，但会反复遇到）

| 坑 | 结论 |
| --- | --- |
| `qr_flutter` 的 `QrValidator.isValid` 不真正展开数据 | 超长时仍返回 true，真正抛 `InputTooLongException` 的是 painter 里的 `QrImage`；要预判必须自己 `QrImage(QrCode.fromData(...))` 触发一次编码 |
| `SharedPreferences` mock 有缓存 | 同一文件内不要依赖「第二次 `setMockInitialValues`」来重置状态，用 `resetForTest()` + 夹具 |
| 金图中文全是方块 | 需要 `FontLoader` 注入系统字体，且路径与平台绑定（见 [TESTING](TESTING.md)） |
| `tool_texts.dart` 的 key 是字符串字面量 | 改动文案时同步改 key 与两层翻译；有 `tr()` 字面量被跨行拼接时审计会误报缺项 |
| `main.dart` 之外没有 `runApp` 入口 | 冒烟测试直接 `pumpWidget(const ToolboxApp())`，前提是先 `registerBuiltinTools()` |

## 3. 历史改造记录

| 轮次 | 时间 | 主题 | 结果 |
| --- | --- | --- | --- |
| 1 | 2026-10-31 | 全量代码审查 | 修 5 处真实缺陷、清约 20 处死代码、收敛 9 类重复实现 |
| 2 | 2026-10-31 | 存储空间 / 技能管理 / 刷题以题库为中心 | 文件出口统一到 `AppStore`；技能管理收进 AI 配置 |
| 3 | 2026-10-31 | 个人信息落盘、练习设置、工具顺序 | 文件镜像 + 顺序持久化 |
| 4 | 2026-10-31 | 视觉系统升级 | fidelity 配色、`AppBackdrop`、`AppTokens`、金图 |
| 5 | 2026-10-31 | 题目 AI 解析 | 流式解析 + 指纹缓存 |
| 6 | 2026-11-01 | 测量工具 + 二维码 | 采集层抽象、手势隔离、全屏横屏 |
| 7 | 2026-11-04 | 去重与拆分、测试重组、文档重构 | 分贝/光强共用组件、台风列表/详情拆分、刷题备份仓库独立；测试 36 → 27 个文件、抽出共享夹具；文档拆为 README / ARCHITECTURE / TESTING / DECISIONS |
