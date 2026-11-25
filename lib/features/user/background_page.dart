import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/app_theme.dart';
import '../../core/settings/app_background.dart';
import '../../core/settings/app_l10n.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/storage/app_files.dart';
import '../../core/widgets/app_backdrop.dart';
import '../../core/widgets/app_widgets.dart';

/// 背景设置：无 / 纯色 / 渐变 / 自定义图片（自动裁切填充屏幕）。
class BackgroundPage extends StatefulWidget {
  const BackgroundPage({super.key});

  @override
  State<BackgroundPage> createState() => _BackgroundPageState();
}

class _BackgroundPageState extends State<BackgroundPage> {
  bool _picking = false;

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.of().background)),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final l10n = AppL10n.of();
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        settings.backgroundKind == BackgroundKind.none
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: theme.colorScheme.primary,
                      ),
                      title: Text(l10n.bgNone),
                      onTap: () => settings.setBackgroundKind(BackgroundKind.none),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _sectionTitle(context, l10n.bgSolid),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final item in AppBackgrounds.colors)
                        _ColorDot(
                          key: ValueKey<String>('bg-color-${item.id}'),
                          color: item.color,
                          selected: settings.backgroundKind ==
                                  BackgroundKind.color &&
                              settings.backgroundColorId == item.id,
                          onTap: () => settings.setBackgroundColor(item.id),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _sectionTitle(context, l10n.bgGradient),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final item in AppBackgrounds.gradients)
                        _GradientCard(
                          key: ValueKey<String>('bg-gradient-${item.id}'),
                          gradient: item,
                          selected: settings.backgroundKind ==
                                  BackgroundKind.gradient &&
                              settings.backgroundGradientId == item.id,
                          onTap: () => settings.setBackgroundGradient(item.id),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _sectionTitle(context, l10n.bgImage),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (settings.backgroundImagePath != null &&
                          File(settings.backgroundImagePath!).existsSync()) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            File(settings.backgroundImagePath!),
                            height: 140,
                            width: double.infinity,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      SmallHint(text: l10n.bgCropHint),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _picking ? null : _pickImage,
                              icon: _picking
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.image_outlined),
                              label: Text(l10n.bgPick),
                            ),
                          ),
                          if (settings.backgroundImagePath != null) ...[
                            const SizedBox(width: 10),
                            OutlinedButton(
                              onPressed: () =>
                                  settings.setBackgroundImage(null),
                              child: Text(l10n.bgRemove),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: BackdropStyle.foregroundOf(
            context,
            theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Future<void> _pickImage() async {
    setState(() => _picking = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
        imageQuality: 90,
      );
      if (picked == null) return;
      // 背景图属于「个人信息」，存进存储空间统一管理。
      final stored = await AppStore.adopt(
        category: AppStoreCategory.profile,
        source: File(picked.path),
        name: '背景-${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      final target = stored.file;
      // 清理上一张自定义背景，避免占空间
      final previous = SettingsController.instance.backgroundImagePath;
      if (previous != null && previous.isNotEmpty && previous != target.path) {
        try {
          final old = File(previous);
          if (old.existsSync()) await old.delete();
        } catch (_) {}
      }
      final luminance = await _averageLuminance(target);
      await SettingsController.instance.setBackgroundImage(
        target.path,
        luminance: luminance,
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 采样背景图的平均亮度（线性亮度 0~1），用于决定前景文字取白还是取深。
  /// 解码到 24px 宽后抽样像素，几乎不占内存；失败时返回 null 走主题默认色。
  static Future<double?> _averageLuminance(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 24);
      final frame = await codec.getNextFrame();
      final rgba = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      frame.image.dispose();
      codec.dispose();
      if (rgba == null) return null;
      final pixels = rgba.buffer.asUint8List();
      var sum = 0.0;
      var count = 0;
      for (var i = 0; i + 3 < pixels.length; i += 16) {
        sum += Color.fromARGB(
          255,
          pixels[i],
          pixels[i + 1],
          pixels[i + 2],
        ).computeLuminance();
        count++;
      }
      return count == 0 ? null : sum / count;
    } catch (_) {
      return null;
    }
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: selected
            ? Icon(Icons.check, size: 18, color: AppTheme.readableOn(color))
            : null,
      ),
    );
  }
}

class _GradientCard extends StatelessWidget {
  const _GradientCard({
    super.key,
    required this.gradient,
    required this.selected,
    required this.onTap,
  });

  final AppBackgroundGradient gradient;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: gradient.colors,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2.5 : 1,
          ),
        ),
        alignment: Alignment.center,
        child: selected
            ? Icon(Icons.check,
                size: 20,
                color: AppTheme.readableOn(gradient.colors.first))
            : null,
      ),
    );
  }
}
