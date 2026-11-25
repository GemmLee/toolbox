import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/app_theme.dart';
import 'package:toolbox/core/settings/app_background.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/core/settings/theme_palette.dart';
import 'package:toolbox/core/widgets/app_backdrop.dart';
import '../support/test_env.dart';

/// 主题是全局视觉的底座，用测试把「对比度」和「深浅色层次」钉住，
/// 以后再加主题色也不会悄悄破坏可读性。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  mockPrefs();

  group('配色可读性（WCAG AA）', () {
    test('所有主题色的前景 / 背景对比度达标', () {
      for (final entry in ThemePalette.all) {
        for (final brightness in Brightness.values) {
          final scheme = AppTheme.schemeFor(entry.color, brightness);
          final where = '${entry.id} / ${brightness.name}';

          expect(
            AppTheme.contrast(scheme.primary, scheme.onPrimary),
            greaterThanOrEqualTo(4.5),
            reason: '$where：主色上的文字',
          );
          expect(
            AppTheme.contrast(scheme.surface, scheme.onSurface),
            greaterThanOrEqualTo(7),
            reason: '$where：正文',
          );
          expect(
            AppTheme.contrast(scheme.surface, scheme.onSurfaceVariant),
            greaterThanOrEqualTo(4.5),
            reason: '$where：次要文字',
          );
          expect(
            AppTheme.contrast(scheme.surface, scheme.primary),
            greaterThanOrEqualTo(3),
            reason: '$where：卡片上的强调色',
          );
          expect(
            AppTheme.contrast(scheme.surface, scheme.error),
            greaterThanOrEqualTo(3),
            reason: '$where：错误色',
          );
        }
      }
    });

    test('浅色下卡片比页面底色亮，深色下更亮一档', () {
      final light = AppTheme.schemeFor(ThemePalette.byId('skyBlue').color,
          Brightness.light);
      expect(
        light.surface.computeLuminance(),
        greaterThan(light.surfaceContainerLow.computeLuminance()),
      );

      final dark = AppTheme.schemeFor(ThemePalette.byId('skyBlue').color,
          Brightness.dark);
      expect(
        dark.surface.computeLuminance(),
        greaterThan(dark.surfaceContainerLowest.computeLuminance()),
      );
    });

    test('深色块自动取白字，浅色块仍取深字', () {
      expect(AppTheme.readableOn(const Color(0xFF1B1E27)), Colors.white);
      expect(AppTheme.readableOn(const Color(0xFFF5F7FA)),
          const Color(0xFF14161B));
    });

    test('半透明彩色块先合成到底色再取前景', () {
      // 半透明填充色本身 alpha 很低，computeLuminance() 会忽略 alpha；
      // 传入真实底色后，深色主题下的深色块应拿到白字而不是黑字。
      const fill = Color(0x1FC62828);
      const darkSurface = Color(0xFF16181D);
      final blended = Color.alphaBlend(fill, darkSurface);
      expect(AppTheme.readableOn(fill, base: darkSurface),
          AppTheme.readableOn(blended));
      expect(AppTheme.readableOn(fill, base: darkSurface), Colors.white);
      expect(
        AppTheme.contrast(
          blended,
          AppTheme.readableOn(fill, base: darkSurface),
        ),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('主题色不同，生成的主色也不同（不是全部褪成灰）', () {
      final colors = <int>{
        for (final entry in ThemePalette.all)
          AppTheme.schemeFor(entry.color, Brightness.light).primary.value,
      };
      // 24 个色板至少应区分出 20 种主色
      expect(colors.length, greaterThanOrEqualTo(20));
    });
  });

  test('每一套主题都能构建出 ThemeData', () {
    for (final entry in ThemePalette.all) {
      expect(AppTheme.light(entry.color).colorScheme.primary, isNotNull);
      expect(AppTheme.dark(entry.color).colorScheme.surface, isNotNull);
    }
  });

  group('自定义背景前景色', () {
    test('浅色主题 + 深色图片用白字，浅色图片仍用深字', () {
      bool dark({
        required BackgroundKind kind,
        required double? luminance,
        Brightness brightness = Brightness.light,
      }) =>
          AppBackdrop.isDarkBackdrop(
        kind: kind,
        colorId: AppBackgrounds.colors.first.id,
        gradientId: AppBackgrounds.gradients.first.id,
        hasImage: true,
        imageLuminance: luminance,
        brightness: brightness,
      );

      expect(dark(kind: BackgroundKind.image, luminance: 0.05), isTrue);
      expect(dark(kind: BackgroundKind.image, luminance: 0.75), isFalse);
      // 老版本没有亮度信息时保持主题默认行为。
      expect(dark(kind: BackgroundKind.image, luminance: null), isFalse);
      expect(dark(kind: BackgroundKind.color, luminance: null), isFalse);
      expect(
        dark(
          kind: BackgroundKind.color,
          luminance: null,
          brightness: Brightness.dark,
        ),
        isTrue,
      );
    });

    test('背景图亮度随设置持久化，移除图片时一起清空', () async {
      final settings = SettingsController.instance;
      await settings.setBackgroundImage('bg.jpg', luminance: 0.08);
      expect(settings.backgroundImageLuminance, 0.08);

      settings.resetForTest();
      await settings.load();
      expect(settings.backgroundImagePath, 'bg.jpg');
      expect(settings.backgroundImageLuminance, 0.08);

      await settings.setBackgroundImage(null);
      settings.resetForTest();
      await settings.load();
      expect(settings.backgroundImageLuminance, isNull);
    });
  });

  testWidgets('背景层：无背景与纯色都能渲染，且不遮挡内容', (tester) async {
    SettingsController.instance.setLanguage(AppLanguage.simplifiedChinese);
    addTearDown(() =>
        SettingsController.instance.setLanguage(AppLanguage.system));

    for (final kind in BackgroundKind.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(ThemePalette.byId('glazeGreen').color),
          home: AppBackdrop(
            kind: kind,
            colorId: AppBackgrounds.colors.first.id,
            gradientId: AppBackgrounds.gradients.first.id,
            imagePath: null,
            child: const Scaffold(
              backgroundColor: Colors.transparent,
              body: Center(child: Text('内容可见')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('内容可见'), findsOneWidget);
    }
  });
}
