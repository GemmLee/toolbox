import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../core/settings/tool_texts.dart';
import 'device_status_channel.dart';
import '../../../core/widgets/app_widgets.dart';

/// 存储分区详情：各分区 + 运存/交换空间的已用、可用、总量与占比。
class StorageDetailPage extends StatefulWidget {
  const StorageDetailPage({super.key});

  @override
  State<StorageDetailPage> createState() => _StorageDetailPageState();
}

class _StorageDetailPageState extends State<StorageDetailPage> {
  List<StoragePartition>? _partitions;
  MemoryDetail? _memory;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final partitions = await DeviceStatusChannel.storageDetail();
    final memory = await DeviceStatusChannel.memoryDetail();
    if (!mounted) return;
    setState(() {
      _partitions = partitions;
      _memory = memory;
      if (partitions == null) {
        _error = tr('无法获取存储信息（仅支持 Android 真机/模拟器）');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('分区详情'))),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : RefreshIndicator(
                onRefresh: () async {
                  await _load();
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    ..._storageRows(),
                    _memoryRow(
                      icon: Icons.memory_outlined,
                      title: tr('运存空间（RAM）'),
                      used: _memory == null
                          ? 0
                          : (_memory!.memTotal - _memory!.memAvailable),
                      total: _memory?.memTotal ?? 0,
                    ),
                    _memoryRow(
                      icon: Icons.sync_outlined,
                      title: tr('交换空间（虚拟内存）'),
                      used: _memory == null
                          ? 0
                          : (_memory!.swapTotal - _memory!.swapFree),
                      total: _memory?.swapTotal ?? 0,
                    ),
                    _memoryRow(
                      icon: Icons.swap_horiz_outlined,
                      title: tr('被高速交换空间缓存（SwapCached）'),
                      used: _memory?.swapCached ?? 0,
                      total: _memory?.swapTotal ?? 0,
                    ),
                    _memoryRow(
                      icon: Icons.grid_view_outlined,
                      title: tr('内核数据结构缓存（Slab）'),
                      used: _memory?.slab ?? 0,
                      total: _memory == null
                          ? 0
                          : (_memory!.slab + _memory!.sReclaimable),
                    ),
                    _memoryRow(
                      icon: Icons.compress_outlined,
                      title: tr('Zram 压缩内存'),
                      used: _memory?.zramUsed ?? 0,
                      total: _memory?.zramDisksize ?? 0,
                    ),
                  ],
                ),
          ),
    );
  }

  List<Widget> _storageRows() {
    final partitions = _partitions ?? const <StoragePartition>[];
    return [
      for (final p in partitions.where((p) => p.total > 0))
        _PartitionCard(
          icon: p.id == 'data'
              ? Icons.save_outlined
              : p.id == 'system'
                  ? Icons.layers_outlined
                  : p.id == 'cache'
                      ? Icons.cleaning_services_outlined
                      : Icons.sd_storage_outlined,
          title: switch (p.id) {
            'data' => tr('用户分区（Data）'),
            'system' => tr('系统分区（System）'),
            'cache' => tr('缓存分区（Cache）'),
            _ => tr('外部存储（External）'),
          },
          subtitle: p.path,
          used: p.total - p.free,
          free: p.free,
          total: p.total,
        ),
    ];
  }

  Widget _memoryRow({
    required IconData icon,
    required String title,
    required int used,
    required int total,
  }) {
    if (total <= 0) return const SizedBox.shrink();
    return _PartitionCard(
      icon: icon,
      title: title,
      used: used.clamp(0, total),
      free: (total - used).clamp(0, total),
      total: total,
    );
  }
}

/// 单个分区卡片：进度条 + 四列指标，样式对齐参考截图。
class _PartitionCard extends StatelessWidget {
  const _PartitionCard({
    required this.icon,
    required this.title,
    required this.used,
    required this.free,
    required this.total,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final int used;
  final int free;
  final int total;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = total > 0 ? used / total : 0.0;
    final clamped = pct.clamp(0.0, 1.0);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 10,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: clamped,
                minHeight: 7,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _cell(context, tr('已用'), formatBytes(used)),
                _cell(context, tr('可用'), formatBytes(free)),
                _cell(context, tr('总空间'), formatBytes(total)),
                _cell(context, tr('占比'), '${(clamped * 100).toStringAsFixed(0)}%'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, String label, String value) =>
      Expanded(child: MetricTile(label: label, value: value, compact: true));
}
