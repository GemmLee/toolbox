import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import 'crypto_service.dart';
import 'crypto_widgets.dart';

/// 哈希页：MD5 / SHA-1 / SHA-256 / SHA-512 + HMAC。
class HashView extends StatefulWidget {
  const HashView({super.key});

  @override
  State<HashView> createState() => _HashViewState();
}

class _HashViewState extends State<HashView>
    with AutomaticKeepAliveClientMixin {
  bool _useFile = false;
  final TextEditingController _text = TextEditingController();
  final TextEditingController _hmacKey = TextEditingController();
  PickedBytes? _file;
  bool _busy = false;
  String? _error;
  Map<HashKind, String> _digests = <HashKind, String>{};
  String? _hmac;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _text.dispose();
    _hmacKey.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Uint8List data;
      if (_useFile) {
        final file = _file;
        if (file == null) throw CryptoException(tr('请先选择文件'));
        data = Uint8List.fromList(file.bytes);
      } else {
        if (_text.text.isEmpty) throw CryptoException(tr('请先输入文本'));
        data = Uint8List.fromList(utf8.encode(_text.text));
      }
      final key = _hmacKey.text;
      final result = await Isolate.run(() {
        final digests = <String, String>{};
        for (final kind in HashKind.values) {
          digests[kind.name] = CryptoService.hashBytes(data, kind);
        }
        final hmac = key.isEmpty
            ? null
            : CryptoService.hmacBytes(data, key, HashKind.sha256);
        return (digests, hmac);
      });
      if (!mounted) return;
      setState(() {
        _digests = <HashKind, String>{
          for (final kind in HashKind.values)
            kind: result.$1[kind.name] ?? '',
        };
        _hmac = result.$2;
      });
    } on CryptoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = trf('计算失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        SectionCard(
          title: tr('内容'),
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  label: Text(tr('文本')),
                  icon: const Icon(Icons.notes, size: 16),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text(tr('文件')),
                  icon: const Icon(Icons.folder_open, size: 16),
                ),
              ],
              selected: <bool>{_useFile},
              onSelectionChanged: (v) => setState(() {
                _useFile = v.first;
                _digests = <HashKind, String>{};
                _hmac = null;
              }),
            ),
            const SizedBox(height: 10),
            if (_useFile)
              PickedFileTile(
                file: _file,
                onPick: () async {
                  final picked = await pickBytesFile();
                  if (picked != null && mounted) {
                    setState(() {
                      _file = picked;
                      _digests = <HashKind, String>{};
                      _hmac = null;
                    });
                  }
                },
                onClear: () => setState(() => _file = null),
              )
            else
              TextField(
                key: const ValueKey('hash-input'),
                controller: _text,
                minLines: 4,
                maxLines: 10,
                decoration: InputDecoration(
                  hintText: tr('要计算摘要的文本'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: tr('HMAC 密钥'),
          children: [
            TextField(
              key: const ValueKey('hash-hmac-key'),
              controller: _hmacKey,
              decoration: InputDecoration(
                hintText: tr('可选：HMAC 密钥'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const ValueKey('hash-run'),
          onPressed: _busy ? null : _run,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.tag, size: 18),
          label: Text(tr(_busy ? '计算中…' : '计算摘要')),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          CryptoErrorBanner(message: _error!),
        ],
        if (_digests.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final kind in HashKind.values) ...[
            CryptoOutput(
              key: ValueKey('hash-result-${kind.name}'),
              value: _digests[kind] ?? '',
              label: kind.label,
              onCopy: () => copyWithToast(
                context,
                _digests[kind] ?? '',
                toast: trf('已复制 {n}', {'n': kind.label}),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
          ],
          if (_hmac != null)
            CryptoOutput(
              key: const ValueKey('hash-result-hmac'),
              value: _hmac!,
              label: 'HMAC-SHA256',
              onCopy: () =>
                  copyWithToast(context, _hmac!, toast: tr('已复制 HMAC')),
              maxLines: 3,
            ),
        ],
        const SizedBox(height: 12),
        SmallHint(
          text: tr('摘要不可逆，只用于校验一致性；MD5 / SHA-1 已不适合用于安全场景。'),
        ),
      ],
    );
  }
}
