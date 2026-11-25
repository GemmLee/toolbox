# 工具箱（XMtools / toolbox）

个人全本地工具箱：Flutter + 纯 Android arm64（包名 `com.toolbox.app`）。
除「智能助手」按需调用用户自配的大模型接口外，其余数据全部留在本机（SharedPreferences + sqflite + 应用存储空间），不依赖任何云服务。

**文档索引**：[架构与开发约定](docs/ARCHITECTURE.md) · [测试指南](docs/TESTING.md) · [设计决策与踩坑](docs/DECISIONS.md)

## 功能一览

| 工具 | 分类 | 说明 |
| --- | --- | --- |
| 工资计算器 | 财务 | 五险一金 + 个税累计预扣，城市规则可扩展 |
| 手机状态监控 | 系统 | 电量 / 存储 / 内存等本机状态；电池详情含功率、电流、容量与寿命估算，系统接口缺数据时改用实测滚动均值或按电量推算，并明确标注来源 |
| 中国象棋 | 游戏 | 正常 + 揭棋；双人 / 内置 AI（新手·普通·大师）；摆子开局、FEN 导入导出、悔棋、对局记录、走子动画 |
| 刷题助手 | 学习 | 以题库为中心：题目、错题、收藏、练习/考试记录与统计按题库隔离；JSON 导入、AI 导入（Word/Excel/文本 → 题库）、练习与考试、判分、断点续答、备份恢复；只有「全局搜索」跨题库 |
| 智能助手 | 效率 | OpenAI 兼容接口流式聊天；多对话 + 可折叠侧栏，离开页面生成不中断；技能系统、附件解析（docx/xlsx/txt）、长文档分段转换；题库 JSON 以文件卡片呈现，可存盘或一键入库；多套 AI 配置与自定义平台 |
| 每日新闻 | 资讯 | 60sAPI 当日简报（15 条），含日期 / 农历 / 星期 / 寄语，支持下拉刷新 |
| 测量工具 | 测量 | 尺子（银行卡短边校准、A/B 标记）、量角器（0.5° 吸附）、分贝仪（PCM 实时估算）、光强计（环境光传感器）；尺子与量角器支持全屏横屏测量 |
| 台风播报 | 天气 | 浙江省水利厅台风路径；自绘沿海底图（离线真实地理数据）与分级着色的路径图、登陆预报、时间线；支持双指缩放与平移 |
| 图片水印 | 图像 | 平铺 / 居中 / 角落三种版式，大小、密度、斜率、透明度、颜色与内置艺术字可调，原图分辨率导出 PNG |
| 二维码生成 | 效率 | 文本或链接实时生成二维码，L/M/Q/H 容错，字符与字节计数、超长提示，可存图到存储空间 |

## 快速开始

```bash
flutter pub get
flutter test        # 285 项
flutter analyze     # 零 issue
flutter build apk --release --target-platform android-arm64
```

产物：`build/app/outputs/flutter-apk/app-release.apk`（仅 arm64-v8a）。

环境：Flutter 3.24.3 / Dart 3.5.3，JDK 21（`android/gradle.properties` 固定了 `org.gradle.java.home`，换机器需改成对应的 JDK 21 路径——Flutter 3.24 的 Gradle 插件无法解析 JDK 25）。
国内镜像：`PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`。

> **vendor 说明**：`vendor/record_android/` 是 record 插件 1.5.2 的本地副本（经 `dependency_overrides` 引用）。
> 上游 gradle 配置要求 AGP 8.12+ 与 `flutter.compileSdkVersion` 扩展，与本项目（AGP 8.3.0 / Gradle 8.5 / Flutter 3.24.3）不兼容；
> 补丁内容：去掉自带 buildscript classpath、`compileSdk` 固定 34。升级 Flutter / AGP 后可删掉 vendor 改回 pub.dev 版本。

## 目录结构（骨架）

```
lib/
├── main.dart / app.dart      入口：加载设置、注册工具后启动；MaterialApp 跟随主题/语言
├── core/                     基础设施，不依赖任何 features
│   ├── settings/             设置单例、语言与文案查表、AI 配置与平台预设、主题色板
│   ├── storage/              SharedPreferences 封装、应用存储空间、文件选择器
│   ├── widgets/              跨工具复用组件（卡片/空态/统计小格/折叠卡/背景层）
│   └── tool_registry.dart    工具注册表（注册顺序 + 用户自定义顺序）
└── features/
    ├── shell/                底部导航外壳与 kAppTabs 声明式导航
    ├── overview/ user/ profile/
    └── tools/
        ├── builtin_tools.dart  内置工具注册（唯一入口）
        └── <tool>/             每个工具自成一块，内部按 data → logic|state → ui 单向依赖
```

完整目录、依赖规则与各工具文件职责见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 导航结构

```
底部导航
├── 工具总览 → 工具卡片（搜索 + 右上角「调整顺序」，顺序可拖动并持久化）
└── 用户
    ├── 个人信息（基本信息 / 五险一金比例）
    ├── 个性化（外观模式 / 主题色 24 色 / 字体大小 / 语言）
    ├── AI 配置（多套配置、平台预设与自定义平台、连接测试与余额查询、用量、技能管理）
    └── 存储空间（个人信息 / 工具输出：题库文件与备份、AI 生成文件、其他）
```

## 数据与隐私

- **设置 / 对局记录 / 助手配置 / 技能 / 个人信息**：`SharedPreferences`（JSON），见 `core/storage/local_store.dart`。
- **刷题**：`sqflite` 独立数据库，7 张表（`banks` / `questions` / `sessions` / `session_questions` / `wrong_entries` / `favorites` / `settings`），带 `schemaVersion` 迁移；错题与收藏以 `(bankId, questionId)` 复合主键 + `INSERT OR IGNORE` 幂等去重。题库 JSON 格式见 `../quiz-json-spec/题库JSON格式规范.md`。
- **象棋**：局面用 FEN 持久化（揭棋 FEN 用 `x/X` 表示暗子），AI 搜索在独立 Isolate 运行。
- **存储空间**：`<ApplicationDocuments>/app_storage/<分类>/`，工具产出（题库备份、AI 生成的题库 JSON、导入归档、自定义背景图）统一写进这里，可在「用户 → 存储空间」预览、导出、重命名、删除；个人信息另有一份 `个人信息.json` 镜像。
- **密钥**：仓库不内置任何 API Key，用户填写的 Key 只存本机，迁移旧配置时会丢弃已存密钥。

## 已知限制

- 助手相关功能必须在「用户 → AI 配置」里自填 API Key；余额与用量以平台接口返回为准。
- 普通对话走同步流式接口：进程被杀只能保住已收到的内容（草稿机制），无法在服务端续跑；GLM Batch 这类小时级异步批处理尚未接入。
- 超长题库依赖自动分段，个别分段失败时保留其余结果并提示失败段数，需人工补转换。
- 设备状态、电池、存储依赖 Android 原生通道，桌面 / Web 与部分模拟器上不返回数据。
- 尺子默认按 160dpi 名义换算（主流机型误差约 4%），精确测量前请用银行卡短边校准；分贝仪是未经声学校准的估算值，只适合相对比较；光强计依赖设备的环境光传感器。
- 工具页文案在 `core/settings/tool_texts.dart` 手工维护，新增文案需同时补 `zh_TW` 与 `en` 两层（缺项回退简体而非报错）。
- 台风数据来自浙江省水利厅（公开免鉴权接口），接口变更或海外网络下可能不可用；地图为 **离线自绘示意图**（非精确地图），不绘制任何争议性国界。
- 水印内置字体为 OFL 1.1 授权（见 `assets/fonts/OFL-LICENSES.txt`）；量角器附近的手势被拖动接管，切页需离开半圆区域。
