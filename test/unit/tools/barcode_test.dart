import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:barcode/barcode.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';
import 'package:toolbox/features/tools/qrcode/barcode_decode.dart';

/// 把 RGBA 像素编成 PNG（decodeBarcodeImage 的输入）。
Future<Uint8List> _png(Uint8List rgba, int width, int height) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 画一张二维码（含 4 模块静区）。
Future<Uint8List> _qrPng(String text, {int scale = 6}) async {
  final code = QrCode.fromData(data: text, errorCorrectLevel: QrErrorCorrectLevel.M);
  final qr = QrImage(code);
  const quiet = 4;
  final size = (qr.moduleCount + quiet * 2) * scale;
  final rgba = Uint8List(size * size * 4)..fillRange(0, size * size * 4, 255);
  for (var row = 0; row < qr.moduleCount; row++) {
    for (var col = 0; col < qr.moduleCount; col++) {
      if (!qr.isDark(row, col)) continue;
      for (var dy = 0; dy < scale; dy++) {
        for (var dx = 0; dx < scale; dx++) {
          final x = (col + quiet) * scale + dx;
          final y = (row + quiet) * scale + dy;
          final o = (y * size + x) * 4;
          rgba[o] = 0;
          rgba[o + 1] = 0;
          rgba[o + 2] = 0;
        }
      }
    }
  }
  return _png(rgba, size, size);
}

/// 画一张一维条码（白底 + 黑色条 + 左右/上下留白）。
Future<Uint8List> _barcodePng(Barcode bc, String data) async {
  const margin = 24;
  const barW = 2.0; // 每个模块像素宽
  final elements = bc.make(data, width: 300, height: 100).toList();
  const innerW = 300.0 * barW;
  const innerH = 100.0;
  final width = (innerW + margin * 2).ceil();
  final height = (innerH + margin * 2).ceil();
  final rgba = Uint8List(width * height * 4)..fillRange(0, width * height * 4, 255);
  for (final e in elements) {
    if (e is! BarcodeBar || !e.black) continue;
    final x0 = (margin + e.left * barW).round().clamp(0, width);
    final x1 = (margin + e.right * barW).round().clamp(0, width);
    final y0 = (margin + e.top).round().clamp(0, height);
    final y1 = (margin + e.bottom).round().clamp(0, height);
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final o = (y * width + x) * 4;
        rgba[o] = 0;
        rgba[o + 1] = 0;
        rgba[o + 2] = 0;
      }
    }
  }
  return _png(rgba, width, height);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('识别二维码图片', () async {
    final png = await _qrPng('https://example.com/中文', scale: 8);
    final result = await decodeBarcodeImage(png);
    expect(result, isNotNull);
    expect(result!.text, 'https://example.com/中文');
    expect(result.format, 'qrCode');
    expect(result.formatLabel, 'QR Code');
  });

  test('识别 Code 128 条码', () async {
    final png = await _barcodePng(Barcode.code128(), 'ABC-12345');
    final result = await decodeBarcodeImage(png);
    expect(result, isNotNull);
    expect(result!.text, 'ABC-12345');
    expect(result.format, 'code128');
  });

  test('识别 EAN-13 条码', () async {
    final png = await _barcodePng(Barcode.ean13(), '6901234567892');
    final result = await decodeBarcodeImage(png);
    expect(result, isNotNull);
    expect(result!.text, '6901234567892');
  });

  test('没有码的图片返回 null 而不是抛异常', () async {
    const size = 64;
    final rgba = Uint8List(size * size * 4)..fillRange(0, size * size * 4, 255);
    final png = await _png(rgba, size, size);
    expect(await decodeBarcodeImage(png), isNull);
  });

  test('损坏的图片字节不崩溃', () async {
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
    expect(await decodeBarcodeImage(bytes), isNull);
  });
}
