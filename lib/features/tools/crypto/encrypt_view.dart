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

/// 加密页：文本/文件 → Base64 密文（或 .xmt 文件）。
class EncryptView extends StatefulWidget {
  const EncryptView({super.key});

  @override
  State<EncryptView> createState() => _EncryptViewState();
}

class _EncryptViewState extends State<EncryptView>
    with AutomaticKeepAliveClientMixin {
  CryptoMode _mode = CryptoMode.aes256;
  bool _useFile = false;
  final TextEditingController _text = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _pem = TextEditingController();
  PickedBytes? _file;
  bool _obscure = true;
  bool _busy = false;
  String? _result;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _text.dispose();
    _password.dispose();
    _pem.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final data = _useFile
          ? (_file == null ? null : Uint8List.fromList(_file!.bytes))
          : (_text.text.trim().isEmpty
              ? null
              : Uint8List.fromList(utf8.encode(_text.text.trim())));
      if (data == null || data.isEmpty) {
        throw CryptoException(tr('请先输入内容或选择文件'));
      }
      final Uint8List out;
      if (_mode.isRsa) {
        final pem = _pem.text;
        out = await Isolate.run(() => CryptoService.rsaEncrypt(pem, data));
      } else {
        final kind = _mode.kind!;
        final password = _password.text;
        out = await Isolate.run(
          () => CryptoService.encrypt(kind: kind, password: password, data: data),
        );
      }
      if (!mounted) return;
      setState(() => _result = base64Encode(out));
    } on CryptoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = trf('加密失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final result = _result;
    if (result == null) return;
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final stored = await AppStore.saveBytes(
        category: AppStoreCategory.other,
        name: 'encrypted-$stamp.txt',
        bytes: utf8.encode(result),
      );
      if (!mounted) return;
      showToast(context, trf('已保存到存储空间：{n}', {'n': stored.name}));
    } catch (e) {
      if (!mounted) return;
      showToast(context, trf('保存失败：{e}', {'e': '$e'}));
    }
  }

  Future<void> _generateKeys() async {
    setState(() => _busy = true);
    try {
      final pair = await Isolate.run(
        () => CryptoService.generateRsaKeyPair(bits: 2048),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _KeyPairDialog(
          privatePem: pair.$1,
          publicPem: pair.$2,
          onUsePublic: (pem) {
            _pem.text = pem;
            Navigator.of(context).pop();
          },
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = trf('生成密钥失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
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
          title: tr('算法'),
          subtitle: tr('对称算法用口令派生密钥；RSA 用公钥加密、私钥解密'),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mode in CryptoMode.values)
                  ChoiceChip(
                    key: ValueKey('crypto-mode-${mode.name}'),
                    label: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(mode.label),
                        Text(
                          mode.detail,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9,
                            color: mode == _mode
                                ? scheme.onSecondaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    selected: mode == _mode,
                    onSelected: (_) => setState(() {
                      _mode = mode;
                      _error = null;
                      _result = null;
                    }),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
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
                _result = null;
                _error = null;
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
                      _result = null;
                    });
                  }
                },
                onClear: () => setState(() => _file = null),
              )
            else
              TextField(
                key: const ValueKey('crypto-plain-input'),
                controller: _text,
                minLines: 4,
                maxLines: 10,
                decoration: InputDecoration(
                  hintText: tr('要加密的文本'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() => _result = null),
              ),
            if (_mode.isRsa) ...[
              const SizedBox(height: 8),
              SmallHint(
                text: tr('RSA 只能加密短内容（约 190 字节 / 2048 位密钥），长文本请先用 AES。'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: _mode.isRsa ? tr('公钥') : tr('口令'),
          children: [
            if (_mode.isRsa) ...[
              TextField(
                key: const ValueKey('crypto-public-pem'),
                controller: _pem,
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText: '-----BEGIN PUBLIC KEY-----',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _generateKeys,
                      icon: const Icon(Icons.vpn_key_outlined, size: 18),
                      label: Text(tr('生成密钥对')),
                    ),
                  ),
                ],
              ),
            ] else
              TextField(
                key: const ValueKey('crypto-password'),
                controller: _password,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: tr('口令'),
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
          key: const ValueKey('crypto-encrypt-run'),
          onPressed: _busy ? null : _run,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.lock_outline, size: 18),
          label: Text(tr(_busy ? '加密中…' : '加密')),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          CryptoErrorBanner(message: _error!),
        ],
        if (_result != null) ...[
          const SizedBox(height: 12),
          CryptoOutput(
            key: const ValueKey('crypto-encrypt-result'),
            value: _result!,
            label: tr('Base64 密文'),
            onCopy: () => copyWithToast(context, _result!, toast: tr('已复制密文')),
            maxLines: 12,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(tr('保存为文件')),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        SmallHint(
          text: tr('密文自带算法标识与随机 salt/IV，直接贴到「解密」页即可还原；'
              '口令不写盘、不上传，忘记后无法找回。'),
          maxLines: 3,
        ),
      ],
    );
  }
}

/// 新生成的 RSA 密钥对。
class _KeyPairDialog extends StatelessWidget {
  const _KeyPairDialog({
    required this.privatePem,
    required this.publicPem,
    required this.onUsePublic,
  });

  final String privatePem;
  final String publicPem;
  final ValueChanged<String> onUsePublic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(tr('RSA 密钥对（2048 位）')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('私钥只显示这一次，请立即复制保存；公钥用来加密，私钥用来解密。'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              CryptoOutput(
                value: publicPem,
                label: tr('公钥 PUBLIC KEY'),
                onCopy: () =>
                    copyWithToast(context, publicPem, toast: tr('已复制公钥')),
                maxLines: 6,
              ),
              const SizedBox(height: 10),
              CryptoOutput(
                value: privatePem,
                label: tr('私钥 RSA PRIVATE KEY'),
                onCopy: () =>
                    copyWithToast(context, privatePem, toast: tr('已复制私钥')),
                maxLines: 8,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('关闭')),
        ),
        FilledButton(
          onPressed: () => onUsePublic(publicPem),
          child: Text(tr('使用这个公钥')),
        ),
      ],
    );
  }
}
