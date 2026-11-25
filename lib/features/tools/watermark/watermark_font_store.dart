import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../../../../core/storage/app_files.dart';
import '../../../../core/storage/local_store.dart';

/// 用户自行导入的水印字体：字体文件随 App 存储目录持久化，family 存偏好。
///
/// 应用不再内置艺术字体（那是 APK 里最大的单份素材），需要时由用户导入
/// .ttf/.otf，运行时注册到引擎后即可给水印与预览使用。
class UserWatermarkFont {
  const UserWatermarkFont({
    required this.family,
    required this.name,
    required this.path,
  });

  /// 注册给引擎用的 family 名，前缀固定避免与系统/主题字体冲突。
  final String family;

  /// 展示用的原始文件名。
  final String name;

  final String path;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'family': family,
        'name': name,
        'path': path,
      };

  factory UserWatermarkFont.fromJson(Map<String, dynamic> json) =>
      UserWatermarkFont(
        family: (json['family'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        path: (json['path'] ?? '').toString(),
      );
}

/// 字体仓库：导入 / 列出 / 删除 / 重新注册。
///
/// [picker] 与 [loader] 可注入，便于单测覆盖而不触碰真实文件选择器或引擎。
class WatermarkFontStore {
  WatermarkFontStore({
    Future<({List<int> bytes, String name})?> Function()? picker,
    Future<void> Function(Uint8List bytes, String family)? loader,
    Future<Directory> Function()? rootLoader,
  })  : _picker = picker,
        _loader = loader,
        _rootLoader = rootLoader;

  static const String storageKey = 'watermark_user_fonts';
  static const String familyPrefix = 'wm_user_';
  static const int maxBytes = 30 * 1024 * 1024;

  final Future<({List<int> bytes, String name})?> Function()? _picker;
  final Future<void> Function(Uint8List bytes, String family)? _loader;
  final Future<Directory> Function()? _rootLoader;

  Future<Directory> _dir() async {
    final root = await (_rootLoader ?? AppStore.root)();
    return Directory(p.join(root.path, 'watermark_fonts'));
  }

  Future<List<UserWatermarkFont>> load() async {
    final map = await LocalStore.readMap(storageKey);
    final raw = map?['fonts'];
    if (raw is! List) return const <UserWatermarkFont>[];
    return raw
        .whereType<Map>()
        .map((e) => UserWatermarkFont.fromJson(Map<String, dynamic>.from(e)))
        .where((f) => f.family.isNotEmpty && File(f.path).existsSync())
        .toList(growable: false);
  }

  /// 选一个字体文件并导入；返回新增的字体，取消时返回 null。
  Future<UserWatermarkFont?> importFont() async {
    final picked = await (_picker ?? _pickWithFilePicker)();
    if (picked == null || picked.bytes.isEmpty) return null;
    final bytes = picked.bytes;
    if (bytes.length > maxBytes) throw StateError('字体文件不能超过 30 MB');

    final name = picked.name;
    final ext = p.extension(name).toLowerCase();
    if (ext != '.ttf' && ext != '.otf') {
      throw StateError('仅支持 .ttf / .otf 字体');
    }
    final family = '$familyPrefix${DateTime.now().microsecondsSinceEpoch}';
    final bytesView = Uint8List.fromList(bytes);

    // 先注册成功再落盘，避免存进一个用不了的 family。
    await (_loader ?? _loadWithEngine)(bytesView, family);
    final dir = await _dir();
    if (!dir.existsSync()) await dir.create(recursive: true);
    final fileName = '$family$ext';
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytesView, flush: true);

    final fonts = <UserWatermarkFont>[
      ...await load(),
      UserWatermarkFont(family: family, name: name, path: file.path),
    ];
    await _save(fonts);
    return fonts.last;
  }

  Future<void> registerAll() async {
    for (final font in await load()) {
      try {
        await (_loader ?? _loadWithEngine)(
          await File(font.path).readAsBytes(),
          font.family,
        );
      } catch (_) {
        // 单个字体损坏不影响其它字体。
      }
    }
  }

  Future<void> remove(UserWatermarkFont font) async {
    final fonts = (await load()).where((f) => f.family != font.family).toList();
    await _save(fonts);
    final file = File(font.path);
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _save(List<UserWatermarkFont> fonts) =>
      LocalStore.writeMap(storageKey, <String, dynamic>{
        'fonts': fonts.map((f) => f.toJson()).toList(growable: false),
      });

  Future<({List<int> bytes, String name})?> _pickWithFilePicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['ttf', 'otf'],
      withData: true,
    );
    final file = result?.files.singleOrNull;
    if (file == null) return null;
    if (file.bytes != null) return (bytes: file.bytes!, name: file.name);
    if (file.path == null) return null;
    return (bytes: await File(file.path!).readAsBytes(), name: file.name);
  }

  Future<void> _loadWithEngine(Uint8List bytes, String family) =>
      ui.loadFontFromList(bytes, fontFamily: family);
}
