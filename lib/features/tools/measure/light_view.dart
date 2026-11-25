import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import 'light_meter.dart';
import 'meter_widgets.dart';

/// 光强计：读取环境光传感器照度（lux），分级显示明暗环境。
class LightView extends StatefulWidget {
  const LightView({super.key, this.controller});

  /// 测试注入；为空时自建并负责释放。
  final LightMeterController? controller;

  @override
  State<LightView> createState() => _LightViewState();
}

class _LightViewState extends State<LightView> {
  late final LightMeterController _controller;
  late final bool _owns;

  @override
  void initState() {
    super.initState();
    _owns = widget.controller == null;
    _controller = widget.controller ?? LightMeterController();
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

  Color _zoneColor(LightZone zone) {
    switch (zone) {
      case LightZone.dark:
        return const Color(0xFF5B6B8C);
      case LightZone.dim:
        return const Color(0xFF2E9BD6);
      case LightZone.indoorDim:
        return const Color(0xFF3AA8A0);
      case LightZone.indoor:
        return const Color(0xFF2FA36B);
      case LightZone.bright:
        return const Color(0xFFD9A322);
      case LightZone.outdoor:
        return const Color(0xFFE0762D);
      case LightZone.direct:
        return const Color(0xFFD64545);
    }
  }

  String _zoneText(LightZone zone) {
    switch (zone) {
      case LightZone.dark:
        return tr('黑暗');
      case LightZone.dim:
        return tr('昏暗');
      case LightZone.indoorDim:
        return tr('偏暗室内');
      case LightZone.indoor:
        return tr('正常室内');
      case LightZone.bright:
        return tr('明亮');
      case LightZone.outdoor:
        return tr('户外阴天');
      case LightZone.direct:
        return tr('强光直射');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sample = _controller.sample;
    final lux = sample?.lux;
    final zone = LightAnalyzer.zoneOf(lux ?? 0);
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
                  icon: Icons.light_mode_outlined,
                  title: tr('环境光照'),
                  badge: lux == null
                      ? null
                      : MeterZoneBadge(text: _zoneText(zone), color: zoneColor),
                ),
                const SizedBox(height: 10),
                MeterReading(
                  value: lux == null ? null : LightAnalyzer.formatLux(lux),
                  valueKey: const ValueKey('light-value'),
                  unit: 'lux',
                  color: zoneColor,
                  caption: tr('传感器实测'),
                ),
                const SizedBox(height: 14),
                MeterLevelBar(
                  level: sample?.level ?? 0,
                  color: zoneColor,
                  divisions: 6,
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    MeterStat(
                      label: tr('峰值'),
                      value: sample == null
                          ? '—'
                          : '${LightAnalyzer.formatLux(sample.max)} lux',
                    ),
                    const SizedBox(width: 18),
                    MeterStat(
                      label: tr('平均'),
                      value: sample == null
                          ? '—'
                          : '${LightAnalyzer.formatLux(sample.average)} lux',
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
                            : Icons.sensors,
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
                    icon: Icons.sensors_off_outlined,
                    message: tr('当前设备没有环境光传感器，无法测量光照。'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        MeterReferenceCard(
          title: tr('常见光照参考'),
          valueWidth: 96,
          rows: <List<String>>[
            <String>['0.5 lux', tr('月夜')],
            <String>['50 lux', tr('走廊、楼道')],
            <String>['300 lux', tr('办公室照明')],
            <String>['10000 lux', tr('阴天户外')],
            <String>['100000 lux', tr('正午阳光直射')],
          ],
          note: tr('手机环境光传感器用于自动亮度调节，不同机型灵敏度有差异，读数仅供参考。'),
        ),
      ],
    );
  }
}
