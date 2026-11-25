import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'device_status_channel.dart';

/// 一次电池采样点。
class BatterySample {
  const BatterySample({
    required this.time,
    required this.level,
    required this.temp,
    required this.currentUa,
  });

  final DateTime time;

  /// 电量百分比（0~100），无效为 -1。
  final double level;

  /// 电池温度（℃）。
  final double temp;

  /// 瞬时电流（µA），充电为正、放电为负（厂商口径可能相反）。
  final int currentUa;

  bool get valid => level >= 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        't': time.millisecondsSinceEpoch,
        'l': level,
        'c': temp,
        'a': currentUa,
      };

  factory BatterySample.fromJson(Map<String, dynamic> json) => BatterySample(
        time: DateTime.fromMillisecondsSinceEpoch(
          (json['t'] as num?)?.toInt() ?? 0,
        ),
        level: (json['l'] as num?)?.toDouble() ?? -1,
        temp: (json['c'] as num?)?.toDouble() ?? 0,
        currentUa: (json['a'] as num?)?.toInt() ?? 0,
      );
}

/// 温度曲线纵轴范围：上下各留「半个数据跨度」，让起伏占满中间一半高度。
///
/// 温度本身变化很小，固定 20~60℃ 会压成一条直线；但也不能只取 min~max，
/// 否则 0.1℃ 的抖动会被放大成满屏锯齿。跨度过小时保底 1℃。
/// 返回 (下界, 上界)；没有数据时给一个 1℃ 的窗口。
(double, double) tempAxisRange(Iterable<double> temps) {
  double? lo;
  double? hi;
  for (final t in temps) {
    if (lo == null || t < lo) lo = t;
    if (hi == null || t > hi) hi = t;
  }
  if (lo == null || hi == null) return (0, 1);
  var span = hi - lo;
  if (span < 1) {
    final mid = (lo + hi) / 2;
    lo = mid - 0.5;
    hi = mid + 0.5;
    span = 1;
  }
  final pad = span / 2;
  return (lo - pad, hi + pad);
}

/// 电池历史：本地保留最近 24 小时的采样，用于画曲线与算放电速率。
///
/// 系统没有开放历史电量接口（BatteryStats 是隐藏 API，普通应用读不到），
/// 所以曲线只能靠自己采样：App 进程存活期间每 [autoInterval] 记一次，
/// 打开工具、回到前台时再各补一次，避免出现「一天只有两三个点」的直线。
class BatteryHistory {
  BatteryHistory._();

  static const Duration window = Duration(hours: 24);
  static const Duration minGap = Duration(seconds: 30);
  static const int maxPoints = 24 * 60 * 2; // 30s 一点约 2880 点封顶

  /// 前台自动采样间隔：15 分钟一点，24 小时最多 96 个点。
  static const Duration autoInterval = Duration(minutes: 15);

  static final List<BatterySample> _samples = <BatterySample>[];
  static File? _file;
  static Future<void>? _loading;
  static Timer? _autoTimer;
  static bool _sampling = false;

  static List<BatterySample> get samples =>
      List<BatterySample>.unmodifiable(_samples);

  static Future<File> _resolveFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/battery_history.json');
    _file = file;
    return file;
  }

  /// 读取磁盘上的历史（只做一次）。
  static Future<void> ensureLoaded() {
    return _loading ??= _loadOnce();
  }

  static Future<void> _loadOnce() async {
    try {
      final file = await _resolveFile();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return;
      final cutoff = DateTime.now().subtract(window);
      _samples
        ..clear()
        ..addAll(raw
            .whereType<Map>()
            .map((e) => BatterySample.fromJson(Map<String, dynamic>.from(e)))
            .where((s) => s.valid && s.time.isAfter(cutoff)));
    } catch (_) {
      // 文件损坏或不可读：当作没有历史
    }
  }

  /// 追加一个采样点；距上一个点不足 [minGap] 时忽略。返回是否真的写入。
  static Future<bool> add(BatterySample sample, {bool force = false}) async {
    if (!sample.valid) return false;
    await ensureLoaded();
    final last = _samples.isEmpty ? null : _samples.last;
    if (!force && last != null && sample.time.difference(last.time) < minGap) {
      // 间隔不够时只刷新最后一个点，保证「最近一次」是最新的
      _samples[_samples.length - 1] = sample;
      return false;
    }
    _samples.add(sample);
    final cutoff = sample.time.subtract(window);
    _samples.removeWhere((s) => s.time.isBefore(cutoff));
    if (_samples.length > maxPoints) {
      _samples.removeRange(0, _samples.length - maxPoints);
    }
    await _save();
    return true;
  }

  static Future<void> _save() async {
    try {
      final file = await _resolveFile();
      await file.writeAsString(
        jsonEncode(_samples.map((s) => s.toJson()).toList(growable: false)),
      );
    } catch (_) {
      // 写失败不影响页面展示
    }
  }

  /// 清空历史（页面上的「重置曲线」）。
  static Future<void> clear() async {
    _samples.clear();
    try {
      final file = await _resolveFile();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 忽略
    }
  }

  /// 立即采一个点（读取原生 BatteryManager 的电量 / 温度 / 电流）。
  ///
  /// 与页面刷新无关，打开工具、回到前台、定时器到点时都可调用；
  /// [force] 为 true 时忽略 [minGap]。
  static Future<bool> sampleNow({bool force = false}) async {
    if (_sampling) return false;
    _sampling = true;
    try {
      final detail = await DeviceStatusChannel.batteryDetail();
      if (detail == null) return false;
      return await add(
        BatterySample(
          time: DateTime.now(),
          level: detail.level,
          temp: detail.temperature,
          currentUa: detail.currentNowUa,
        ),
        force: force,
      );
    } catch (_) {
      // 原生通道不可用（桌面端 / 测试环境）时静默跳过
      return false;
    } finally {
      _sampling = false;
    }
  }

  /// 启动进程级定时采样：重复调用只保留一个定时器。
  ///
  /// [interval] 默认 [autoInterval]；启动时先记一个点，回到前台也会补记。
  static void startAutoSample({Duration interval = autoInterval}) {
    if (_autoTimer != null) return;
    WidgetsBinding.instance.addObserver(_sampler);
    unawaited(sampleNow());
    _autoTimer = Timer.periodic(interval, (_) => unawaited(sampleNow()));
  }

  static void stopAutoSample() {
    _autoTimer?.cancel();
    _autoTimer = null;
    WidgetsBinding.instance.removeObserver(_sampler);
  }

  static final _LifecycleSampler _sampler = _LifecycleSampler();
}

/// 应用回到前台时补一个采样点：后台期间系统可能冻结进程，
/// 定时器不保证按时触发，靠这一下把断档补上。
class _LifecycleSampler with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(BatteryHistory.sampleNow());
    }
  }
}

/// 由采样序列推导的充放电趋势。
class BatteryTrend {
  const BatteryTrend({
    required this.percentPerHour,
    required this.span,
    required this.fromLevel,
    required this.toLevel,
  });

  /// 每小时电量变化（正=充电，负=放电）。
  final double percentPerHour;

  /// 参与计算的时间跨度。
  final Duration span;
  final double fromLevel;
  final double toLevel;

  bool get charging => percentPerHour > 0;

  /// 放电/充电估算剩余时间；速率过小时返回 null。
  Duration? get remaining {
    final rate = percentPerHour.abs();
    if (rate < 0.2) return null;
    final delta = charging ? 100 - toLevel : toLevel;
    if (delta <= 0) return null;
    final hours = delta / rate;
    if (hours.isNaN || hours.isInfinite || hours > 24 * 7) return null;
    return Duration(minutes: (hours * 60).round());
  }

  /// 用最近 [window] 内全部采样做加权斜率：ΣΔ电量 / ΣΔ小时。
  static BatteryTrend? fromSamples(
    List<BatterySample> samples, {
    Duration window = const Duration(hours: 1),
  }) {
    if (samples.length < 2) return null;
    final cutoff = samples.last.time.subtract(window);
    final points =
        samples.where((s) => s.valid && !s.time.isBefore(cutoff)).toList();
    if (points.length < 2) return null;
    var deltaLevel = 0.0;
    var deltaHours = 0.0;
    for (var i = 1; i < points.length; i++) {
      final dt = points[i].time.difference(points[i - 1].time).inMilliseconds;
      if (dt <= 0) continue;
      final dl = points[i].level - points[i - 1].level;
      // 跳变超过 30% 视为插拔/重启造成的异常段，直接跳过
      if (dl.abs() > 30) continue;
      deltaLevel += dl;
      deltaHours += dt / Duration.millisecondsPerHour;
    }
    if (deltaHours <= 0) return null;
    return BatteryTrend(
      percentPerHour: deltaLevel / deltaHours,
      span: points.last.time.difference(points.first.time),
      fromLevel: points.first.level,
      toLevel: points.last.level,
    );
  }
}
