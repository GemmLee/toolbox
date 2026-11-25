import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/platform/ocr.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/storage/app_files.dart';
import '../../../core/widgets/app_widgets.dart';

// 选图/识别能力已下沉到 core，这里转出一次，历史 import 不必改。
export '../../../core/platform/ocr.dart'
    show OcrImageSource, OcrImagePicker, OcrRecognizer, defaultOcrImagePicker;

typedef OcrSaver = Future<String> Function(String text);

/// 默认保存：写进存储空间，文字阅读器可直接打开继续编辑。
Future<String> defaultOcrSaver(String text) async {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final name = 'OCR_${now.year}${two(now.month)}${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}.txt';
  final stored = await AppStore.saveText(
    category: AppStoreCategory.other,
    name: name,
    content: text,
  );
  return stored.name;
}

/// OCR 文字识别：扫描图片中的文字，提取为可编辑 / 复制 / 保存的纯文本。
///
/// 识别引擎在 Android 原生侧（ML Kit 中文+拉丁 bundled 模型，离线）。
/// 页面把选图、识别、保存都做成可注入函数，widget 测试不碰真实 I/O。
class OcrPage extends StatefulWidget {
  const OcrPage({
    super.key,
    this.picker = defaultOcrImagePicker,
    this.recognizer = OcrScanner.recognize,
    this.saver = defaultOcrSaver,
  });

  final OcrImagePicker picker;
  final OcrRecognizer recognizer;
  final OcrSaver saver;

  @override
  State<OcrPage> createState() => _OcrPageState();
}

class _OcrPageState extends State<OcrPage> {
  final TextEditingController _text = TextEditingController();
  String? _imagePath;
  String? _error;
  bool _busy = false;
  int _lineCount = 0;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _scan(OcrImageSource source) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path = await widget.picker(source);
      if (path == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      if (!mounted) return;
      setState(() => _imagePath = path);
      final result = await widget.recognizer(path);
      if (!mounted) return;
      final display = result.lines.isEmpty
          ? result.text
          : assembleOcrText(result.lines);
      setState(() {
        _text.text = display;
        _lineCount = result.lines.length;
        _error = display.trim().isEmpty
            ? tr('没有识别到文字，试试更清晰的图片')
            : null;
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

  Future<void> _save() async {
    final value = _text.text;
    if (value.trim().isEmpty) {
      showToast(context, tr('识别内容为空'));
      return;
    }
    try {
      final name = await widget.saver(value);
      if (mounted) {
        showToast(context, trf('已保存到存储空间：{n}', {'n': name}));
      }
    } catch (e) {
      if (mounted) showToast(context, trf('识别失败：{e}', {'e': '$e'}));
    }
  }

  void _clear() {
    setState(() {
      _text.clear();
      _imagePath = null;
      _error = null;
      _lineCount = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showPreview = _imagePath != null && File(_imagePath!).existsSync();
    return Scaffold(
      appBar: AppBar(title: Text(tr('文字识别'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  Icon(Icons.document_scanner_outlined,
                      size: 40, color: scheme.primary),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('ocr-camera'),
                          onPressed:
                              _busy ? null : () => _scan(OcrImageSource.camera),
                          icon: const Icon(Icons.photo_camera_outlined, size: 18),
                          label: Text(tr('拍照识别')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('ocr-gallery'),
                          onPressed: _busy
                              ? null
                              : () => _scan(OcrImageSource.gallery),
                          icon: const Icon(Icons.photo_library_outlined,
                              size: 18),
                          label: Text(tr('从相册选图')),
                        ),
                      ),
                    ],
                  ),
                  if (showPreview) ...<Widget>[
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(_imagePath!),
                        height: 160,
                        width: double.infinity,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ],
                  if (_busy) ...<Widget>[
                    const SizedBox(height: 14),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    SmallHint(text: tr('识别中'), maxLines: 1),
                  ],
                ],
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: SmallHint(text: _error!, color: scheme.error),
            ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          tr('识别结果'),
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (_lineCount > 0)
                        Text(
                          trf('{n} 行', {'n': _lineCount}),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      if (_imagePath != null)
                        IconButton(
                          key: const ValueKey('ocr-rescan'),
                          tooltip: tr('重新识别'),
                          icon: const Icon(Icons.refresh, size: 20),
                          onPressed: _busy
                              ? null
                              : () => _scan(OcrImageSource.gallery),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('ocr-result'),
                    controller: _text,
                    maxLines: null,
                    minLines: 8,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      hintText: tr('识别出的文字会出现在这里，可直接修改'),
                      border: const OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SmallHint(
                    text: tr('支持中文、英文印刷体；图片端正清晰时识别更准确'),
                    maxLines: 1,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                key: const ValueKey('ocr-copy'),
                onPressed: () => copyWithToast(context, _text.text),
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                label: Text(tr('复制全文')),
              ),
              OutlinedButton.icon(
                key: const ValueKey('ocr-save'),
                onPressed: _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(tr('保存到存储空间')),
              ),
              TextButton.icon(
                key: const ValueKey('ocr-clear'),
                onPressed: _clear,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(tr('清空')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
