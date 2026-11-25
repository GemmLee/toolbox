/// 证件照工具的原生能力桥接：人脸校验 + 抠图合成 + 相册导出。
///
/// 全部逻辑在 Android 原生侧（ML Kit 人脸检测 + U²-Net LiteRT 推理 +
/// Bitmap 合成 + JPEG 二分压缩），Dart 只负责交互与参数。
/// 非 Android 平台调用会抛 MissingPluginException。
library;

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

/// 图片来源（相册 / 拍照）。
enum IdPhotoImageSource { camera, gallery }

typedef IdPhotoPicker = Future<String?> Function(IdPhotoImageSource source);

/// 默认选图：系统 Photo Picker（Android 13+）或相册；长边限制 3000px，
/// 证件照最终只有几百像素，原图太大只是浪费内存。
Future<String?> defaultIdPhotoPicker(IdPhotoImageSource source) async {
  final file = await ImagePicker().pickImage(
    source: source == IdPhotoImageSource.camera
        ? ImageSource.camera
        : ImageSource.gallery,
    maxWidth: 3000,
    maxHeight: 3000,
    imageQuality: 100,
  );
  return file?.path;
}

/// 一张人脸的矩形框（原图像素坐标）。
class FaceBox {
  const FaceBox(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => (right - left).abs();
  double get height => (bottom - top).abs();
  double get area => width * height;

  /// 与另一框的交并比：用于去掉「同一张脸被重复检出」的框。
  double iou(FaceBox other) {
    final l = left > other.left ? left : other.left;
    final t = top > other.top ? top : other.top;
    final r = right < other.right ? right : other.right;
    final b = bottom < other.bottom ? bottom : other.bottom;
    if (r <= l || b <= t) return 0;
    final overlap = (r - l) * (b - t);
    final union = area + other.area - overlap;
    return union <= 0 ? 0 : overlap / union;
  }
}

/// 一张人脸的位置与姿态（欧拉角，单位度）。
class FaceInfo {
  const FaceInfo({
    required this.count,
    required this.eulerX,
    required this.eulerY,
    required this.eulerZ,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.imageWidth,
    required this.imageHeight,
    this.boxes = const <FaceBox>[],
  });

  /// 原生检出的原始人脸数量（含误检）。
  final int count;

  /// 原生检出的全部人脸框；老版本通道没有这个字段时为空列表。
  final List<FaceBox> boxes;

  /// 抬头/低头角度。
  final double eulerX;

  /// 左右转头角度。
  final double eulerY;

  /// 歪头角度。
  final double eulerZ;

  final double left;
  final double top;
  final double right;
  final double bottom;
  final int imageWidth;
  final int imageHeight;

  bool get hasFace => count > 0 && right > left && bottom > top;
  double get faceWidth => right - left;
  double get faceHeight => bottom - top;
  double get centerX => (left + right) / 2;

  static double _num(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

  factory FaceInfo.fromMap(Map<dynamic, dynamic> map) => FaceInfo(
        count: _num(map['count']).toInt(),
        eulerX: _num(map['eulerX']),
        eulerY: _num(map['eulerY']),
        eulerZ: _num(map['eulerZ']),
        left: _num(map['left']),
        top: _num(map['top']),
        right: _num(map['right']),
        bottom: _num(map['bottom']),
        imageWidth: _num(map['width']).toInt(),
        imageHeight: _num(map['height']).toInt(),
        boxes: <FaceBox>[
          for (final raw in (map['faces'] as List? ?? const <dynamic>[]))
            if (raw is Map)
              FaceBox(
                _num(raw['left']),
                _num(raw['top']),
                _num(raw['right']),
                _num(raw['bottom']),
              ),
        ],
      );

  /// 过滤掉误检后「真正需要视为独立人脸」的数量。
  ///
  /// ML Kit 精确模式会把背景里的小人像、衣服花纹、镜像甚至同一张脸的
  /// 第二个尺度也算成一张脸。证件照场景只关心最大那张人脸：面积不足
  /// 最大脸 35% 的框、以及与已保留框重叠过半（IoU > 0.5）的框都视为误检。
  int get dominantFaceCount {
    if (boxes.isEmpty) return count; // 兼容旧通道 / 测试构造
    final sorted = [...boxes]..sort((a, b) => b.area.compareTo(a.area));
    if (sorted.isEmpty) return 0;
    final largest = sorted.first.area;
    final kept = <FaceBox>[];
    for (final box in sorted) {
      if (largest <= 0 || box.area < largest * 0.35) continue;
      if (kept.any((other) => box.iou(other) > 0.5)) continue;
      kept.add(box);
    }
    return kept.length;
  }
}

/// 人脸校验结论。
enum FaceIssue { none, noFace, multiple, tilted }

/// 姿态阈值：超过就基本不是正面照，抠图和裁切都会歪。
const double kMaxEulerX = 15;
const double kMaxEulerY = 12;
const double kMaxEulerZ = 12;

FaceIssue judgeFace(FaceInfo info) {
  if (info.count == 0) return FaceIssue.noFace;
  if (info.dominantFaceCount > 1) return FaceIssue.multiple;
  if (info.eulerX.abs() > kMaxEulerX ||
      info.eulerY.abs() > kMaxEulerY ||
      info.eulerZ.abs() > kMaxEulerZ) {
    return FaceIssue.tilted;
  }
  return FaceIssue.none;
}

/// 按「头占画面约 2/3 高」推算裁切框，返回原图像素坐标。
///
/// 证件照的通用构图：头顶留白约 8%，下巴到胸线留下一段。这里以人脸框
/// 高度为基准放大 1.55 倍作为画框高，再按目标比例换算宽度。
Rect suggestCrop(FaceInfo face, double ratio, int imageWidth, int imageHeight) {
  if (!face.hasFace || ratio <= 0 || imageWidth <= 0 || imageHeight <= 0) {
    return Rect.zero;
  }
  var cropH = face.faceHeight * 1.55;
  var cropW = cropH * ratio;
  if (cropW > imageWidth) {
    cropW = imageWidth.toDouble();
    cropH = cropW / ratio;
  }
  if (cropH > imageHeight) {
    cropH = imageHeight.toDouble();
    cropW = cropH * ratio;
  }
  final left = (face.centerX - cropW / 2)
      .clamp(0.0, (imageWidth - cropW).clamp(0.0, double.infinity));
  final top = (face.top - cropH * 0.28)
      .clamp(0.0, (imageHeight - cropH).clamp(0.0, double.infinity));
  return Rect.fromLTWH(left, top, cropW, cropH);
}

/// 把裁切框收进图片边界内（尺寸不变，只挪位置）。
Rect clampCrop(Rect crop, int imageWidth, int imageHeight) {
  final width = crop.width;
  final height = crop.height;
  final left =
      crop.left.clamp(0.0, (imageWidth - width).clamp(0.0, double.infinity));
  final top =
      crop.top.clamp(0.0, (imageHeight - height).clamp(0.0, double.infinity));
  return Rect.fromLTWH(left, top, width, height);
}

/// 一次处理的入参。
class IdPhotoRequest {
  const IdPhotoRequest({
    required this.sourcePath,
    required this.crop,
    required this.background,
    required this.width,
    required this.height,
    this.maxKb = 0,
    this.edgeShrink = 0,
  });

  final String sourcePath;

  /// 原图像素坐标下的裁切框（比例已与目标尺寸一致）。
  final Rect crop;

  /// 背景色 ARGB（0xFFRRGGBB）。
  final int background;
  final int width;
  final int height;

  /// 目标体积（KB）；0 表示不限制。
  final int maxKb;

  /// 边缘蒙版收缩（0~1）：越大越紧贴人像，能去掉原底色的残留描边。
  final double edgeShrink;
}

/// 只改底色 / 边缘收缩 / 体积：复用原生侧缓存的抠图结果，不重跑模型。
class IdPhotoRecolorRequest {
  const IdPhotoRecolorRequest({
    required this.background,
    required this.edgeShrink,
    required this.maxKb,
  });

  final int background;
  final double edgeShrink;
  final int maxKb;
}

/// 处理结果：写完的临时 JPEG 路径与体积。
class IdPhotoResult {
  const IdPhotoResult({
    required this.path,
    required this.width,
    required this.height,
    required this.bytes,
  });

  final String path;
  final int width;
  final int height;
  final int bytes;

  double get kilobytes => bytes / 1024;

  factory IdPhotoResult.fromMap(Map<dynamic, dynamic> map) => IdPhotoResult(
        path: map['path']?.toString() ?? '',
        width: (map['width'] as num?)?.toInt() ?? 0,
        height: (map['height'] as num?)?.toInt() ?? 0,
        bytes: (map['bytes'] as num?)?.toInt() ?? 0,
      );
}

typedef IdPhotoProgress = void Function(String stage, double value);

/// 抠图 / 合成进度回调的阶段名。
class IdPhotoStage {
  static const String detect = 'detect';
  static const String matte = 'matte';
  static const String composite = 'composite';
  static const String compress = 'compress';
}

/// 证件照引擎（可注入，widget 测试用假实现替换真实通道）。
abstract class IdPhotoEngine {
  Future<FaceInfo> detectFace(String path);

  Future<IdPhotoResult> process(
    IdPhotoRequest request, {
    IdPhotoProgress? onProgress,
  });

  /// 复用上一次抠图缓存重出一张图；缓存不存在时返回 null，调用方回退到
  /// [process]（例如 App 被系统回收后原生缓存已丢）。
  Future<IdPhotoResult?> recolor(IdPhotoRecolorRequest request);

  Future<bool> saveToGallery(String path, String name);
}

/// Android 原生实现。
class IdPhotoBridge implements IdPhotoEngine {
  IdPhotoBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('toolbox/id_photo');

  final MethodChannel _channel;

  @override
  Future<FaceInfo> detectFace(String path) async {
    final reply = await _channel.invokeMapMethod<String, dynamic>(
      'detect',
      <String, Object?>{'path': path},
    );
    if (reply == null) {
      throw PlatformException(
        code: 'ID_PHOTO_EMPTY',
        message: 'face detector returned no result',
      );
    }
    return FaceInfo.fromMap(reply);
  }

  @override
  Future<IdPhotoResult> process(
    IdPhotoRequest request, {
    IdPhotoProgress? onProgress,
  }) async {
    // 原生侧每完成一步就回一条 progress，避免长任务期间界面像卡死。
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress' && onProgress != null) {
        final args = call.arguments;
        if (args is Map) {
          onProgress(
            args['stage']?.toString() ?? '',
            (args['value'] as num?)?.toDouble() ?? 0,
          );
        }
      }
      return null;
    });
    try {
      final reply = await _channel.invokeMapMethod<String, dynamic>(
        'process',
        <String, Object?>{
          'path': request.sourcePath,
          'left': request.crop.left,
          'top': request.crop.top,
          'right': request.crop.right,
          'bottom': request.crop.bottom,
          'background': request.background,
          'width': request.width,
          'height': request.height,
          'maxKb': request.maxKb,
          'edgeShrink': request.edgeShrink,
        },
      );
      if (reply == null) {
        throw PlatformException(code: 'ID_PHOTO_EMPTY', message: 'no result');
      }
      return IdPhotoResult.fromMap(reply);
    } finally {
      _channel.setMethodCallHandler(null);
    }
  }

  @override
  Future<IdPhotoResult?> recolor(IdPhotoRecolorRequest request) async {
    final reply = await _channel.invokeMapMethod<String, dynamic>(
      'recolor',
      <String, Object?>{
        'background': request.background,
        'edgeShrink': request.edgeShrink,
        'maxKb': request.maxKb,
      },
    );
    return reply == null ? null : IdPhotoResult.fromMap(reply);
  }

  @override
  Future<bool> saveToGallery(String path, String name) async {
    final ok = await _channel.invokeMethod<bool>(
      'saveToGallery',
      <String, Object?>{'path': path, 'name': name},
    );
    return ok ?? false;
  }
}
