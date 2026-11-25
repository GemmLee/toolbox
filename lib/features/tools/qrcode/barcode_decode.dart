import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:zxing_lib/common.dart';
import 'package:zxing_lib/zxing.dart';

/// 识别结果。
class BarcodeScanResult {
  const BarcodeScanResult({required this.text, required this.format});

  final String text;

  /// zxing 格式名（code128 / qrCode / ean13 …）。
  final String format;

  /// 人类可读的格式名。
  String get formatLabel {
    switch (format) {
      case 'qrCode':
        return 'QR Code';
      case 'code128':
        return 'Code 128';
      case 'code39':
        return 'Code 39';
      case 'code93':
        return 'Code 93';
      case 'ean13':
        return 'EAN-13';
      case 'ean8':
        return 'EAN-8';
      case 'upcA':
        return 'UPC-A';
      case 'upcE':
        return 'UPC-E';
      case 'itf':
        return 'ITF';
      case 'codabar':
        return 'Codabar';
      case 'pdf417':
        return 'PDF417';
      case 'dataMatrix':
        return 'Data Matrix';
      case 'aztec':
        return 'Aztec';
      case 'maxicode':
        return 'MaxiCode';
      default:
        return format.isEmpty ? '未知格式' : format;
    }
  }

  /// 内容像链接时给一个可点的判断。
  bool get isLink =>
      text.startsWith('http://') ||
      text.startsWith('https://') ||
      text.startsWith('www.');
}

class _DecodeInput {
  const _DecodeInput(this.width, this.height, this.pixels);

  final int width;
  final int height;

  /// ARGB 整型像素。
  final Int32List pixels;
}

/// 从图片字节里识别二维码 / 条形码。
///
/// 纯 Dart 解码（zxing_lib），不依赖相机与 Google 服务；先按原图解码，
/// 失败再试反色（深色底浅色码）。识别在独立 isolate 中进行，避免卡 UI。
Future<BarcodeScanResult?> decodeBarcodeImage(Uint8List bytes) async {
  final image = await _loadImage(bytes);
  if (image == null) return null;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final pixels = _toArgb(data.buffer.asUint8List(), image.width, image.height);
    final map = await compute(
      _decodeTask,
      _DecodeInput(image.width, image.height, pixels),
    );
    if (map == null) return null;
    final text = map['text'] as String? ?? '';
    if (text.isEmpty) return null;
    return BarcodeScanResult(
      text: text,
      format: map['format'] as String? ?? '',
    );
  } finally {
    image.dispose();
  }
}

/// 解码任务（isolate 入口，必须是顶层函数）。
Map<String, dynamic>? _decodeTask(_DecodeInput input) {
  final source = RGBLuminanceSource(input.width, input.height, input.pixels);
  final readers = <Reader>[
    MultiFormatReader(),
  ];
  // 两种二值化 + 反色，覆盖光照不均与深色底的图
  final variants = <LuminanceSource Function()>[
    () => source,
    () => source,
    () => InvertedLuminanceSource(source),
  ];
  final binarizers = <Binarizer Function(LuminanceSource)>[
    (s) => HybridBinarizer(s),
    (s) => GlobalHistogramBinarizer(s),
    (s) => HybridBinarizer(s),
  ];
  for (var i = 0; i < readers.length; i++) {
    for (var v = 0; v < variants.length; v++) {
      try {
        final bitmap = BinaryBitmap(binarizers[v](variants[v]()));
        final result = readers[i].decode(bitmap);
        final text = result.text;
        if (text.isEmpty) continue;
        return <String, dynamic>{
          'text': text,
          'format': result.barcodeFormat.name,
        };
      } catch (_) {
        // ReaderException / FormatException：换下一种组合继续试
        continue;
      }
    }
  }
  return null;
}

/// 读取图片并按需缩小（长边超过 1600 时再解码一次），控制识别耗时。
Future<ui.Image?> _loadImage(Uint8List bytes) async {
  try {
    final probe = await ui.instantiateImageCodec(bytes);
    final frame = await probe.getNextFrame();
    final image = frame.image;
    if (image.width <= 1600) return image;
    image.dispose();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1600);
    final small = await codec.getNextFrame();
    return small.image;
  } catch (_) {
    return null;
  }
}

Int32List _toArgb(Uint8List rgba, int width, int height) {
  final count = width * height;
  final out = Int32List(count);
  for (var i = 0; i < count; i++) {
    final o = i * 4;
    final r = rgba[o];
    final g = rgba[o + 1];
    final b = rgba[o + 2];
    // 0xFF000000 | r<<16 | g<<8 | b
    out[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
  }
  return out;
}
