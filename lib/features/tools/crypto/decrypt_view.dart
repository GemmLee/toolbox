import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/storage/app_files.dart';
import '../../../core/widgets/app_widgets.dart';
import 'crypto_mode.dart';
import 'crypto_service.dart';
import 'crypto_widgets.dart';

/// 解密页：Base64 密文 / .xmt 文件 → 明文。
class DecryptView extends StatefulWidget {
  const DecryptView({super.key});

  @override
  State<DecryptView> createState() => _DecryptViewState();
}

class _DecryptViewState extends State<DecryptView>
    with AutomaticKeepAliveClientMixin {
  CryptoMode _mode = CryptoMode.aes256;
  bool _autoDetect = true;
  bool _useFile = false;
  final TextEditingController _cipher = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _pem = TextEditingController();
  PickedBytes? _file;
  bool _obscure = true;
  bool _busy = false;
  String? _plain;
  Uint8List? _plainBytes;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _cipher.dispose();
    _password.dispose();
    _pem.dispose();
    super.dispose();
  }

  /// 解析输入：Base64 文本或文件字节。
  Uint8List? _readCipher() {
    if (_useFile) {
      final file = _file;
      if (file == null) return null;
      final bytes = Uint8List.fromList(file.bytes);
      // 选择的可能是文本形式的 Base64（.txt），也可能是二进制 .xmt
      if (CryptoService.detectKind(bytes) != null) return bytes;
      return _tryBase64(utf8.decode(bytes, allowMalformed: true));
    }
    return _tryBase64(_cipher.text);
  }

  static Uint8List? _tryBase64(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'\s'), '');
    if (cleaned.isEmpty) return null;
    try {
      return base64Decode(cleaned);
    } catch (_) {
      return null;
    }
  }

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _plain = null;
      _plainBytes = null;
    });
    try {
      final payload = _readCipher();
      if (payload == null || payload.isEmpty) {
        throw CryptoException(tr('请输入 Base64 密文，或选择 .xmt 文件'));
      }
      final detected = CryptoService.detectKind(payload);
      final mode = _autoDetect && detected != null
          ? (CryptoMode.fromKind(detected) ?? _mode)
          : _mode;
      final Uint8List out;
      if (mode.isRsa) {
        // RSA 密文没有自定义头，只能按选择的算法解
        final pem = _pem.text;
        out = await Isolate.run(() => CryptoService.rsaDecrypt(pem, payload));
      } else {
        final kind = mode.kind!;
        final password = _password.text;
        out = await Isolate.run(
          () => CryptoService.decrypt(kind: kind, password: password, data: payload),
        );
      }
      if (!mounted) return;
      setState(() {
        _plainBytes = out;
        _plain = _decodeText(out);
      });
    } on CryptoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = trf('解密失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 能按 UTF-8 解出来就显示文本，否则给出二进制提示。
  static String? _decodeText(Uint8List bytes) {
    try {
      final text = utf8.decode(bytes);
      // 控制字符过多说明其实是二进制
      final bad = text.runes
          .where((c) => c < 0x09 || (c > 0x0D && c < 0x20))
          .length;
      if (text.isNotEmpty && bad / text.length > 0.05) return null;
      return text;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    final bytes = _plainBytes;
    if (bytes == null) return;
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final name = _plain != null
          ? 'decrypted-$stamp.txt'
          : 'decrypted-$stamp.bin';
      final stored = await AppStore.saveBytes(
        category: AppStoreCategory.other,
        name: name,
        bytes: bytes,
      );
      if (!mounted) return;
      showToast(context, trf('已保存到存储空间：{n}', {'n': stored.name}));
    } catch (e) {
      if (!mounted) return;
      showToast(context, trf('保存失败：{e}', {'e': '$e'}));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        SectionCard(
          title: tr('密文'),
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  label: Text(tr('Base64 文本')),
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
                _error = null;
                _plain = null;
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
                      _plain = null;
                      _error = null;
                    });
                  }
                },
                onClear: () => setState(() => _file = null),
              )
            else
              TextField(
                key: const ValueKey('crypto-cipher-input'),
                controller: _cipher,
                minLines: 4,
                maxLines: 10,
                decoration: InputDecoration(
                  hintText: tr('粘贴 Base64 密文'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() => _plain = null),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: tr('算法'),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _autoDetect,
              onChanged: (v) => setState(() => _autoDetect = v),
              title: Text(tr('自动识别对称算法'), style: theme.textTheme.bodyMedium),
            ),
            const SizedBox(height: 4),
            Opacity(
              opacity: _autoDetect ? 0.55 : 1,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mode in CryptoMode.values)
                    ChoiceChip(
                      key: ValueKey('crypto-decrypt-mode-${mode.name}'),
                      label: Text(mode.label),
                      selected: mode == _mode,
                      onSelected: _autoDetect && !mode.isRsa
                          ? null
                          : (_) => setState(() => _mode = mode),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: _mode.isRsa ? tr('私钥') : tr('口令'),
          children: [
            if (_mode.isRsa)
              TextField(
                key: const ValueKey('crypto-private-pem'),
                controller: _pem,
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText: '-----BEGIN RSA PRIVATE KEY-----',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              )
            else
              TextField(
                key: const ValueKey('crypto-password'),
                controller: _password,
                obscureText: _obscure,
                decoration: InputDecoration(
                  hintText: tr('与加密时相同的口令'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    tooltip: _obscure ? tr('显示') : tr('隐藏'),
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const ValueKey('crypto-decrypt-run'),
          onPressed: _busy ? null : _run,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.lock_open, size: 18),
          label: Text(tr(_busy ? '解密中…' : '解密')),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          CryptoErrorBanner(message: _error!),
        ],
        if (_plainBytes != null) ...[
          const SizedBox(height: 12),
          if (_plain != null)
            CryptoOutput(
              key: const ValueKey('crypto-decrypt-result'),
              value: _plain!,
              label: tr('明文'),
              onCopy: () => copyWithToast(context, _plain!, toast: tr('已复制明文')),
              maxLines: 12,
            )
          else
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                trf('解密成功，内容为二进制（{n} 字节），可保存为文件。', {
                  'n': '${_plainBytes!.length}',
                }),
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(tr('保存为文件')),
          ),
        ],
        const SizedBox(height: 12),
        SmallHint(
          text: tr('口令错误、算法不符或密文被改动都会解密失败；'
              '本工具不做长度填充以外的数据校验，重要数据请先备份。'),
          maxLines: 3,
        ),
      ],
    );
  }
}
