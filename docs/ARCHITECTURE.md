# 架构与开发约定

本文件说明 toolbox 的分层、数据流、复用组件与扩展方式。
使用说明见 [README](../README.md)，测试组织见 [TESTING](TESTING.md)，历史取舍见 [DECISIONS](DECISIONS.md)。

## 1. 分层与依赖方向

```
lib/
├── main.dart                  入口：注册内置工具 → 恢复工具顺序 → 加载设置 → runApp
├── app.dart                   MaterialApp：主题、语言、字号、背景层
├── core/                      基础设施（不依赖任何 features）
│   ├── app_theme.dart         Material 3 主题（fidelity 配色 + 可读前景 + AppTokens 设计令牌）
│   ├── formatters.dart        金额 / 比例 / 数字 / 字节格式化（全局唯一口径）
│   ├── insurance.dart         五险一金项目定义
│   ├── tool_registry.dart     工具注册表（注册顺序 + 用户自定义顺序）
│   ├── settings/              设置单例、语言与文案查表、AI 配置与平台预设、主题色板
│   ├── storage/               SharedPreferences JSON 封装、应用存储空间、文件选择器
│   └── widgets/               跨工具复用 UI（SectionCard / StatRow / MetricTile / EmptyState /
│                              HintBanner / NumberField / CollapseCard / RateTable / AppBackdrop）
└── features/                  业务功能
    ├── shell/                 底部导航外壳 + kAppTabs（声明式导航）
    ├── overview/              工具总览与排序页
    ├── user/                  用户主目录：个性化 / AI 配置入口 / 存储空间 / 关于
    ├── profile/               个人信息（模型 + 仓库 + 基本信息 / 五险一金比例）
    └── tools/
        ├── builtin_tools.dart 内置工具注册（唯一注册点）
        └── <tool>/            单个工具，内部按 data → logic|state → ui 单向依赖
```

依赖规则（强制，`flutter analyze` 之外靠 review 把关）：

1. `core/` **不得** import `features/`（导航、工具注册因此都在 `features/` 下）。
2. `features/<tool>/ui/` 可以依赖 `logic|state|data`，反向禁止。
3. 纯算法与协议解析放在 `data` / `logic`，**不得** import `package:flutter/material.dart`
   （如 `assistant_chunking.dart`、`chess/engine/chess_core.dart`、`measure_geometry.dart`、`formatters.dart`），
   这样能被纯 Dart 单测直接覆盖。
4. 跨工具共享的能力上移到 `core/`，不在两个 feature 之间互相 import
   （例外：`user/profile_hub_page.dart` 组合 `profile/` 的页面，属同一业务域）。

## 2. 状态管理

| 场景 | 方式 | 代表 |
| --- | --- | --- |
| 全局设置 | `SettingsController.instance`（`ChangeNotifier` + `LocalStore` 持久化） | 主题、语言、字号、背景、AI 配置、用量 |
| 需跨页面存活的会话 | 全局单例 `AssistantController.instance`，页面只挂/摘监听 | 智能助手对话 |
| 单页内的交互状态 | `StatefulWidget` + `setState`；长任务用 `ChangeNotifier` 控制器 | 刷题会话、棋局、设备状态 |
| 只读数据流 | `ValueListenableBuilder` | 个人信息 `ProfileRepository.notifier` |
| 工具展示顺序 | `ToolRegistry` 静态列表 + `SharedPreferences(tool_order)` | 工具总览、排序页 |

约定：

- 控制器通过 `Listenable` 暴露状态，UI 只在 `AnimatedBuilder` / `ListenableBuilder` 里读。
- 控制器由「创建它的页面」负责 `dispose()`；若移交给下一个页面（答题页 → 报告页），必须显式传
  `ownsController`，不能两个页面都 `dispose()`。
- 全局单例不随页面 `dispose()` 销毁，监听必须在页面 `dispose()` 里摘除。
- 轮询类页面（设备状态、电池）必须有 in-flight 保护，避免请求叠加与快照乱序。

## 3. 数据存储

### 3.1 SharedPreferences（JSON，`core/storage/local_store.dart`）

| key | 内容 |
| --- | --- |
| `app_settings` | 主题、语言、字号、背景、`assistantProfiles`、`activeAssistantProfileId`、`customAssistantPlatforms`、token 用量 |
| `assistant_sessions` | `{activeId, sessions:[{id,title,updatedAt,skillId,messages,draft}]}`（`skillId` 让技能跟着对话走） |
| `assistant_skills` | 用户导入 / 新建的自定义技能 |
| `user_profile` | 个人信息（主存储，文件只是镜像） |
| `tool_order` | 工具自定义顺序 |
| `quiz_ai_analysis` | 题目 AI 解析缓存（上限 300 条，按时间淘汰） |
| 棋局记录 / 测量校准 等 | 各自 key，均带 `schemaVersion`，旧数据只补默认值 |

注意事项：

- `LocalStore` 只提供 `readMap/writeMap/remove`，写入是**整键覆盖**，读-改-写必须串行。
- 旧版单配置字段（`assistantApiKey` / `assistantBaseUrl` / `assistantModel`）只在 `load()` 里读一次用于迁移，
  迁移后**不写回**，且不迁移密钥。

### 3.2 sqflite（刷题助手）

7 张表：`banks` / `questions` / `sessions` / `session_questions` / `wrong_entries` / `favorites` / `settings`。
`quizSchemaVersion` + `migrateQuiz(db, from, to)` 逐版本升级；错题与收藏用 `(bankId, questionId)` 复合主键 +
`INSERT OR IGNORE` 保证幂等。错题、收藏、会话都带 `bankId`：题库详情页的「错题 / 收藏 / 考试」只查当前题库，
跨题库只有 `search()` 一个入口。

数据访问拆两个仓库：`quiz_repository.dart`（题库、题目、会话、错题、收藏、设置）与
`quiz_backup_repository.dart`（整库导出 / 恢复 / JSON 编码，含 `QuizBackupError`）。

### 3.3 应用存储空间（`core/storage/app_files.dart`）

```
<ApplicationDocuments>/app_storage/
├── profile/      # 个人信息.json、背景图
├── quiz/         # 题库 JSON、备份
├── assistant/    # AI 生成的文件
└── other/        # 手动添加的其他文件
```

- `AppStoreCategory` 决定目录名、文案与分组（`profile` → 个人信息，其余 → 工具输出）。
- `AppStore` 提供 `list/saveBytes/saveText/adopt/rename/delete/usedBytes`，同名文件自动加 `(2)` 后缀，
  文件名先过 `sanitizeName()`。
- 工具不直接拼路径：题库备份、AI 题库 JSON、导入归档、自定义背景图都走 `AppStore`，
  因此在「用户 → 存储空间」里一定看得到、管得了。
- 工具页的导入入口用 `pickStoredFile(context, extensions: ...)` 弹出存储空间选择器，与「手机文件」并列。
- 测试用 `AppStore.useRootForTest(dir)` 把根目录指到临时目录。
- **个人信息**：运行时数据仍在 `SharedPreferences(user_profile)`（读取快、页面多），
  `ProfileRepository.save()` 之后把同一份 JSON 后台同步成 `profile/个人信息.json`；`syncMirror()` 给老用户补写，
  删除该文件等同清空个人信息。之所以不让文件当唯一数据源：`dart:io` 的 Future 在 widget 测试的 fake-async 下
  永远不完成，页面会卡在 loading / 保存转圈（详见 [DECISIONS](DECISIONS.md)）。

## 4. 关键数据流

### 4.1 流式对话（智能助手）

```
用户发送 → AssistantController.send()
  → 组装上下文（技能提示词 + 最近 N 条消息 + 附件解析文本）
  → OpenAiCompatClient.streamChat()（SSE 增量回调）
  → partial 累积 → notifyListeners() → UI 增量渲染
  → 结束后写入该会话 messages、持久化、累计 usage
```

- 结果按 `streamingSessionId` 归属，切走会话不会串台。
- 生成中每 1.5 s 把 `partial` 写入会话 `draft`；异常退出后下次 `load()` 把草稿转成助手消息。

### 4.2 长文档题库转换

```
源文本 > 6000 字符 → splitForConversion()（按行切分 ≤4000）
  → 逐段请求 → 每段解析 JSON → questionKey() 去重 → 重排序号
  → 合并成单个题库 → 渲染为文件卡片（保存 .json / 直接导入）
```

单段失败不丢整体结果，提示失败段数；`max_tokens` 显式传入，服务端 400 时降级重试。

### 4.3 刷题答题 → 报告

```
QuizSessionController.start() → 逐题 answer() / judgeShortAnswer()
  → submit()（判分 + 落库）→ pushReplacement 跳报告页（移交控制器所有权）
  → 报告页补自评 → judgeShortAnswer() + refreshScore()
```

## 5. 复用组件与格式化（新增页面前先查这里）

`core/widgets/app_widgets.dart`

| 组件 | 用途 |
| --- | --- |
| `SectionCard` | 带标题 / 副标题 / 右侧操作的分区卡片 |
| `StatRow` | 左标签右数值行（可带副标题） |
| `MetricTile` | 统计小格：数值在上、标签在下；`compact` 小号，`labelFirst` 标签在上并左对齐 |
| `EmptyState` | 空态 / 错误态占位（图标 + 标题 + 说明 + 操作） |
| `HintBanner` | 轻提示条 |
| `NumberField` | 数字输入框（统一键盘与过滤） |
| `showToast` / `copyWithToast` | 轻提示 / 复制并提示（含 mounted 保护） |

- `core/widgets/collapse_card.dart`：`CollapseCard` 折叠卡，`RateSection` 组合它而不是复制折叠逻辑。
- `core/widgets/rate_table.dart`：五险一金比例表格。
- `core/formatters.dart`：`formatMoney`、`formatRate`、`formatNumber` / `textOf`、`formatBytes`。
- 工具内也有就近的复用层，避免跨工具互相 import：
  - `measure/meter_widgets.dart`：分贝仪与光强计共用的读数区、电平条、刻度、参考表。
  - `typhoon/typhoon_widgets.dart`：强度 / 预警徽章、错误卡、空态、图例。

## 6. 视觉系统

- **配色**：`ColorScheme.fromSeed(dynamicSchemeVariant: fidelity)` 保留用户选择的色相，
  中性色再向 seed 轻染（2%~7%）避免发冷；`onPrimary/onSecondary/onTertiary` 由 `AppTheme.readableOn`
  按对比度自动取深/浅（WCAG AA）。
- **设计令牌**：圆角与间距统一取自 `AppTokens`；卡片 = 18 圆角 + 发丝描边 + 低透明度投影；
  导航栏半透明 + 顶部发丝线 + 胶囊指示器。
- **背景**：`AppBackdrop` 是一个 Stack（底色渐变 → 两团径向柔光 → 内容），
  四种 `BackgroundKind` 都在这一层收口；`HomeShell` 的 Scaffold 背景保持透明。
- **兜底**：`test/unit/theme_test.dart` 断言 24 套主题色的对比度与深浅层次；
  `test/golden/preview_golden_test.dart` 渲染关键页 PNG 供人工比对。

## 7. 工具模块速查

| 工具 | 关键文件 | 要点 |
| --- | --- | --- |
| 工资计算器 | `salary/salary_page.dart`、`city_rules.dart` | 个税累计预扣；城市规则表驱动 |
| 手机状态 | `device_status/device_status_page.dart`、`battery_detail_page.dart`、`device_status_channel.dart` | 平台通道 + 轮询；缺数据时标注来源，不提示 root |
| 中国象棋 | `chess/engine/chess_core.dart`、`chess/rules/*`、`chess/ai/*`、`chess_page.dart`、`board_editor_page.dart`、`game_controller.dart` | 90 格一维内核 + `RulesEngine` 两套实现；揭棋暗子概率 AI；走子动画 480 ms |
| 刷题助手 | `quiz/data/*`、`quiz/logic/*`、`quiz/state/quiz_session_controller.dart`、`quiz/ui/*` | 以题库为中心；判分与错题规则在 logic；AI 解析带缓存 |
| 智能助手 | `assistant/data/*`、`assistant/logic/*`、`assistant/ui/*` | 全局单例控制器 + 会话模型 + 分段算法；技能在 data 层 |
| 每日新闻 | `news/news_api.dart`、`daily_news_page.dart` | 60sAPI，解析失败给出可读错误 |
| 测量工具 | `measure/measure_geometry.dart`、`ruler_view.dart`、`protractor_view.dart`、`decibel_meter.dart`、`light_meter.dart`、`meter_widgets.dart` | 采集层抽接口（`AudioCapture` / `LightSensor`）便于注入假实现；几何换算纯函数 |
| 台风播报 | `typhoon/typhoon_api.dart`、`typhoon_geo.dart`、`typhoon_geo_data.dart`、`typhoon_map.dart`、`typhoon_list_page.dart`、`typhoon_detail_page.dart` | 离线地理数据由仓库外的 `../tools/geo/gen_typhoon_geo.py` 生成；列表与详情分文件，`typhoon_page.dart` 只做导出 |
| 图片水印 | `watermark/watermark_engine.dart`、`watermark_page.dart` | 落点计算纯函数（可单测）；渲染靠 `ui.Image` |
| 二维码生成 | `qrcode/qr_page.dart` | 超长需自行触发一次编码才能捕获 `InputTooLongException` |

## 8. 扩展点

| 要做什么 | 改哪里 |
| --- | --- |
| 新增工具 | `features/tools/<tool>/` 建页面 + `features/tools/builtin_tools.dart` 注册 |
| 新增底部导航 | `features/shell/tab_registry.dart` 的 `kAppTabs` |
| 新增城市社保规则 | `features/tools/salary/city_rules.dart` 的 `CityRules.all` |
| 新增险种 | `core/insurance.dart` 的 `kInsuranceItems` |
| 新增助手技能 | 预置在 `features/tools/assistant/data/skills.dart`；自定义在「AI 配置 → 技能管理」 |
| 新增 AI 平台预设 | `core/settings/assistant_platforms.dart` |
| 新增存储分类 | `core/storage/app_files.dart` 的 `AppStoreCategory` |
| 新增文案 | 工具页 `core/settings/tool_texts.dart`（zh_TW + en 两层）；外壳 `core/settings/app_l10n.dart` |
| 个人信息新增字段 | `UserProfile.putNumber/putText(...)` 写入，Map 存储带 `schemaVersion`，旧数据无需迁移 |

新增工具的最小注册样例：

```dart
ToolDefinition(
  id: 'bmi',
  name: 'BMI 计算器',
  description: '身高体重指数与区间提示',
  icon: Icons.monitor_weight_outlined,
  category: '健康',                       // 总览页按分类分组
  accent: const Color(0xFF34C77B),
  keywords: <String>['体重', '健康'],
  builder: (_) => const BmiPage(),
),
```

## 9. 编码约定

- 注释只写「为什么」，不写「做了什么」；公共 API 写 `///`。
- 单文件超过 ~600 行或出现第二个职责时拆分（参考 `assistant/ui/` 的 5 个文件、`typhoon/` 的列表/详情拆分）。
- 不写死密钥、路径、语言文案；文案一律 `tr()/trf()`。
- `async` 之后使用 `BuildContext` 前必须 `mounted` / `context.mounted` 检查。
- 新增依赖前先确认「`core/` 能放就放 `core/`」，工具之间不互相 import。
- 改完跑 `flutter analyze`（要求零 issue）与 `flutter test`（要求全绿）再提交。
