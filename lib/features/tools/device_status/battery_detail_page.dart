import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../core/settings/tool_texts.dart';
import 'battery_history.dart';
import 'device_status_channel.dart';
import '../../../core/widgets/app_widgets.dart';

/// 电池详情：电池图形 + 技术/健康/温度/电压/状态 + 电流功率 + 容量估算。
class BatteryDetailPage extends StatefulWidget {
  const BatteryDetailPage({super.key});

  @override
  State<BatteryDetailPage> createState() => _BatteryDetailPageState();
}

class _BatteryDetailPageState extends State<BatteryDetailPage> {
  BatteryDetail? _detail;
  Timer? _timer;

  /// 防止 2 秒轮询与下拉刷新并发。
  bool _inFlight = false;

  /// 实测电流采样（时间戳 + µA），用于自行计算平均电流。
  ///
  /// 系统 `BATTERY_PROPERTY_CURRENT_AVERAGE` 在多数机型上返回 0/不支持，
  /// 因此这里对 `CURRENT_NOW` 做 60 秒窗口的滚动平均作为兜底。
  final List<_CurrentSample> _samples = <_CurrentSample>[];
  static const Duration _avgWindow = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    BatteryHistory.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    _load();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final detail = await DeviceStatusChannel.batteryDetail();
      if (!mounted) return;
      _record(detail);
      // 先渲染再落盘：磁盘写入不应挡住首帧（也让页面在测试环境不依赖 path_provider）
      setState(() => _detail = detail);
      if (detail != null) {
        unawaited(
          BatteryHistory.add(BatterySample(
            time: DateTime.now(),
            level: detail.level,
            temp: detail.temperature,
            currentUa: detail.currentNowUa,
          )).then((changed) {
            if (changed && mounted) setState(() {});
          }),
        );
      }
    } finally {
      _inFlight = false;
    }
  }

  /// 记录一次电流采样，丢弃窗口外的旧值。
  void _record(BatteryDetail? d) {
    if (d == null || d.currentNowUa == 0) return;
    final now = DateTime.now();
    _samples.add(_CurrentSample(now, d.currentNowUa));
    _samples.removeWhere((s) => now.difference(s.time) > _avgWindow);
    if (_samples.length > 60) {
      _samples.removeRange(0, _samples.length - 60);
    }
  }

  /// 自己算的平均电流（µA）；样本不足时返回 0。
  int get _measuredAvgUa {
    if (_samples.length < 2) return 0;
    final sum = _samples.fold<double>(0, (acc, s) => acc + s.ua.abs());
    return (sum / _samples.length).round();
  }

  bool get _charging {
    final d = _detail;
    return d == null ? false : d.status == 2 || d.status == 5 || d.plugged != 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = _detail;
    return Scaffold(
      appBar: AppBar(title: Text(tr('电池详情'))),
      body: d == null
          ? Center(
              child: Text(tr('无法获取电池信息（仅支持 Android 真机/模拟器）')),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _headerCard(theme, d),
                  const SizedBox(height: 14),
                  _powerCard(theme, d),
                  const SizedBox(height: 14),
                  _trendCard(theme),
                  const SizedBox(height: 14),
                  _historyCard(theme),
                  const SizedBox(height: 14),
                  _capacityCard(theme, d),
                ],
              ),
            ),
    );
  }

  Widget _headerCard(ThemeData theme, BatteryDetail d) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _BatteryShape(level: d.level, charging: _charging),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _infoLine(theme, tr('电池技术'), d.technology),
                  _infoLine(theme, tr('健康状态'), _healthText(d.health)),
                  _infoLine(theme, tr('温度'),
                      '${formatMoney(d.temperature, digits: 1)}℃'),
                  _infoLine(
                      theme,
                      tr('电压'),
                      d.voltageMv > 0
                          ? '${formatMoney(d.voltageMv / 1000.0, digits: 2)} V'
                          : '--'),
                  _infoLine(theme, tr('电池状态'), _stateText(d)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoLine(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label：',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// 充放电趋势：速率（%/h）与预计剩余/充满时间。
  Widget _trendCard(ThemeData theme) {
    final trend = BatteryTrend.fromSamples(BatteryHistory.samples);
    final rate = trend?.percentPerHour;
    final remain = trend?.remaining;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.4,
    );
    return SectionCard(
      title: tr('充放电趋势'),
      subtitle: tr('按本机采样推算，采样间隔约 30 秒'),
      children: [
        Row(
          children: [
            Expanded(
              child: MetricTile(
                label: tr('速率'),
                value: rate == null
                    ? '--'
                    : '${rate > 0 ? '+' : ''}${formatMoney(rate, digits: 1)} %/h',
                compact: true,
                labelFirst: true,
              ),
            ),
            Expanded(
              child: MetricTile(
                label: _charging ? tr('预计充满') : tr('预计可用'),
                value: remain == null ? '--' : _formatDuration(remain),
                compact: true,
                labelFirst: true,
              ),
            ),
            Expanded(
              child: MetricTile(
                label: tr('采样点'),
                value: '${BatteryHistory.samples.length}',
                compact: true,
                labelFirst: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          trend == null
              ? tr('采样不足：保持页面开启几分钟即可算出速率与剩余时间')
              : trf('最近 {a} 分钟：{b}% → {c}%', {
                  'a': '${trend.span.inMinutes}',
                  'b': formatMoney(trend.fromLevel, digits: 0),
                  'c': formatMoney(trend.toLevel, digits: 0),
                }),
          style: muted,
        ),
      ],
    );
  }

  /// 24 小时电量/温度曲线（数据来自本地采样）。
  Widget _historyCard(ThemeData theme) {
    final samples = BatteryHistory.samples;
    final scheme = theme.colorScheme;
    return SectionCard(
      title: tr('电量曲线'),
      subtitle: trf('最近 24 小时 · {n} 个采样点', {'n': '${samples.length}'}),
      trailing: samples.isEmpty
          ? null
          : TextButton(
              onPressed: () async {
                await BatteryHistory.clear();
                if (mounted) setState(() {});
              },
              child: Text(tr('清空'), style: theme.textTheme.labelSmall),
            ),
      children: [
        if (samples.length < 2)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              tr('至少需要两个采样点才能画出曲线'),
              style: theme.textTheme.bodySmall,
            ),
          )
        else ...[
          SizedBox(
            height: 164,
            child: CustomPaint(
              size: Size.infinite,
              painter: _BatteryChartPainter(
                samples: samples,
                levelColor: scheme.primary,
                tempColor: const Color(0xFFF0A22E),
                gridColor: scheme.outlineVariant.withOpacity(0.6),
                axisColor: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _legend(scheme.primary, tr('电量')),
              const SizedBox(width: 16),
              _legend(const Color(0xFFF0A22E), tr('温度')),
            ],
          ),
        ],
        const SizedBox(height: 8),
        SmallHint(
          text: trf('仅在 App 运行时采样，每 {n} 分钟一点',
              {'n': BatteryHistory.autoInterval.inMinutes}),
        ),
      ],
    );
  }

  Widget _legend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h <= 0) return '$m 分钟';
    return '$h 小时 $m 分';
  }

  Widget _powerCard(ThemeData theme, BatteryDetail d) {
    final voltageV = d.voltageMv / 1000.0;
    final valid = d.currentNowUa != 0;
    final currentMa = d.currentNowUa / 1000.0;
    final powerW =
        valid ? (voltageV * currentMa.abs() / 1000).clamp(0.0, 1000.0) : 0.0;
    // 系统平均值多数机型不可用，退回自采样的 60 秒滚动均值。
    final avgUa = d.currentAvgUa != 0 ? d.currentAvgUa : _measuredAvgUa;
    final avgMa = avgUa / 1000.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _metric(
                    theme,
                    _charging ? tr('充电功率') : tr('放电功率'),
                    valid ? '${formatMoney(powerW, digits: 2)} W' : '--',
                  ),
                ),
                Expanded(
                  child: _metric(
                    theme,
                    tr('当前电流'),
                    valid
                        ? '${formatMoney(currentMa.abs(), digits: 0)} mA'
                        : '--',
                  ),
                ),
                Expanded(
                  child: _metric(
                    theme,
                    tr('平均电流'),
                    avgUa != 0
                        ? '${formatMoney(avgMa.abs(), digits: 0)} mA'
                        : '--',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              d.chargeCounterUah > 0
                  ? trf('剩余电量约 {v} mAh', {
                      'v': formatMoney(d.chargeCounterUah / 1000.0, digits: 0),
                    })
                  : tr('当前电量数据不可用'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _capacityCard(ThemeData theme, BatteryDetail d) {
    final design = d.chargeFullDesignUah;
    final measured = d.chargeFullUah;
    // 满充容量：系统 charge_full 读不到时，用「当前电量 ÷ 电量百分比」推算。
    final estimatedFull = measured > 0
        ? measured
        : (d.chargeCounterUah > 0 && d.level > 0
            ? (d.chargeCounterUah * 100 / d.level).round()
            : 0);
    final healthPct = estimatedFull > 0 && design > 0
        ? (estimatedFull * 100 / design).clamp(0, 100).toDouble()
        : 0.0;
    final unavailable = tr('系统未提供');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('容量与寿命'),
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            _capacityRow(
                theme,
                tr('标称容量'),
                design > 0
                    ? '${formatMoney(design / 1000.0, digits: 0)} mAh'
                    : unavailable),
            _capacityRow(
              theme,
              tr('估算满充电容量'),
              estimatedFull > 0
                  ? '${formatMoney(estimatedFull / 1000.0, digits: 0)} mAh'
                      '${measured > 0 ? '' : '（${tr('由当前电量推算')}）'}'
                  : unavailable,
            ),
            _capacityRow(
                theme,
                tr('电池健康度'),
                healthPct > 0
                    ? '${formatMoney(healthPct, digits: 0)}%'
                    : unavailable),
            _capacityRow(theme, tr('充电循环次数'),
                d.cycleCount > 0 ? '${d.cycleCount}' : unavailable),
            if (d.chargeType.isNotEmpty)
              _capacityRow(theme, tr('充电协议'), d.chargeType),
            if (d.chargeCounterUah > 0 && estimatedFull > 0)
              _capacityRow(
                theme,
                tr('当前电量'),
                '${formatMoney(d.chargeCounterUah / 1000.0, digits: 0)} mAh · '
                '${(d.chargeCounterUah * 100 / estimatedFull).toStringAsFixed(0)}%',
              ),
          ],
        ),
      ),
    );
  }

  Widget _capacityRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          Text(
            value,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _metric(ThemeData theme, String label, String value) =>
      MetricTile(label: label, value: value, compact: true);

  String _healthText(int health) {
    switch (health) {
      case 2:
        return tr('良好');
      case 3:
        return tr('过热');
      case 4:
        return tr('已损坏');
      case 5:
        return tr('电压过高');
      case 7:
        return tr('过冷');
      case 1:
      default:
        return tr('未知');
    }
  }

  String _stateText(BatteryDetail d) {
    if (d.plugged != 0) {
      switch (d.plugged) {
        case 1:
          return tr('充电中 · AC 电源');
        case 2:
          return tr('充电中 · USB');
        case 4:
          return tr('充电中 · 无线');
        default:
          return tr('充电中');
      }
    }
    switch (d.status) {
      case 4:
        return tr('已充满');
      case 3:
      case 5:
        return tr('放电中');
      default:
        return tr('未在充电');
    }
  }
}

/// 一次电流采样（用于计算滚动平均电流）。
class _CurrentSample {
  const _CurrentSample(this.time, this.ua);

  final DateTime time;
  final int ua;
}

/// 参考截图的电池图形：带电极头的矩形 + 电量填充。
class _BatteryShape extends StatelessWidget {
  const _BatteryShape({required this.level, required this.charging});

  final double level;
  final bool charging;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pct = level >= 0 ? level / 100 : 0.0;
    final fill = charging
        ? const Color(0xFF34C77B)
        : pct < 0.2
            ? const Color(0xFFE5484D)
            : scheme.primary;
    return SizedBox(
      width: 88,
      height: 130,
      child: Column(
        children: [
          Container(
            width: 34,
            height: 8,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(3)),
            ),
          ),
          Expanded(
            child: Container(
              width: 88,
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant, width: 2.5),
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(8),
                ),
              ),
              padding: const EdgeInsets.all(4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: pct.clamp(0.0, 1.0),
                    widthFactor: 1,
                    child: ColoredBox(color: fill),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 电量（折线 + 渐变填充）与温度（虚线）曲线。
class _BatteryChartPainter extends CustomPainter {
  _BatteryChartPainter({
    required this.samples,
    required this.levelColor,
    required this.tempColor,
    required this.gridColor,
    required this.axisColor,
  });

  final List<BatterySample> samples;
  final Color levelColor;
  final Color tempColor;
  final Color gridColor;
  final Color axisColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;
    final start = samples.first.time;
    final span = samples.last.time.difference(start).inMilliseconds;
    if (span <= 0) return;

    // 四周留出刻度文字空间，曲线只画在内嵌区域，避免文字压到曲线主体。
    const double leftPad = 34;
    const double rightPad = 34;
    const double topPad = 6;
    const double bottomPad = 18;
    final chart = Rect.fromLTRB(
      leftPad,
      topPad,
      size.width - rightPad,
      size.height - bottomPad,
    );
    if (chart.width <= 0 || chart.height <= 0) return;

    double xOf(BatterySample s) =>
        chart.left +
        (s.time.difference(start).inMilliseconds / span) * chart.width;
    double yOfLevel(BatterySample s) =>
        chart.bottom - (s.level.clamp(0, 100) / 100) * chart.height;
    // 温度轴跟随本次采样动态取 (min - 半程, max + 半程)：温度本来变化很小，
    // 固定 20~60℃ 会压成一条直线；上下留半个跨度又不至于把抖动放得太大。
    final (tempLo, tempHi) = tempAxisRange(samples.map((s) => s.temp));
    double yOfTemp(BatterySample s) =>
        chart.bottom - ((s.temp - tempLo) / (tempHi - tempLo)) * chart.height;

    // 三条网格线对应两侧刻度的顶/中/底，保持与曲线映射一致。
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final f in <double>[0, 0.5, 1]) {
      final y = chart.top + chart.height * f;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
    }

    canvas.save();
    canvas.clipRect(chart);

    final levelPath = Path()
      ..moveTo(xOf(samples.first), yOfLevel(samples.first));
    for (final s in samples.skip(1)) {
      levelPath.lineTo(xOf(s), yOfLevel(s));
    }
    final fill = Path.from(levelPath)
      ..lineTo(chart.right, chart.bottom)
      ..lineTo(chart.left, chart.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            levelColor.withOpacity(0.28),
            levelColor.withOpacity(0.02),
          ],
        ).createShader(chart),
    );
    canvas.drawPath(
      levelPath,
      Paint()
        ..color = levelColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final tempPaint = Paint()
      ..color = tempColor.withOpacity(0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    var prev = samples.first;
    for (final s in samples.skip(1)) {
      final dashPath = Path()
        ..moveTo(xOf(prev), yOfTemp(prev))
        ..lineTo(xOf(s), yOfTemp(s));
      canvas.drawPath(dashPath, tempPaint);
      prev = s;
    }

    canvas.restore();

    // 坐标轴刻度：小字号、弱化色，绘制在裁剪区之外的 padding 里。
    final labelStyle = TextStyle(color: axisColor, fontSize: 9, height: 1.0);
    TextPainter makeLabel(String text) {
      return TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
    }

    // 左纵轴电量、右纵轴温度，三者与 top/middle/bottom 网格线一一对应。
    const fractions = <double>[0, 0.5, 1];
    const levelLabels = <String>['100%', '50%', '0%'];
    final tempLabels = <String>[
      _tempLabel(tempHi),
      _tempLabel((tempLo + tempHi) / 2),
      _tempLabel(tempLo),
    ];
    for (var i = 0; i < fractions.length; i++) {
      final y = chart.top + chart.height * fractions[i];
      final levelTick = makeLabel(levelLabels[i]);
      levelTick.paint(canvas,
          Offset(chart.left - 4 - levelTick.width, y - levelTick.height / 2));
      final tempTick = makeLabel(tempLabels[i]);
      tempTick.paint(canvas, Offset(chart.right + 4, y - tempTick.height / 2));
    }

    // 横轴 4 个低密度刻度，沿横轴均匀分布；按真实时间取 24 小时制的小时。
    // 采样跨度不足 1 小时时相邻刻度会是同一个小时，重复的就不再画。
    const int ticks = 4;
    String? lastLabel;
    for (var i = 0; i < ticks; i++) {
      final f = i / (ticks - 1);
      final x = chart.left + chart.width * f;
      final time = start.add(Duration(milliseconds: (span * f).round()));
      final label = '${time.hour}h';
      if (label == lastLabel && i != ticks - 1) continue;
      lastLabel = label;
      final tp = makeLabel(label);
      final dx =
          i == 0 ? x : (i == ticks - 1 ? x - tp.width : x - tp.width / 2);
      tp.paint(canvas, Offset(dx, chart.bottom + 4));
    }
  }

  /// 刻度文字：整数就省掉小数点，避免「41.0℃」这种多余位数。
  static String _tempLabel(double value) {
    final rounded = value.roundToDouble();
    final text = (value - rounded).abs() < 0.05
        ? rounded.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$text℃';
  }

  @override
  bool shouldRepaint(covariant _BatteryChartPainter oldDelegate) {
    return oldDelegate.samples.length != samples.length ||
        oldDelegate.levelColor != levelColor ||
        oldDelegate.tempColor != tempColor ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.axisColor != axisColor;
  }
}
