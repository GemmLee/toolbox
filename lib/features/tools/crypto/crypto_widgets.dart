import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../core/settings/tool_texts.dart';

/// 选中的本地文件内容。
class PickedBytes {
  const PickedBytes({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;

  int get size => bytes.length;
}

/// 选一个文件并读成字节（限制 24 MB，避免一次读爆内存）。
Future<PickedBytes?> pickBytesFile({List<String>? extensions}) async {
  final result = await FilePicker.platform.pickFiles(
    type: extensions == null || extensions.isEmpty
        ? FileType.any
        : FileType.custom,
    allowedExtensions: extensions,
    withData: true,
  );
  final file = result?.files.single;
  final bytes = file?.bytes;
  if (file == null || bytes == null) return null;
  return PickedBytes(name: file.name, bytes: bytes);
}

/// 文件选择行：文件名 + 大小 + 重新选择/清除。
class PickedFileTile extends StatelessWidget {
  const PickedFileTile({
    super.key,
    required this.file,
    required this.onPick,
    this.onClear,
  });

  final PickedBytes? file;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final picked = file;
    return Row(
      children: [
        Icon(Icons.insert_drive_file_outlined, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            picked == null
                ? tr('未选择文件')
                : '${picked.name} · ${formatFileSize(picked.size)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: picked == null ? scheme.onSurfaceVariant : null,
              fontWeight: picked == null ? null : FontWeight.w600,
            ),
          ),
        ),
        if (picked != null && onClear != null)
          IconButton(
            tooltip: tr('清除'),
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClear,
          ),
        TextButton(onPressed: onPick, child: Text(tr('选择文件'))),
      ],
    );
  }
}

/// 结果输出块：等宽可选文本 + 复制。
class CryptoOutput extends StatelessWidget {
  const CryptoOutput({
    super.key,
    required this.value,
    required this.onCopy,
    this.label,
    this.maxLines = 8,
  });

  final String value;
  final VoidCallback onCopy;
  final String? label;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (label != null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    label!,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: tr('复制'),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  onPressed: onCopy,
                ),
              ],
            ),
            const SizedBox(height: 2),
          ],
          SelectableText(
            value,
            maxLines: maxLines,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

/// 错误提示条（加密/解密/哈希页共用）。
class CryptoErrorBanner extends StatelessWidget {
  const CryptoErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withOpacity(0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
