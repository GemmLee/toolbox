import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import 'barcode_decode.dart';

/// 识别页：拍照或从相册选图，离线解码二维码与常见一维/二维条码。
class QrScanView extends StatefulWidget {
  const QrScanView({super.key, required this.onUseText});

  /// 把识别结果填回「生成」页。
  final ValueChanged<String> onUseText;

  @override
  State<QrScanView> createState() => _QrScanViewState();
}

class _QrScanViewState extends State<QrScanView> {
  final ImagePicker _picker = ImagePicker();
  bool _busy = false;
  BarcodeScanResult? _result;
  Uint8List? _thumb;
  String? _error;

  Future<void> _pick(ImageSource source) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 2400,
        imageQuality: 95,
      );
      if (file == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final bytes = await file.readAsBytes();
      final result = await decodeBarcodeImage(bytes);
      if (!mounted) return;
      setState(() {
        _thumb = bytes;
        _result = result;
        _error = result == null ? tr('没有识别到二维码或条码，试试更清晰的图或让码占满画面') : null;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = trf('识别失败：{e}', {'e': '$e'});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = _result;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Icon(Icons.qr_code_scanner, size: 44, color: scheme.primary),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey('qr-scan-camera'),
                        onPressed:
                            _busy ? null : () => _pick(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined, size: 18),
                        label: Text(tr('拍照识别')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('qr-scan-gallery'),
                        onPressed:
                            _busy ? null : () => _pick(ImageSource.gallery),
                        icon:
                            const Icon(Icons.photo_library_outlined, size: 18),
                        label: Text(tr('从相册选择')),
                      ),
                    ),
                  ],
                ),
                if (_busy) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(minHeight: 3),
                  const SizedBox(height: 6),
                  Text(
                    tr('正在识别…'),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_thumb != null) ...[
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: Image.memory(
                    _thumb!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
                if (result != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                result.formatLabel,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${result.text.length} ${tr('字符')}',
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SelectableText(
                          result.text,
                          key: const ValueKey('qr-scan-result'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.5,
                            fontFamily:
                                result.text.length > 40 ? null : 'monospace',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => copyWithToast(
                                  context,
                                  result.text,
                                  toast: tr('已复制识别结果'),
                                ),
                                icon: const Icon(Icons.copy_rounded, size: 18),
                                label: Text(tr('复制')),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () => widget.onUseText(result.text),
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                label: Text(tr('拿去生成')),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          HintBanner(
            text: _error!,
            icon: Icons.error_outline,
            color: scheme.error,
          ),
        ],
        const SizedBox(height: 12),
        SmallHint(
          text: tr(
              '支持 QR Code、Code 128/39/93、EAN-13/8、UPC、ITF、PDF417、Data Matrix、Aztec；'
              '识别在手机本地完成，图片不会上传。'),
          maxLines: 3,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              final clip = await Clipboard.getData(Clipboard.kTextPlain);
              final value = clip?.text?.trim();
              if (value == null || value.isEmpty) {
                if (context.mounted) showToast(context, tr('剪贴板里没有文字'));
                return;
              }
              widget.onUseText(value);
            },
            icon: const Icon(Icons.content_paste, size: 16),
            label: Text(tr('把剪贴板内容拿去生成')),
          ),
        ),
      ],
    );
  }
}
