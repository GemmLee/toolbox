import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// 一帧音量结果。
class DecibelFrame {
  const DecibelFrame({
    required this.dbfs,
    required this.spl,
    required this.peak,
    required this.average,
  });

  /// 相对满量程的分贝值（dBFS，≤0）。
  final double dbfs;

  /// 估算的声压级（dB SPL），= dBFS + 校准偏移。
  final double spl;

  final double peak;
  final double average;

  /// 0~1 的归一化电平，用于进度条：30dB 起、110dB 满。
  double get level => ((spl - 30) / 80).clamp(0.0, 1.0);
}

/// 环境音量分级。
enum DecibelZone { quiet, normal, loud, noisy, dangerous }

/// PCM16 音量分析（纯逻辑，不依赖插件，可单测）。
class DecibelAnalyzer {
  DecibelAnalyzer({
    this.offsetDb = 94,
    this.riseSmoothing = 0.6,
    this.fallSmoothing = 0.22,
  });

  /// 校准偏移：dBFS 加它得到估算 dB SPL。手机麦克风未经校准，默认 94。
  double offsetDb;

  /// 上升（变响）比下降（变轻）更快，接近专业声级表的快档特性。
  final double riseSmoothing;
  final double fallSmoothing;

  double _smoothed = -100;
  double _peak = -100;
  double _sum = 0;
  int _count = 0;
  bool _hasData = false;

  double get peak => _hasData ? _peak : 0;
  double get average => _count == 0 ? 0 : _sum / _count;

  void reset() {
    _smoothed = -100;
    _peak = -100;
    _sum = 0;
    _count = 0;
    _hasData = false;
  }

  /// 处理一段 PCM16LE 数据；数据不足一帧时返回 null。
  DecibelFrame? process(Uint8List pcm16) {
    if (pcm16.lengthInBytes < 4) return null;
    final rms = rmsOfPcm16(pcm16);
    final dbfs = dbfsFromRms(rms);
    if (!_hasData) {
      _hasData = true;
      _smoothed = dbfs;
      _peak = dbfs;
      _sum = dbfs;
      _count = 1;
      return _frame(_smoothed);
    }
    final k = dbfs > _smoothed ? riseSmoothing : fallSmoothing;
    _smoothed += (dbfs - _smoothed) * k;
    if (_smoothed > _peak || _peak < -99) _peak = _smoothed;
    _sum += _smoothed;
    _count++;
    return _frame(_smoothed);
  }

  DecibelFrame _frame(double dbfs) {
    final spl = (dbfs + offsetDb).clamp(0.0, 140.0);
    return DecibelFrame(
      dbfs: dbfs,
      spl: spl,
      peak: (_peak + offsetDb).clamp(0.0, 140.0),
      average: (_sum / _count + offsetDb).clamp(0.0, 140.0),
    );
  }

  /// PCM16LE 数据的均方根（0~32767）。
  static double rmsOfPcm16(Uint8List bytes) {
    final samples = bytes.lengthInBytes ~/ 2;
    if (samples == 0) return 0;
    final data = ByteData.sublistView(bytes);
    var sum = 0.0;
    for (var i = 0; i < samples; i++) {
      final v = data.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
    }
    return math.sqrt(sum / samples) * 32768;
  }

  /// 均方根 → dBFS，下限 -100dB（静音）。
  static double dbfsFromRms(double rms) {
    if (rms <= 0) return -100;
    final normalized = rms / 32768.0;
    final db = 20 * (math.log(normalized) / math.ln10);
    return db.clamp(-100.0, 0.0);
  }

  /// 估算声压级分级。
  static DecibelZone zoneOf(double spl) {
    if (spl < 40) return DecibelZone.quiet;
    if (spl < 60) return DecibelZone.normal;
    if (spl < 75) return DecibelZone.loud;
    if (spl < 90) return DecibelZone.noisy;
    return DecibelZone.dangerous;
  }
}

/// 音频采集抽象：真机用 record 插件，测试注入假实现。
abstract class AudioCapture {
  Future<bool> ensurePermission();

  Future<Stream<Uint8List>> startStream();

  Future<void> stop();

  Future<void> dispose();
}

/// 基于 record 插件的 PCM16 采集。
class RecordAudioCapture implements AudioCapture {
  final AudioRecorder _recorder = AudioRecorder();

  static const RecordConfig config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 44100,
    numChannels: 1,
    autoGain: false,
    echoCancel: false,
    noiseSuppress: false,
  );

  @override
  Future<bool> ensurePermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> startStream() => _recorder.startStream(config);

  @override
  Future<void> stop() async {
    if (await _recorder.isRecording()) await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// 分贝仪状态：开始 / 停止采集，向外推送最新一帧。
class DecibelController extends ChangeNotifier {
  DecibelController({AudioCapture? capture, DecibelAnalyzer? analyzer})
      : _capture = capture ?? RecordAudioCapture(),
        _analyzer = analyzer ?? DecibelAnalyzer();

  final AudioCapture _capture;
  final DecibelAnalyzer _analyzer;

  StreamSubscription<Uint8List>? _sub;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  DecibelFrame? _frame;
  bool _running = false;
  String? _error;

  DecibelFrame? get frame => _frame;
  bool get running => _running;
  String? get error => _error;
  double get offsetDb => _analyzer.offsetDb;

  void setOffsetDb(double value) {
    _analyzer.offsetDb = value;
    notifyListeners();
  }

  Future<void> start() async {
    if (_running) return;
    _error = null;
    _analyzer.reset();
    _frame = null;
    notifyListeners();
    try {
      final granted = await _capture.ensurePermission();
      if (!granted) {
        _error = 'permission';
        notifyListeners();
        return;
      }
      final stream = await _capture.startStream();
      _running = true;
      notifyListeners();
      _sub = stream.listen(
        _onData,
        onError: (Object e) {
          _error = '$e';
          _running = false;
          notifyListeners();
        },
        cancelOnError: false,
      );
    } catch (e) {
      // 测试环境没有麦克风插件，或设备不支持：给出提示而不是崩溃。
      _error = '$e';
      _running = false;
      notifyListeners();
    }
  }

  void _onData(Uint8List chunk) {
    final frame = _analyzer.process(chunk);
    if (frame == null) return;
    _frame = frame;
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds < 90) return;
    _lastNotify = now;
    notifyListeners();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    if (_running) {
      try {
        await _capture.stop();
      } catch (_) {
        // 停止失败不影响界面状态复位。
      }
    }
    _running = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _capture.dispose();
    super.dispose();
  }
}
