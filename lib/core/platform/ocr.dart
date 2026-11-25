import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

/// 图片来源，UI 用不到 image_picker 的具体类型，便于测试注入。
enum OcrImageSource { camera, gallery }

typedef OcrImagePicker = Future<String?> Function(OcrImageSource source);
typedef OcrRecognizer = Future<OcrResult> Function(String path);

/// 默认选图：拍照或从相册取一张，限制长边避免超大图拖慢识别。
Future<String?> defaultOcrImagePicker(OcrImageSource source) async {
  final file = await ImagePicker().pickImage(
    source: source == OcrImageSource.camera
        ? ImageSource.camera
        : ImageSource.gallery,
    maxWidth: 2400,
    imageQuality: 95,
  );
  return file?.path;
}

/// 一行识别结果，带原始坐标；用于把「排版整齐」的图片还原成段落文本。
class OcrLine {
  const OcrLine({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String text;
  final int left;
  final int top;
  final int width;
  final int height;

  factory OcrLine.fromMap(Map<dynamic, dynamic> map) => OcrLine(
        text: map['text']?.toString() ?? '',
        left: _asInt(map['left']),
        top: _asInt(map['top']),
        width: _asInt(map['width']),
        height: _asInt(map['height']),
      );

  static int _asInt(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

/// OCR 返回值：ML Kit 的原始整段文本 + 逐行几何信息。
class OcrResult {
  const OcrResult({required this.text, required this.lines});

  final String text;
  final List<OcrLine> lines;

  factory OcrResult.fromMap(Map<dynamic, dynamic> map) {
    final raw = map['lines'] as List<dynamic>? ?? const <dynamic>[];
    final lines = <OcrLine>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final line = OcrLine.fromMap(item);
      if (line.text.isNotEmpty) lines.add(line);
    }
    return OcrResult(
      text: map['text']?.toString() ?? '',
      lines: List<OcrLine>.unmodifiable(lines),
    );
  }
}

/// 按行坐标还原阅读顺序：自上而下、同行从左到右；行间距明显变大时分段。
///
/// 图片排版整齐时，这个处理能把 ML Kit 的散行拼回自然段；
/// 没有几何信息时回退到引擎给出的整段文本。
String assembleOcrText(List<OcrLine> lines) {
  if (lines.isEmpty) return '';
  final sorted = List<OcrLine>.of(lines)
    ..sort((a, b) {
      final byTop = a.top.compareTo(b.top);
      return byTop != 0 ? byTop : a.left.compareTo(b.left);
    });
  final buffer = StringBuffer();
  OcrLine? previous;
  for (final line in sorted) {
    if (previous != null) {
      final gap = line.top - (previous.top + previous.height);
      final newParagraph = previous.height > 0 && gap > previous.height * 0.9;
      buffer.write(newParagraph ? '\n\n' : '\n');
    }
    buffer.write(line.text);
    previous = line;
  }
  return buffer.toString().trim();
}

/// Android 端 ML Kit 文字识别通道。
///
/// 中文 + 拉丁模型随 APK 打包（bundled），完全离线，不需要联网下载模型，
/// 也不需要 Google Play 服务。非 Android 平台调用会抛 MissingPluginException。
class OcrScanner {
  OcrScanner._();

  static const MethodChannel _channel = MethodChannel('toolbox/ocr');

  static Future<OcrResult> recognize(String path) async {
    final reply = await _channel.invokeMapMethod<String, dynamic>(
      'recognize',
      <String, Object?>{'path': path},
    );
    if (reply == null) {
      throw PlatformException(
        code: 'OCR_EMPTY',
        message: 'OCR engine returned no result',
      );
    }
    return OcrResult.fromMap(reply);
  }
}
