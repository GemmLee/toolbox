import 'settings_controller.dart';
import 'app_version.dart';

/// 轻量多语言：覆盖外壳（导航/标题）与「用户」目录及其子页。
///
/// 扩展方式：新页面需要多语言时在此补充字段并同步三个实例；
/// 工具页面暂维持中文。
class AppL10n {
  static AppL10n of() =>
      switch (SettingsController.instance.effectiveLanguage) {
        AppLanguage.traditionalChinese => _zhHant,
        AppLanguage.english => _en,
        _ => _zh,
      };

  static final AppL10n _zh = AppL10n._(
    appTitle: 'XMtools',
    tabOverview: '工具总览',
    tabUser: '用户',
    aboutTitle: '关于XMtools',
    aboutBody:
        'XMtools 把常用小工具集中在一处：刷题与搜题、文字阅读器、文字识别、证件照、设备状态等都能在首页直接打开。数据主要保存在本机，AI 与联网类功能需要网络。',
    aboutToolHint:
        '新增工具：在 lib/features/tools 下新建页面，并在 builtin_tools.dart 注册一行即可。',
    aboutVersion: '版本 $kAppVersion',
    ok: '知道了',
    profileSection: '个人信息',
    profileSubtitle: '城市、工资与五险一金比例',
    basicInfo: '基本信息',
    basicInfoSubtitle: '所在城市与工资基数',
    insuranceRates: '五险一金比例',
    insuranceRatesSubtitle: '留空时计算使用城市默认值',
    filledNone: '尚未填写',
    filledCount: (n) => '已填写 $n 项 · 数据仅保存在本机',
    appearanceSection: '个性化',
    appearanceSubtitle: '模式、主题色、语言与字号',
    appearanceMode: '外观模式',
    modeLight: '亮色',
    modeDark: '暗色',
    modeSystem: '跟随系统',
    theme: '主题',
    themeSystem: '系统',
    themeLight: '浅色',
    themeDark: '深色',
    background: '背景',
    backgroundSubtitle: '纯色、渐变或自定义图片',
    bgNone: '无背景',
    bgSolid: '纯色背景',
    bgGradient: '渐变背景',
    bgImage: '自定义图片',
    bgPick: '选择图片',
    bgRemove: '移除图片',
    bgCropHint: '图片按屏幕比例裁切填充',
    storage: '存储空间',
    storageSubtitle: '个人信息、存储文件分类管理',
    storageData: '应用数据',
    storageCache: '缓存',
    storageFiles: '本地数据文件',
    storageEmpty: '暂无数据文件',
    themeColor: '主题色',
    themeColorSubtitle: '设置全局主题颜色',
    language: '语言',
    languageSubtitle: '应用显示语言',
    fontSize: '字体大小',
    fontSizeSubtitle: '调整全局文字缩放',
    preview: '预览',
    previewTitle: '预览标题',
    previewBody: '这是一段示例文字，用于预览当前字体大小。',
    resetDefault: '恢复默认',
    cityLabel: '所在城市',
    grossLabel: '税前月薪',
    grossHint: '如 12000',
    socialBaseLabel: '社保缴费基数',
    fundBaseLabel: '公积金缴费基数',
    followGrossHint: '留空则跟随税前月薪',
    currencySuffix: '元',
    save: '保存',
    saveProfile: '保存个人信息',
    savingProfile: '保存中…',
    clearProfile: '清空个人信息',
    clearDialogTitle: '清空个人信息？',
    clearDialogContent: '清空后计算器将使用城市默认值。此操作不可撤销。',
    cancel: '取消',
    confirmClear: '清空',
    snackbarSavedEmpty: '已保存（当前没有任何填写内容）',
    snackbarSaved: '个人信息已保存到本机',
    snackbarCleared: '个人信息已清空',
  );

  static final AppL10n _zhHant = AppL10n._(
    appTitle: 'XMtools',
    tabOverview: '工具總覽',
    tabUser: '使用者',
    aboutTitle: '關於XMtools',
    aboutBody:
        'XMtools 把常用小工具集中在一處：刷題與搜題、文字閱讀器、文字辨識、證件照、裝置狀態等都能在首頁直接開啟。資料主要儲存在本機，AI 與網路類功能需要連網。',
    aboutToolHint:
        '新增工具：在 lib/features/tools 下建立頁面，並在 builtin_tools.dart 註冊一行即可。',
    aboutVersion: '版本 $kAppVersion',
    ok: '知道了',
    profileSection: '個人資訊',
    profileSubtitle: '城市、工資與五險一金比例',
    basicInfo: '基本資訊',
    basicInfoSubtitle: '所在城市與工資基數',
    insuranceRates: '五險一金比例',
    insuranceRatesSubtitle: '留空時計算使用城市預設值',
    filledNone: '尚未填寫',
    filledCount: (n) => '已填寫 $n 項 · 資料僅保存在本機',
    appearanceSection: '個人化',
    appearanceSubtitle: '模式、主題色、語言與字號',
    appearanceMode: '外觀模式',
    modeLight: '亮色',
    modeDark: '暗色',
    modeSystem: '跟隨系統',
    theme: '主題',
    themeSystem: '系統',
    themeLight: '淺色',
    themeDark: '深色',
    background: '背景',
    backgroundSubtitle: '純色、漸層或自訂圖片',
    bgNone: '無背景',
    bgSolid: '純色背景',
    bgGradient: '漸層背景',
    bgImage: '自訂圖片',
    bgPick: '選擇圖片',
    bgRemove: '移除圖片',
    bgCropHint: '圖片按螢幕比例裁切填滿',
    storage: '儲存空間',
    storageSubtitle: '個人資訊、儲存檔案分類管理',
    storageData: '應用程式資料',
    storageCache: '快取',
    storageFiles: '本機資料檔案',
    storageEmpty: '暫無資料檔案',
    themeColor: '主題色',
    themeColorSubtitle: '設定全域主題顏色',
    language: '語言',
    languageSubtitle: '應用顯示語言',
    fontSize: '字體大小',
    fontSizeSubtitle: '調整全域文字縮放',
    preview: '預覽',
    previewTitle: '預覽標題',
    previewBody: '這是一段範例文字，用於預覽目前字體大小。',
    resetDefault: '還原預設',
    cityLabel: '所在城市',
    grossLabel: '稅前月薪',
    grossHint: '如 12000',
    socialBaseLabel: '社保繳費基數',
    fundBaseLabel: '公積金繳費基數',
    followGrossHint: '留空則跟隨稅前月薪',
    currencySuffix: '元',
    save: '儲存',
    saveProfile: '儲存個人資訊',
    savingProfile: '儲存中…',
    clearProfile: '清空個人資訊',
    clearDialogTitle: '清空個人資訊？',
    clearDialogContent: '清空後計算器將使用城市預設值。此操作不可撤銷。',
    cancel: '取消',
    confirmClear: '清空',
    snackbarSavedEmpty: '已儲存（當前沒有任何填寫內容）',
    snackbarSaved: '個人資訊已儲存到本機',
    snackbarCleared: '個人資訊已清空',
  );

  static final AppL10n _en = AppL10n._(
    appTitle: 'XMtools',
    tabOverview: 'Tools',
    tabUser: 'User',
    aboutTitle: 'About XMtools',
    aboutBody:
        'XMtools gathers everyday tools in one place: quiz practice and search, a text reader, OCR, ID photos, device status and more, all one tap from the home screen. Data stays mostly on this device; AI and network features need internet.',
    aboutToolHint:
        'Add a tool: create a page under lib/features/tools and register it in builtin_tools.dart.',
    aboutVersion: 'Version $kAppVersion',
    ok: 'OK',
    profileSection: 'Personal Info',
    profileSubtitle: 'City, salary and insurance rates',
    basicInfo: 'Basic Info',
    basicInfoSubtitle: 'City and salary base',
    insuranceRates: 'Insurance & Fund Rates',
    insuranceRatesSubtitle: 'City defaults are used when empty',
    filledNone: 'Nothing filled yet',
    filledCount: (n) => '$n items filled · stored on this device only',
    appearanceSection: 'Personalization',
    appearanceSubtitle: 'Mode, color, language and text size',
    appearanceMode: 'Theme Mode',
    modeLight: 'Light',
    modeDark: 'Dark',
    modeSystem: 'Follow system',
    theme: 'Theme',
    themeSystem: 'Auto',
    themeLight: 'Light',
    themeDark: 'Dark',
    background: 'Background',
    backgroundSubtitle: 'Solid color, gradient or your own image',
    bgNone: 'None',
    bgSolid: 'Solid colors',
    bgGradient: 'Gradients',
    bgImage: 'Custom image',
    bgPick: 'Choose image',
    bgRemove: 'Remove image',
    bgCropHint: 'Image is cropped to fill the screen',
    storage: 'Storage',
    storageSubtitle: 'Manage personal files and stored files',
    storageData: 'App data',
    storageCache: 'Cache',
    storageFiles: 'Local data files',
    storageEmpty: 'No data files yet',
    themeColor: 'Theme Color',
    themeColorSubtitle: 'Set the global accent color',
    language: 'Language',
    languageSubtitle: 'Display language of the app',
    fontSize: 'Font Size',
    fontSizeSubtitle: 'Adjust text scaling',
    preview: 'Preview',
    previewTitle: 'Preview heading',
    previewBody: 'This is sample text to preview the current font size.',
    resetDefault: 'Reset',
    cityLabel: 'City',
    grossLabel: 'Gross monthly salary',
    grossHint: 'e.g. 12000',
    socialBaseLabel: 'Social insurance base',
    fundBaseLabel: 'Housing fund base',
    followGrossHint: 'Leave empty to follow salary',
    currencySuffix: 'CNY',
    save: 'Save',
    saveProfile: 'Save personal info',
    savingProfile: 'Saving…',
    clearProfile: 'Clear personal info',
    clearDialogTitle: 'Clear personal info?',
    clearDialogContent:
        'The calculator will fall back to city defaults. This cannot be undone.',
    cancel: 'Cancel',
    confirmClear: 'Clear',
    snackbarSavedEmpty: 'Saved (nothing filled yet)',
    snackbarSaved: 'Personal info saved to this device',
    snackbarCleared: 'Personal info cleared',
  );

  const AppL10n._({
    required this.appTitle,
    required this.tabOverview,
    required this.tabUser,
    required this.aboutTitle,
    required this.aboutBody,
    required this.aboutToolHint,
    required this.aboutVersion,
    required this.ok,
    required this.profileSection,
    required this.profileSubtitle,
    required this.basicInfo,
    required this.basicInfoSubtitle,
    required this.insuranceRates,
    required this.insuranceRatesSubtitle,
    required this.filledNone,
    required this.filledCount,
    required this.appearanceSection,
    required this.appearanceSubtitle,
    required this.appearanceMode,
    required this.modeLight,
    required this.modeDark,
    required this.modeSystem,
    required this.theme,
    required this.themeSystem,
    required this.themeLight,
    required this.themeDark,
    required this.background,
    required this.backgroundSubtitle,
    required this.bgNone,
    required this.bgSolid,
    required this.bgGradient,
    required this.bgImage,
    required this.bgPick,
    required this.bgRemove,
    required this.bgCropHint,
    required this.storage,
    required this.storageSubtitle,
    required this.storageData,
    required this.storageCache,
    required this.storageFiles,
    required this.storageEmpty,
    required this.themeColor,
    required this.themeColorSubtitle,
    required this.language,
    required this.languageSubtitle,
    required this.fontSize,
    required this.fontSizeSubtitle,
    required this.preview,
    required this.previewTitle,
    required this.previewBody,
    required this.resetDefault,
    required this.cityLabel,
    required this.grossLabel,
    required this.grossHint,
    required this.socialBaseLabel,
    required this.fundBaseLabel,
    required this.followGrossHint,
    required this.currencySuffix,
    required this.save,
    required this.saveProfile,
    required this.savingProfile,
    required this.clearProfile,
    required this.clearDialogTitle,
    required this.clearDialogContent,
    required this.cancel,
    required this.confirmClear,
    required this.snackbarSavedEmpty,
    required this.snackbarSaved,
    required this.snackbarCleared,
  });

  final String appTitle;
  final String tabOverview;
  final String tabUser;
  final String aboutTitle;
  final String aboutBody;
  final String aboutToolHint;
  final String aboutVersion;
  final String ok;
  final String profileSection;
  final String profileSubtitle;
  final String basicInfo;
  final String basicInfoSubtitle;
  final String insuranceRates;
  final String insuranceRatesSubtitle;
  final String filledNone;
  final String Function(int n) filledCount;
  final String appearanceSection;
  final String appearanceSubtitle;
  final String appearanceMode;
  final String modeLight;
  final String modeDark;
  final String modeSystem;
  final String theme;
  final String themeSystem;
  final String themeLight;
  final String themeDark;
  final String background;
  final String backgroundSubtitle;
  final String bgNone;
  final String bgSolid;
  final String bgGradient;
  final String bgImage;
  final String bgPick;
  final String bgRemove;
  final String bgCropHint;
  final String storage;
  final String storageSubtitle;
  final String storageData;
  final String storageCache;
  final String storageFiles;
  final String storageEmpty;
  final String themeColor;
  final String themeColorSubtitle;
  final String language;
  final String languageSubtitle;
  final String fontSize;
  final String fontSizeSubtitle;
  final String preview;
  final String previewTitle;
  final String previewBody;
  final String resetDefault;
  final String cityLabel;
  final String grossLabel;
  final String grossHint;
  final String socialBaseLabel;
  final String fundBaseLabel;
  final String followGrossHint;
  final String currencySuffix;
  final String save;
  final String saveProfile;
  final String savingProfile;
  final String clearProfile;
  final String clearDialogTitle;
  final String clearDialogContent;
  final String cancel;
  final String confirmClear;
  final String snackbarSavedEmpty;
  final String snackbarSaved;
  final String snackbarCleared;
}
