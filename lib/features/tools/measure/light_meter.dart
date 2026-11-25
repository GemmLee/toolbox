import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 环境光照度分级（lux）。
enum LightZone {
  /// 深夜 / 无光（< 1 lux）。
  dark,

  /// 昏暗（1~20 lux，路灯、走道）。
  dim,

  /// 偏暗的室内（20~80 lux，客厅电视旁）。
  indoorDim,

  /// 正常室内（80~300 lux，办公室照明）。
  indoor,

  /// 明亮（300~1500 lux，靠窗、超市）。
  bright,

  /// 户外阴天 / 树荫（1500~12000 lux）。
  outdoor,

  /// 强光（> 12000 lux，晴天、阳光直射）。
  direct,
}

/// 光照读数（纯逻辑，可单测）。
class LightAnalyzer {
  /// 当前平滑后的读数。传感器噪声较大，用非对称平滑：
  /// 变亮跟随快，变暗跟随慢，读数更稳。
  double smoothed = 0;
  double min = double.infinity;
  double max = 0;
  double sum = 0;
  int count = 0;

  /// 平滑系数：上升 0.55 / 下降 0.18。
  static const double riseSmoothing = 0.55;
  static const double fallSmoothing = 0.18;

  void reset() {
    smoothed = 0;
    min = double.infinity;
    max = 0;
    sum = 0;
    count = 0;
  }

  LightSample process(double lux) {
    final v = lux.clamp(0.0, 200000.0).toDouble();
    if (count == 0) {
      smoothed = v;
    } else {
      final k = v > smoothed ? riseSmoothing : fallSmoothing;
      smoothed += (v - smoothed) * k;
    }
    count++;
    if (smoothed < min) min = smoothed;
    if (smoothed > max) max = smoothed;
    sum += smoothed;
    return LightSample(
      lux: smoothed,
      min: min,
      max: max,
      average: sum / count,
    );
  }

  static LightZone zoneOf(double lux) {
    if (lux < 1) return LightZone.dark;
    if (lux < 20) return LightZone.dim;
    if (lux < 80) return LightZone.indoorDim;
    if (lux < 300) return LightZone.indoor;
    if (lux < 1500) return LightZone.bright;
    if (lux < 12000) return LightZone.outdoor;
    return LightZone.direct;
  }

  /// 0~1 归一化电平，对数刻度：0.1 lux 起步，100000 lux 满格（6 个数量级）。
  static double levelOf(double lux) {
    if (lux <= 0.1) return 0;
    final decades = (math.log(lux) / math.ln10 + 1) / 6;
    return decades.clamp(0.0, 1.0);
  }

  /// 数值格式化：< 10 保留一位小数，< 1000 取整，更大用 k 缩写。
  static String formatLux(double lux) {
    if (lux < 10) return lux.toStringAsFixed(1);
    if (lux < 1000) return lux.round().toString();
    return '${(lux / 1000).toStringAsFixed(lux < 10000 ? 2 : 1)}k';
  }
}

/// 一次光照采样。
class LightSample {
  const LightSample({
    required this.lux,
    required this.min,
    required this.max,
    required this.average,
  });

  final double lux;
  final double min;
  final double max;
  final double average;

  LightZone get zone => LightAnalyzer.zoneOf(lux);

  double get level => LightAnalyzer.levelOf(lux);
}

/// 光照传感器抽象：真机走平台通道，测试注入假实现。
abstract class LightSensor {
  /// 订阅光照度事件（lux）。设备没有传感器时流会带错误。
  Stream<double> luxStream();
}

/// Android 环境光传感器（TYPE_LIGHT），由 MainActivity 提供 EventChannel。
class EventChannelLightSensor implements LightSensor {
  static const EventChannel _channel = EventChannel('toolbox/sensors/light');

  @override
  Stream<double> luxStream() => _channel
      .receiveBroadcastStream()
      .map<double>((event) => (event as num).toDouble());
}

/// 光强计状态：开始 / 停止读取，向外推送最新采样。
class LightMeterController extends ChangeNotifier {
  LightMeterController({LightSensor? sensor})
      : _sensor = sensor ?? EventChannelLightSensor();

  final LightSensor _sensor;
  final LightAnalyzer _analyzer = LightAnalyzer();

  StreamSubscription<double>? _sub;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  LightSample? _sample;
  bool _running = false;
  String? _error;

  LightSample? get sample => _sample;
  bool get running => _running;
  String? get error => _error;

  Future<void> start() async {
    if (_running) return;
    _error = null;
    _analyzer.reset();
    _sample = null;
    notifyListeners();
    try {
      final stream = _sensor.luxStream();
      _running = true;
      notifyListeners();
      _sub = stream.listen(
        _onData,
        onError: (Object e) {
          _error = '$e';
          _running = false;
          notifyListeners();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _error = '$e';
      _running = false;
      notifyListeners();
    }
  }

  void _onData(double lux) {
    _sample = _analyzer.process(lux);
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds < 120) return;
    _lastNotify = now;
    notifyListeners();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _running = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
