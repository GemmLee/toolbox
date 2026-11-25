import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 水印版式：平铺 / 居中 / 角落。
enum WatermarkType { tile, center, corner }

/// 角落位置：多行自定义水印（含实时信息）落在图片的哪个角。
enum WatermarkCorner { topLeft, topRight, bottomLeft, bottomRight }

/// 水印字段类型：自定义文本，或拍照时的实时信息。
/// 经纬度作为一个整体字段 [geo]，拍照时一并定格。
enum WatermarkField {
  custom,
  date,
  time,
  temperature,
  altitude,
  geo,
}

/// 拍照瞬间的实时信息快照。包含实时字段的水印须在拍照前配置，
/// 拍照时把当时的值定格进 [WatermarkSnapshot]，再随水印一起烧录。
class WatermarkSnapshot {
  const WatermarkSnapshot({
    this.dateTime,
    this.temperature,
    this.altitude,
    this.latitude,
    this.longitude,
  });

  final DateTime? dateTime;
  final double? temperature;
  final double? altitude;
  final double? latitude;
  final double? longitude;

  static WatermarkSnapshot now({
    double? temperature,
    double? altitude,
    double? latitude,
    double? longitude,
  }) {
    return WatermarkSnapshot(
      dateTime: DateTime.now(),
      temperature: temperature,
      altitude: altitude,
      latitude: latitude,
      longitude: longitude,
    );
  }
}

/// 一行水印：字段类型 + 自定义文本（仅 [WatermarkField.custom] 使用）。
class WatermarkItem {
  const WatermarkItem({
    required this.field,
    this.customText = '',
    this.id = '',
  });

  final WatermarkField field;
  final String customText;

  /// 页面用稳定 id 维持控件身份（拖动排序 / 文本输入不丢焦点）。
  final String id;

  /// 依据快照解析成实际显示的文本；无数据时该行返回空串（渲染时跳过）。
  String resolve(WatermarkSnapshot snapshot) {
    switch (field) {
      case WatermarkField.custom:
        return customText.trim();
      case WatermarkField.date:
        final d = snapshot.dateTime;
        if (d == null) return '';
        return '${d.year}-${_two(d.month)}-${_two(d.day)}';
      case WatermarkField.time:
        final d = snapshot.dateTime;
        if (d == null) return '';
        return '${_two(d.hour)}:${_two(d.minute)}';
      case WatermarkField.temperature:
        final t = snapshot.temperature;
        return t == null ? '' : '${t.toStringAsFixed(1)}°C';
      case WatermarkField.altitude:
        final a = snapshot.altitude;
        return a == null ? '' : '海拔 ${a.toStringAsFixed(0)}m';
      case WatermarkField.geo:
        final lat = snapshot.latitude;
        final lng = snapshot.longitude;
        if (lat == null || lng == null) return '';
        return '${lat.toStringAsFixed(5)}°N ${lng.toStringAsFixed(5)}°E';
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

/// 角落水印的一行：同一行内可放多个字段，渲染时用竖线分隔。
class WatermarkRow {
  const WatermarkRow({required this.items, this.id = ''});

  /// 最多两个字段；空行在渲染时跳过。
  final List<WatermarkItem> items;

  /// 页面用稳定 id 维持拖动排序时的行身份。
  final String id;

  WatermarkRow copyWith({List<WatermarkItem>? items}) =>
      WatermarkRow(items: items ?? this.items, id: id);
}

/// 解析一行水印：缺失实时数据的字段自动跳过，再用 `|` 连接。
String resolveWatermarkRow(WatermarkRow row, WatermarkSnapshot snapshot) =>
    row.items
        .map((item) => item.resolve(snapshot).trim())
        .where((text) => text.isNotEmpty)
        .join(' | ');

/// 水印样式参数（纯数据，可单测）。
class WatermarkSettings {
  const WatermarkSettings({
    required this.text,
    this.type = WatermarkType.tile,
    this.sizeFactor = 0.05,
    this.density = 1.0,
    this.angleDeg = -30,
    this.opacity = 0.35,
    this.darkText = false,
    this.fontFamily,
    this.rows = const <WatermarkRow>[],
    this.corner = WatermarkCorner.bottomRight,
    this.outline = false,
  });

  /// 单条水印文字（平铺 / 居中版式使用，或作为多行模式的兜底）。
  final String text;

  final WatermarkType type;

  /// 字号相对图片短边的比例（0.02 ~ 0.12）。
  final double sizeFactor;

  /// 平铺密度：间距 = 水印尺寸 × (1 + density)，越大越稀（0.4 ~ 2.5）。
  final double density;

  /// 斜率（旋转角，度，-90 ~ 90，负数表示左低右高）。
  final double angleDeg;

  /// 透明度（0.05 ~ 1）。
  final double opacity;

  /// true 黑字 / false 白字。
  final bool darkText;

  /// 水印字体（应用内置注册的字体 family 名，null 用系统默认）。
  final String? fontFamily;

  /// 角落水印行（最多三行，每行最多两个字段）。
  /// 为空时回退到 [text] 单条渲染，保持平铺 / 居中的旧行为。
  final List<WatermarkRow> rows;

  /// 角落位置（多行角落水印的落点）。
  final WatermarkCorner corner;

  /// 是否为文字描边：在文字下先画一圈对比色轮廓，避免与照片背景同色看不清。
  final bool outline;

  WatermarkSettings copyWith({
    String? text,
    WatermarkType? type,
    double? sizeFactor,
    double? density,
    double? angleDeg,
    double? opacity,
    bool? darkText,
    String? fontFamily,
    List<WatermarkRow>? rows,
    WatermarkCorner? corner,
    bool? outline,
  }) {
    return WatermarkSettings(
      text: text ?? this.text,
      type: type ?? this.type,
      sizeFactor: sizeFactor ?? this.sizeFactor,
      density: density ?? this.density,
      angleDeg: angleDeg ?? this.angleDeg,
      opacity: opacity ?? this.opacity,
      darkText: darkText ?? this.darkText,
      fontFamily: fontFamily ?? this.fontFamily,
      rows: rows ?? this.rows,
      corner: corner ?? this.corner,
      outline: outline ?? this.outline,
    );
  }
}

/// 计算平铺水印的落点（纯逻辑，可单测）。
///
/// 以图片中心为轴，把砖墙式网格整体旋转 [angleDeg]，
/// 网格覆盖范围按对角线扩展，保证旋转后铺满整图。
List<Offset> computeTilePositions({
  required Size size,
  required Size itemSize,
  required double density,
  required double angleDeg,
}) {
  final stepX = math.max(itemSize.width * (1 + density), itemSize.width + 8);
  final stepY = math.max(itemSize.height * (0.7 + density), 8.0);
  final rad = angleDeg * math.pi / 180;
  final cos = math.cos(rad);
  final sin = math.sin(rad);
  final center = size.center(Offset.zero);
  final half =
      math.sqrt(size.width * size.width + size.height * size.height) / 2;

  Offset rotate(Offset p) {
    final dx = p.dx - center.dx;
    final dy = p.dy - center.dy;
    return center + Offset(dx * cos - dy * sin, dx * sin + dy * cos);
  }

  final margin = itemSize.longestSide;
  final positions = <Offset>[];
  var row = 0;
  for (var y = -half; y <= half + stepY; y += stepY, row++) {
    // 奇数行错开半个步长，砖墙排布更自然。
    final shift = row.isOdd ? stepX / 2 : 0.0;
    for (var x = -half; x <= half + stepX; x += stepX) {
      final p = rotate(center + Offset(x + shift, y));
      if (p.dx >= -margin &&
          p.dx <= size.width + margin &&
          p.dy >= -margin &&
          p.dy <= size.height + margin) {
        positions.add(p);
      }
    }
  }
  return positions;
}

/// 计算角落锚点的左上角坐标（多行水印从此处向内排布）。
Offset computeCornerOrigin(Size size, Size blockSize, WatermarkCorner corner) {
  const marginRatio = 0.04;
  final mx = size.width * marginRatio;
  final my = size.height * marginRatio;
  return switch (corner) {
    WatermarkCorner.topLeft => Offset(mx, my),
    WatermarkCorner.topRight => Offset(size.width - mx - blockSize.width, my),
    WatermarkCorner.bottomLeft =>
      Offset(mx, size.height - my - blockSize.height),
    WatermarkCorner.bottomRight => Offset(
        size.width - mx - blockSize.width, size.height - my - blockSize.height),
  };
}

/// 测量单个水印的排版尺寸。
Size measureWatermark(String text, double fontSize) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        letterSpacing: fontSize * 0.08,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  return Size(tp.width, tp.height);
}

/// 把水印文字画到 [canvas] 上（不画底图），底图与水印共用坐标系。
///
/// [baseStyle] 只取 fontFamily / fontFeatures 等文字属性，颜色、字号、
/// 粗细由样式参数决定，保证预览与导出渲染一致。
/// [snapshot] 为实时信息快照；多行字段水印按它解析文本。
void paintWatermark(
  Canvas canvas,
  Size size,
  WatermarkSettings settings, {
  TextStyle? baseStyle,
  WatermarkSnapshot snapshot = const WatermarkSnapshot(),
}) {
  final fontSize = math.min(size.width, size.height) * settings.sizeFactor;
  if (fontSize < 4) return;
  final color = (settings.darkText ? Colors.black : Colors.white)
      .withOpacity(settings.opacity.clamp(0.0, 1.0));
  final base = baseStyle ?? const TextStyle();
  // 样式里的字体优先；没有则回退到 baseStyle 的字体（通常为系统默认）。
  final fontFamily = (settings.fontFamily?.trim().isNotEmpty ?? false)
      ? settings.fontFamily!.trim()
      : base.fontFamily;
  final style = base.copyWith(
    fontSize: fontSize,
    color: color,
    fontWeight: FontWeight.w600,
    letterSpacing: fontSize * 0.08,
    fontFamily: fontFamily,
  );

  // 描边用反色（白字黑边、黑字白边），宽度随字号缩放。
  final strokeStyle = style.copyWith(
    color: null,
    foreground: Paint()
      ..style = PaintingStyle.stroke
      ..color = (settings.darkText ? Colors.white : Colors.black)
          .withOpacity(settings.opacity.clamp(0.0, 1.0))
      ..strokeWidth = math.max(1.0, fontSize * 0.09)
      ..strokeJoin = StrokeJoin.round,
  );
  final strokeCache = <String, TextPainter>{};

  /// 描边先画、文字后画，保证所有版式的轮廓一致。
  void paintText(TextPainter painter, String text, Offset offset) {
    if (settings.outline) {
      final stroke = strokeCache.putIfAbsent(
        text,
        () => TextPainter(
          text: TextSpan(text: text, style: strokeStyle),
          textDirection: TextDirection.ltr,
        )..layout(),
      );
      stroke.paint(canvas, offset);
    }
    painter.paint(canvas, offset);
  }

  // 多行角落模式：每行可含多个字段，按行落在指定角落。
  if (settings.type == WatermarkType.corner && settings.rows.isNotEmpty) {
    final lines = settings.rows
        .map((row) => resolveWatermarkRow(row, snapshot))
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return;
    final painters = lines
        .map((line) => TextPainter(
              text: TextSpan(text: line, style: style),
              textDirection: TextDirection.ltr,
            )..layout())
        .toList();
    final lineHeight = fontSize * 1.35;
    final blockWidth = painters.map((p) => p.width).reduce(math.max);
    final blockHeight = lineHeight * painters.length;
    final origin = computeCornerOrigin(
        size, Size(blockWidth, blockHeight), settings.corner);
    final alignRight = settings.corner == WatermarkCorner.topRight ||
        settings.corner == WatermarkCorner.bottomRight;
    for (var i = 0; i < painters.length; i++) {
      final dx = alignRight ? blockWidth - painters[i].width : 0.0;
      paintText(painters[i], lines[i], origin.translate(dx, i * lineHeight));
    }
    return;
  }

  // 单条模式（平铺 / 居中 / 旧角落行为）。
  if (settings.text.trim().isEmpty) return;
  final tp = TextPainter(
    text: TextSpan(text: settings.text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final rad = settings.angleDeg * math.pi / 180;

  void drawAt(Offset center) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rad);
    paintText(tp, settings.text, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  switch (settings.type) {
    case WatermarkType.tile:
      for (final p in computeTilePositions(
        size: size,
        itemSize: Size(tp.width, tp.height),
        density: settings.density,
        angleDeg: settings.angleDeg,
      )) {
        drawAt(p);
      }
    case WatermarkType.center:
      drawAt(size.center(Offset.zero));
    case WatermarkType.corner:
      const marginRatio = 0.04;
      final mx = size.width * marginRatio + tp.width / 2;
      final my = size.height * marginRatio + tp.height / 2;
      drawAt(Offset(size.width - mx, size.height - my));
  }
}

/// 把水印渲染到整图并导出为新 [ui.Image]（原分辨率）。
Future<ui.Image> renderWatermarked(
  ui.Image source,
  WatermarkSettings settings, {
  TextStyle? baseStyle,
  WatermarkSnapshot snapshot = const WatermarkSnapshot(),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImage(source, Offset.zero, Paint());
  paintWatermark(
    canvas,
    Size(source.width.toDouble(), source.height.toDouble()),
    settings,
    baseStyle: baseStyle,
    snapshot: snapshot,
  );
  final picture = recorder.endRecording();
  return picture.toImage(source.width, source.height);
}
