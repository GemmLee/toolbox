import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import 'decibel_meter.dart';
import 'meter_widgets.dart';

/// 分贝仪：采集麦克风 PCM 数据，估算环境音量（手机麦克风未校准，读数仅供参考）。
class DecibelView extends StatefulWidget {
  const DecibelView({super.key, this.controller});

  /// 测试注入；为空时自建并负责释放。
  final DecibelController? controller;

  @override
  State<DecibelView> createState() => _DecibelViewState();
}

class _DecibelViewState extends State<DecibelView> {
  late final DecibelController _controller;
  late final bool _owns;

  @override
  void initState() {
    super.initState();
    _owns = widget.controller == null;
    _controller = widget.controller ?? DecibelController();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    if (_owns) _controller.dispose();
    super.dispose();
  }

  Color _zoneColor(DecibelZone zone) {
    switch (zone) {
      case DecibelZone.quiet:
        return const Color(0xFF2E9BD6);
      case DecibelZone.normal:
        return const Color(0xFF2FA36B);
      case DecibelZone.loud:
        return const Color(0xFFD9A322);
      case DecibelZone.noisy:
        return const Color(0xFFE0762D);
      case DecibelZone.dangerous:
        return const Color(0xFFD64545);
    }
  }

  String _zoneText(DecibelZone zone) {
    switch (zone) {
      case DecibelZone.quiet:
        return tr('安静');
      case DecibelZone.normal:
        return tr('正常');
      case DecibelZone.loud:
        return tr('偏吵');
      case DecibelZone.noisy:
        return tr('吵杂');
      case DecibelZone.dangerous:
        return tr('过响');
    }
  }

  String _errorText() {
    final error = _controller.error;
    if (error == 'permission') return tr('未获得麦克风权限，请在系统设置中允许后重试。');
    return trf('当前设备无法采集声音：{e}', {'e': error ?? ''});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frame = _controller.frame;
    final spl = frame?.spl;
    final zone = spl == null ? DecibelZone.quiet : DecibelAnalyzer.zoneOf(spl);
    final zoneColor = _zoneColor(zone);

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MeterHeader(
                  icon: Icons.graphic_eq,
                  title: tr('环境音量'),
                  badge: spl == null
                      ? null
                      : MeterZoneBadge(text: _zoneText(zone), color: zoneColor),
                ),
                const SizedBox(height: 10),
                MeterReading(
                  value: spl?.toStringAsFixed(0),
                  unit: 'dB',
                  color: zoneColor,
                  caption: tr('≈ 估算值'),
                ),
                const SizedBox(height: 14),
                MeterLevelBar(level: frame?.level ?? 0, color: zoneColor),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    MeterStat(
                      label: tr('峰值'),
                      value: frame == null
                          ? '—'
                          : '${frame.peak.toStringAsFixed(0)} dB',
                    ),
                    const SizedBox(width: 18),
                    MeterStat(
                      label: tr('平均'),
                      value: frame == null
                          ? '—'
                          : '${frame.average.toStringAsFixed(0)} dB',
                    ),
                    const Spacer(),
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        if (_controller.running) {
                          await _controller.stop();
                        } else {
                          await _controller.start();
                        }
                      },
                      icon: Icon(
                        _controller.running
                            ? Icons.stop_circle_outlined
                            : Icons.mic_none,
                        size: 18,
                      ),
                      label: Text(
                        _controller.running ? tr('停止测量') : tr('开始测量'),
                      ),
                    ),
                  ],
                ),
                if (_controller.error != null) ...[
                  const SizedBox(height: 12),
                  MeterErrorBanner(
                    icon: Icons.mic_off_outlined,
                    message: _errorText(),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        tr('校准偏移'),
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    InfoHint(
                      text: tr('手机麦克风没有统一灵敏度。读数明显偏高或偏低时，在安静房间（约 30dB）拖动滑块贴近实际值。'),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _controller.offsetDb.clamp(60.0, 120.0),
                        min: 60,
                        max: 120,
                        divisions: 60,
                        label: '${_controller.offsetDb.toStringAsFixed(0)} dB',
                        onChanged: _controller.setOffsetDb,
                      ),
                    ),
                    Text(
                      '${tr('偏移')} ${_controller.offsetDb.toStringAsFixed(0)}',
                      style: theme.textTheme.labelMedium,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        MeterReferenceCard(
          title: tr('常见音量参考'),
          rows: <List<String>>[
            <String>[tr('30 dB'), tr('耳语、安静卧室')],
            <String>[tr('60 dB'), tr('正常交谈')],
            <String>[tr('75 dB'), tr('吸尘器、繁忙街道')],
            <String>[tr('90 dB'), tr('摩托车、长时间会损伤听力')],
            <String>[tr('110 dB'), tr('电锯、演唱会前排')],
          ],
          note: tr('手机麦克风未经声学校准，结果只适合做相对比较，不能用于噪声取证。'),
        ),
      ],
    );
  }
}
