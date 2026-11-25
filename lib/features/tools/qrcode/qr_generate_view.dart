import 'dart:ui' as ui;

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart' as qr;
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/storage/app_files.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/mini_segmented.dart';

/// 可生成的码类型。
class CodeKind {
  const CodeKind({
    required this.id,
    required this.label,
    required this.hint,
    this.barcode,
    this.qr = false,
  });

  final String id;
  final String label;

  /// 输入示例，用作 hint。
  final String hint;

  /// 一维码/二维条码对应的 barcode 实例；二维码为 null。
  final Barcode? barcode;
  final bool qr;

  /// 二维码类在前，常用一维条码在后。
  static final List<CodeKind> all = <CodeKind>[
    const CodeKind(
      id: 'qr',
      label: '二维码',
      hint: 'https://example.com',
      qr: true,
    ),
    CodeKind(
      id: 'datamatrix',
      label: 'Data Matrix',
      hint: 'DATA MATRIX',
      barcode: Barcode.dataMatrix(),
    ),
    CodeKind(
      id: 'code128',
      label: 'Code 128',
      hint: 'ABC-123456',
      barcode: Barcode.code128(),
    ),
    CodeKind(
      id: 'code39',
      label: 'Code 39',
      hint: 'CODE39',
      barcode: Barcode.code39(),
    ),
    CodeKind(
      id: 'ean13',
      label: 'EAN-13',
      hint: '6901234567892',
      barcode: Barcode.ean13(),
    ),
    CodeKind(
      id: 'ean8',
      label: 'EAN-8',
      hint: '6901234',
      barcode: Barcode.ean8(),
    ),
  ];
}

/// 生成页：二维码与常见一维/二维条码。
class QrGenerateView extends StatefulWidget {
  const QrGenerateView({
    super.key,
    required this.controller,
    required this.kind,
    required this.onKindChanged,
    this.previewKey,
  });

  final TextEditingController controller;
  final CodeKind kind;
  final ValueChanged<CodeKind> onKindChanged;
  final GlobalKey? previewKey;

  @override
  State<QrGenerateView> createState() => _QrGenerateViewState();
}

class _QrGenerateViewState extends State<QrGenerateView> {
  final GlobalKey _fallbackKey = GlobalKey();
  int _level = QrErrorCorrectLevel.M;
  bool _saving = false;
  String? _error;

  GlobalKey get _previewKey => widget.previewKey ?? _fallbackKey;

  String get _data => widget.controller.text.trim();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_revalidate);
    _error = _computeError();
  }

  @override
  void didUpdateWidget(covariant QrGenerateView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_revalidate);
      widget.controller.addListener(_revalidate);
    }
    if (oldWidget.kind.id != widget.kind.id) _revalidate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_revalidate);
    super.dispose();
  }

  void _revalidate() {
    if (!mounted) return;
    setState(() => _error = _computeError());
  }

  /// 生成能力自检：二维码看容量，一维码看编码规则。
  String? _computeError() {
    final data = _data;
    if (data.isEmpty) return null;
    if (widget.kind.qr) {
      // qr_flutter 的 painter 在超长时才抛异常，这里先自检一次容量
      try {
        qr.QrImage(
          qr.QrCode.fromData(data: data, errorCorrectLevel: _level),
        );
      } catch (_) {
        return tr('内容过长，无法生成二维码');
      }
      return null;
    }
    final fixed = _fixedLengthError(data);
    if (fixed != null) return fixed;
    try {
      final square = _isSquare;
      widget.kind.barcode!.make(
        data,
        width: square ? 160 : 300,
        height: square ? 160 : 100,
      );
    } catch (_) {
      return trf('内容不符合 {n} 的编码规则', {'n': widget.kind.label});
    }
    return null;
  }

  /// Data Matrix 这类矩阵码必须是正方形，否则模块被拉成长方形、
  /// 打印或贴屏后扫不出来。
  bool get _isSquare => widget.kind.id == 'datamatrix';

  /// EAN/UPC/ITF 有固定长度与校验位要求，先给出更明确的提示。
  String? _fixedLengthError(String data) {
    final digits = RegExp(r'^\d+$').hasMatch(data);
    final need = switch (widget.kind.id) {
      'ean13' => 13,
      'ean8' => 8,
      'upca' => 12,
      'itf14' => 14,
      _ => 0,
    };
    if (need == 0) return null;
    if (!digits || data.length != need) {
      return trf('{n} 需要 {c} 位数字', {
        'n': widget.kind.label,
        'c': '$need',
      });
    }
    return null;
  }

  Future<void> _paste() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final value = clip?.text?.trim();
    if (value == null || value.isEmpty) {
      if (mounted) showToast(context, tr('剪贴板里没有文字'));
      return;
    }
    widget.controller.text = value;
    widget.controller.selection = TextSelection.collapsed(offset: value.length);
  }

  Future<void> _save() async {
    final data = _data;
    if (data.isEmpty || _error != null || _saving) return;
    setState(() => _saving = true);
    try {
      final boundary = _previewKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('尚未渲染');
      final image = await boundary.toImage(pixelRatio: 4);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('导出图片失败');
      final now = DateTime.now();
      final stamp = '${now.year}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}-'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}'
          '${now.second.toString().padLeft(2, '0')}';
      final stored = await AppStore.saveBytes(
        category: AppStoreCategory.other,
        name: '${widget.kind.id}-$stamp.png',
        bytes: bytes.buffer.asUint8List(),
      );
      if (!mounted) return;
      showToast(context, trf('已保存到存储空间：{n}', {'n': stored.name}));
    } catch (e) {
      if (!mounted) return;
      showToast(context, trf('保存失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final empty = _data.isEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('qr-input'),
                  controller: widget.controller,
                  minLines: 2,
                  maxLines: 6,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: trf('输入内容，例如 {s}', {'s': widget.kind.hint}),
                    border: InputBorder.none,
                    isDense: true,
                    suffixIcon: empty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: tr('清空'),
                            onPressed: widget.controller.clear,
                          ),
                  ),
                ),
                const Divider(height: 16),
                Text(
                  tr('码类型'),
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final kind in CodeKind.all)
                      ChoiceChip(
                        key: ValueKey('qr-kind-${kind.id}'),
                        label: Text(kind.label),
                        selected: widget.kind.id == kind.id,
                        onSelected: (_) => widget.onKindChanged(kind),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                if (widget.kind.qr) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        tr('容错级别'),
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(width: 10),
                      MiniSegmented<int>(
                        key: const ValueKey('qr-error-level'),
                        options: <MiniSegmentedOption<int>>[
                          MiniSegmentedOption<int>(
                            value: QrErrorCorrectLevel.L,
                            label: tr('低'),
                          ),
                          MiniSegmentedOption<int>(
                            value: QrErrorCorrectLevel.M,
                            label: tr('中'),
                          ),
                          MiniSegmentedOption<int>(
                            value: QrErrorCorrectLevel.Q,
                            label: tr('较高'),
                          ),
                          MiniSegmentedOption<int>(
                            value: QrErrorCorrectLevel.H,
                            label: tr('高'),
                          ),
                        ],
                        selected: _level,
                        onChanged: (value) {
                          _level = value;
                          _revalidate();
                        },
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '${tr('字符数')} ${widget.controller.text.length} · '
                  '${tr('字节数')} ${_byteLength(widget.controller.text)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // 码图固定白底黑块：深色模式下也能被正常扫描
                RepaintBoundary(
                  key: _previewKey,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _preview(theme, empty),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: empty
                            ? null
                            : () => copyWithToast(
                                  context,
                                  _data,
                                  toast: tr('已复制内容'),
                                ),
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: Text(tr('复制内容')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed:
                            (empty || _error != null || _saving) ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download_rounded, size: 18),
                        label: Text(tr('保存图片')),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SmallHint(
                  text: tr('图片会保存到「用户 → 存储空间 → 存储文件」，可在那里导出或分享。'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        SmallHint(
          text: widget.kind.qr
              ? tr('提示：容错越高，二维码越密但越耐污损；短链或纯文本用「中」即可。')
              : _isSquare
                  ? tr('提示：Data Matrix 是矩阵码，适合小面积标识，比一维码能装下多得多的内容。')
                  : tr('提示：一维条码只适合短编号（数字或大写字母），内容长请改用二维码。'),
          maxLines: 3,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _paste,
            icon: const Icon(Icons.content_paste, size: 16),
            label: Text(tr('从剪贴板粘贴')),
          ),
        ),
      ],
    );
  }

  Widget _preview(ThemeData theme, bool empty) {
    final placeholder = SizedBox(
      width: 240,
      height: 160,
      child: Center(
        child: Text(
          tr('输入内容后自动生成'),
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54),
        ),
      ),
    );
    if (empty) return placeholder;
    if (_error != null) {
      return SizedBox(
        width: 240,
        height: 160,
        child: Center(
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54),
          ),
        ),
      );
    }
    if (widget.kind.qr) {
      return QrImageView(
        data: _data,
        version: QrVersions.auto,
        size: 220,
        gapless: true,
        backgroundColor: Colors.white,
        errorCorrectionLevel: _level,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
        errorStateBuilder: (context, err) => SizedBox(
          width: 220,
          height: 160,
          child: Center(
            child: Text(
              tr('内容过长，无法生成二维码'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54),
            ),
          ),
        ),
      );
    }
    final square = _isSquare;
    return BarcodeWidget(
      key: ValueKey('barcode-${widget.kind.id}'),
      barcode: widget.kind.barcode!,
      data: _data,
      width: square ? 168 : 280,
      height: square ? 168 : 120,
      drawText: !square,
      color: Colors.black,
      backgroundColor: Colors.white,
      errorBuilder: (context, error) => SizedBox(
        width: 240,
        height: 120,
        child: Center(
          child: Text(
            tr('内容不符合该码的编码规则'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54),
          ),
        ),
      ),
    );
  }

  static int _byteLength(String text) {
    var bytes = 0;
    for (final rune in text.runes) {
      bytes += rune <= 0x7F
          ? 1
          : rune <= 0x7FF
              ? 2
              : rune <= 0xFFFF
                  ? 3
                  : 4;
    }
    return bytes;
  }
}
