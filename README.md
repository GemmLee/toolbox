# XMtools 工具箱

Flutter 个人工具箱，仅 Android arm64（包名 `com.toolbox.app`）。除「智能助手」按需调用用户自配的大模型接口外，数据全部留在本机。

**下载**：[GitHub Releases](https://github.com/GemmLee/toolbox/releases) · [当前版 1.0.7 APK](https://github.com/GemmLee/toolbox/releases/download/v1.0.7/XMtools-1.0.7.apk)

文档：[架构与开发约定](docs/ARCHITECTURE.md) · [测试指南](docs/TESTING.md) · [设计决策与踩坑](docs/DECISIONS.md)

### 发布新版本

在 GitHub 创建 Release，**tag 用纯版本号**（如 `1.0.7`，带 `v` 前缀也可识别），并把 arm64 安装包作为 asset 上传、命名为 `XMtools-<版本号>.apk`。应用内「检测更新」读取最新 Release 的 tag 与本地版本比较，下载按钮直接用该 asset 直链；「下载站」也走同一 Release 数据。发布页入口为 [Releases](https://github.com/GemmLee/toolbox/releases)，直链中的版本号需与 asset 文件名一致，否则请从发布页下载。

## 功能

| 工具 | 说明 |
| --- | --- |
| 工资计算器 | 五险一金 + 个税累计预扣，含房贷方案与统计 |
| 手机状态监控 | 电量 / 存储 / 内存等本机状态；电池详情含功率、电流、容量与寿命估算 |
| 中国象棋 | 正常 + 揭棋；双人 / 内置 AI；摆子开局、FEN 导入导出、悔棋、对局记录 |
| 刷题助手 | 题库隔离的题目 / 错题 / 收藏 / 练习考试 / 统计；JSON 与 Excel 导入、AI 生成题库、断点续答、备份恢复；仅全局搜索跨题库 |
| 智能助手 | OpenAI 兼容接口流式聊天；多对话侧栏、技能系统、附件解析、长文档分段、题库 JSON 一键入库 |
| 每日新闻 | 60sAPI 简报 + AI 热点速递，下拉刷新与 24h 缓存 |
| 测量工具 | 尺子、量角器、分贝仪、光强计；尺子与量角器支持全屏横屏 |
| 台风播报 | 浙江省水利厅台风路径，自绘离线底图、登陆预报与时间线，双指缩放 |
| 图片水印 | 平铺 / 居中 / 角落版式，支持用户导入字体、自定义字段与拖动排序、原图分辨率导出 |
| 二维码生成 | 文本 / 链接实时生成，容错等级可选，存图到存储空间 |

## 快速开始

```bash
flutter pub get
flutter test        # 903 项
flutter analyze     # 零 issue
flutter build apk --release --target-platform android-arm64
```

产物按约定重命名为 `XMtools-<版本号>.apk`（仅 arm64-v8a）。

环境：Flutter 3.24.3 / Dart 3.5.3，JDK 21（`android/gradle.properties` 固定 `org.gradle.java.home`，换机器需改路径）。国内镜像：`PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`。

> `vendor/record_android/` 是 record 插件 1.5.2 的本地副本（`dependency_overrides` 引用），补丁去掉 buildscript classpath 并固定 `compileSdk 34`，以兼容 AGP 8.3 / Gradle 8.5 / Flutter 3.24。升级后可改回 pub.dev 版本。

## 目录结构

```
lib/
├── main.dart / app.dart      入口：加载设置、注册工具后启动
├── core/                     基础设施，不依赖 features
│   ├── settings/             设置、多语言文案、AI 配置与预设、主题色板
│   ├── storage/              SharedPreferences、应用存储空间、文件选择
│   ├── widgets/              通用组件（卡片/空态/统计格/折叠卡）
│   └── tool_registry.dart    工具注册表
└── features/
    ├── shell/                底部导航
    ├── overview/ user/ profile/
    └── tools/
        ├── builtin_tools.dart  内置工具注册（唯一入口）
        └── <tool>/             每个工具 data → logic|state → ui 单向依赖
```

完整目录与依赖规则见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 数据与隐私

- **设置 / 对局记录 / 助手配置 / 技能 / 个人信息**：`SharedPreferences`（JSON），见 `core/storage/local_store.dart`。
- **刷题**：`sqflite` 独立库，7 张表带 schema 迁移；错题与收藏以 `(bankId, questionId)` 复合主键去重。题库 JSON 格式见 `../quiz-json-spec/题库JSON格式规范.md`。
- **象棋**：FEN 持久化（揭棋用 `x/X` 表示暗子），AI 搜索在独立 Isolate。
- **存储空间**：`<ApplicationDocuments>/app_storage/<分类>/`，可在「用户 → 存储空间」预览、导出、重命名、删除。
- **密钥**：不内置任何 API Key，用户填写的 Key 只存本机。

## 已知限制

- 助手功能需在「用户 → AI 配置」自填 API Key；余额与用量以平台返回为准。
- 普通对话走同步流式接口，进程被杀只能保住已收到内容；GLM Batch 类异步批处理未接入。
- 超长题库自动分段，个别段失败时保留其余结果并提示失败段数。
- 设备状态 / 电池 / 存储依赖 Android 原生通道，桌面 / Web 与部分模拟器不返回数据。
- 尺子按名义 dpi 换算（约 4% 误差），请用银行卡短边校准；分贝仪未经声学校准，仅适合相对比较。
- 文案在 `core/settings/tool_texts.dart` 手工维护，新增需同时补繁中与英文。
- 台风数据来自浙江省水利厅公开接口，接口变更或海外网络下可能不可用；地图为离线自绘示意图。
- 量角器附近手势被拖动接管，切页需离开半圆区域。
