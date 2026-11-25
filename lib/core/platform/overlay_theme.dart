/// 搜题悬浮窗的背景色主题。
///
/// 与原生 OverlayPalette 的 key 一一对应；Dart 侧只负责持久化与下发，
/// 真正的画笔配色在原生 View 里按这三个 key 取色板。
enum OverlayTheme {
  dark('dark'),
  light('light'),
  transparent('transparent');

  const OverlayTheme(this.key);

  final String key;

  static OverlayTheme fromKey(String? key) => switch (key) {
        'light' => OverlayTheme.light,
        'transparent' => OverlayTheme.transparent,
        _ => OverlayTheme.dark,
      };

  /// 展示用中文 key（走 tr 三语表）。
  String get labelKey => switch (this) {
        OverlayTheme.dark => '黑色',
        OverlayTheme.light => '白色',
        OverlayTheme.transparent => '透明',
      };
}
