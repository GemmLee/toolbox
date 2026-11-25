import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/platform/id_photo.dart' show clampCrop;

/// 读取图片像素尺寸（默认走 codec，只解码头信息）。
typedef IdPhotoSizeLoader = Future<Size> Function(String path);

Future<Size> defaultIdPhotoSizeLoader(String path) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final size = Size(
    frame.image.width.toDouble(),
    frame.image.height.toDouble(),
  );
  frame.image.dispose();
  codec.dispose();
  return size;
}

/// 按目标比例裁切：固定画框、双指缩放 / 拖动选景，返回原图像素坐标。
///
/// 画框比例锁定为证件照规格，所以出来的图不再二次变形。
class IdPhotoCropPage extends StatefulWidget {
  const IdPhotoCropPage({
    super.key,
    required this.imagePath,
    required this.aspectRatio,
    this.initialRect,
    this.sizeLoader = defaultIdPhotoSizeLoader,
    this.previewBuilder,
  });

  final String imagePath;

  /// 宽 / 高。
  final double aspectRatio;

  /// 初始画框（原图像素坐标），一般由人脸位置推算。
  final Rect? initialRect;

  final IdPhotoSizeLoader sizeLoader;

  /// 测试注入：替换真实图片预览。
  final Widget Function(Size imageSize)? previewBuilder;

  @override
  State<IdPhotoCropPage> createState() => _IdPhotoCropPageState();
}

class _IdPhotoCropPageState extends State<IdPhotoCropPage> {
  final TransformationController _controller = TransformationController();
  Size? _imageSize;
  String? _error;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _loadSize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadSize() async {
    try {
      final size = await widget.sizeLoader(widget.imagePath);
      if (!mounted) return;
      setState(() => _imageSize = size);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 画框尺寸：按可用空间等比缩放，留出边距。
  Size _boxOf(BoxConstraints constraints) {
    final ratio = widget.aspectRatio <= 0 ? 0.72 : widget.aspectRatio;
    final maxW = constraints.maxWidth - 32;
    final maxH = constraints.maxHeight - 24;
    var width = maxW;
    var height = width / ratio;
    if (height > maxH) {
      height = maxH;
      width = height * ratio;
    }
    return Size(math.max(80, width), math.max(80, height));
  }

  Matrix4 _matrixFor(Rect rect, Size box) {
    final scale = box.width / rect.width;
    return Matrix4.identity()
      ..translate(-rect.left * scale, -rect.top * scale)
      ..scale(scale);
  }

  Rect _centeredRect(Size image, Size box) {
    // 没有初始框时按「铺满画框」取中间区域。
    final scale = math.max(box.width / image.width, box.height / image.height);
    final width = box.width / scale;
    final height = box.height / scale;
    return Rect.fromLTWH(
      (image.width - width) / 2,
      (image.height - height) / 2,
      width,
      height,
    );
  }

  void _ensureMatrix(Size image, Size box) {
    if (_initialized) return;
    _initialized = true;
    final initial = widget.initialRect;
    final rect = initial != null && initial.width > 1 && initial.height > 1
        ? clampCrop(initial, image.width.round(), image.height.round())
        : _centeredRect(image, box);
    _controller.value = _matrixFor(rect, box);
  }

  Rect _currentRect(Size image, Size box) {
    final inverse = Matrix4.tryInvert(_controller.value);
    if (inverse == null) return _centeredRect(image, box);
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight =
        MatrixUtils.transformPoint(inverse, Offset(box.width, box.height));
    return clampCrop(
      Rect.fromPoints(topLeft, bottomRight),
      image.width.round(),
      image.height.round(),
    );
  }

  void _done(Size image, Size box) {
    final rect = _currentRect(image, box);
    if (rect.width < 8 || rect.height < 8) return;
    Navigator.of(context).pop(rect);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(tr('裁切照片')),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    final error = _error;
    if (error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        text: trf('读取图片失败：{e}', {'e': error}),
      );
    }
    final image = _imageSize;
    if (image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(builder: (context, constraints) {
      final box = _boxOf(constraints);
      _ensureMatrix(image, box);
      final coverScale = math.max(
        box.width / image.width,
        box.height / image.height,
      );
      return Column(
        children: <Widget>[
          Expanded(
            child: Center(
              child: SizedBox(
                width: box.width,
                height: box.height,
                child: ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      InteractiveViewer(
                        key: const ValueKey('idphoto-crop-view'),
                        transformationController: _controller,
                        constrained: false,
                        boundaryMargin: EdgeInsets.zero,
                        minScale: coverScale,
                        maxScale: coverScale * 5,
                        child: SizedBox(
                          width: image.width,
                          height: image.height,
                          child: widget.previewBuilder != null
                              ? widget.previewBuilder!(image)
                              : Image.file(
                                  File(widget.imagePath),
                                  fit: BoxFit.fill,
                                  width: image.width,
                                  height: image.height,
                                  gaplessPlayback: true,
                                ),
                        ),
                      ),
                      // 画框：三分线 + 高亮描边，拖动/缩放都在框内生效。
                      IgnorePointer(
                        child: CustomPaint(
                          painter: _CropGridPainter(
                            color: Colors.white.withOpacity(0.55),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    tr('双指缩放、拖动调整取景范围'),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton(
                          key: const ValueKey('idphoto-crop-cancel'),
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white38),
                          ),
                          child: Text(tr('取消')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey('idphoto-crop-done'),
                          onPressed: () => _done(image, box),
                          child: Text(tr('使用这张')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// 裁切框内的三分线。
class _CropGridPainter extends CustomPainter {
  const _CropGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color.withOpacity(0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final dx = size.width * i / 3;
      final dy = size.height * i / 3;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), line);
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), line);
    }
    final border = Paint()
      ..color = Colors.white.withOpacity(0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(Offset.zero & size, border);
  }

  @override
  bool shouldRepaint(_CropGridPainter oldDelegate) => oldDelegate.color != color;
}
