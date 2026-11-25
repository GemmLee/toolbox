import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/platform/keep_awake.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/storage/local_store.dart';
import '../logic/quiz_ai_convert.dart';

/// 转换阶段：页面退出后状态仍保留，回来直接接着看进度或结果。
enum QuizConvertPhase { idle, running, done, error, cancelled }

/// AI 题库转换的进程级任务控制器。
///
/// 转换是耗时网络任务，过去绑在页面 State 上：一旦退出页面或息屏就会中断。
/// 这里把任务、进度与结果放到单例里，页面只订阅；`dispose()` 不取消任务，
/// 同时用 [KeepAwake] 在息屏/切后台后保持 CPU 运行，回来即可继续或查看结果。
class QuizConversionController extends ChangeNotifier {
  QuizConversionController._();

  static final QuizConversionController instance =
      QuizConversionController._();

  static const String _storeKey = 'quiz_convert_options';

  QuizConvertPhase _phase = QuizConvertPhase.idle;
  String? _fileName;
  String? _text;
  double _fraction = 0;
  String _label = '';
  QuizConvertResult? _result;
  String? _error;
  bool _cancelled = false;
  bool _keepScreenOn = false;
  bool _preferencesLoaded = false;

  /// 每次 start / reset 递增，旧任务完成后不会覆盖新任务的状态。
  int _generation = 0;

  QuizConvertPhase get phase => _phase;
  String? get fileName => _fileName;
  /// 源文档正文：退出页面再回来仍能「重新转换」。
  String? get text => _text;
  double get fraction => _fraction;
  String get label => _label;
  QuizConvertResult? get result => _result;
  String? get error => _error;
  bool get busy => _phase == QuizConvertPhase.running;
  bool get keepScreenOn => _keepScreenOn;

  /// 读取「转换时保持屏幕常亮」偏好。默认关闭：允许息屏，任务照样继续。
  Future<void> loadPreference() async {
    if (_preferencesLoaded) return;
    _preferencesLoaded = true;
    try {
      final map = await LocalStore.readMap(_storeKey);
      final value = map?['keepScreenOn'];
      if (value is bool) _keepScreenOn = value;
    } catch (_) {
      // 存储不可用时保持默认。
    }
    _notify();
  }

  Future<void> setKeepScreenOn(bool value) async {
    _keepScreenOn = value;
    _notify();
    try {
      await LocalStore.writeMap(
        _storeKey,
        <String, dynamic>{'keepScreenOn': value},
      );
    } catch (_) {
      // 持久化失败不影响本次会话。
    }
    await _applyAwake(busy);
  }

  /// 开始转换；已有任务在跑时忽略，避免重复扣费。
  Future<void> start({
    required String text,
    required String fileName,
    required QuizAiConverter converter,
  }) async {
    if (busy) return;
    final generation = ++_generation;
    bool alive() => generation == _generation;

    _cancelled = false;
    _phase = QuizConvertPhase.running;
    _fileName = fileName;
    _text = text;
    _fraction = 0;
    _label = tr('正在准备…');
    _result = null;
    _error = null;
    _notify();
    // 不 await：保活是原生通道调用，测试环境无插件时也能立刻进入转换。
    unawaited(_applyAwake(true));

    try {
      final result = await converter.convert(
        text,
        cancelled: () => !alive() || _cancelled,
        onProgress: (p) {
          if (!alive()) return;
          _fraction = p.fraction;
          _label = p.label;
          _notify();
        },
      );
      if (!alive() || _cancelled) return;
      _result = result;
      _phase = QuizConvertPhase.done;
      _notify();
    } on QuizConvertException catch (e) {
      if (!alive()) return;
      _phase = _cancelled
          ? QuizConvertPhase.cancelled
          : QuizConvertPhase.error;
      _error = _cancelled ? tr('已取消转换') : e.message;
      _notify();
    } catch (e) {
      if (!alive()) return;
      _phase = _cancelled
          ? QuizConvertPhase.cancelled
          : QuizConvertPhase.error;
      _error = _cancelled ? tr('已取消转换') : '$e';
      _notify();
    } finally {
      // 释放唤醒锁不必等状态刷新：上面已经同步通知过页面。
      if (alive()) await _applyAwake(false);
    }
  }

  /// 用上一次的源文档重新转换（页面重建后转换器可换成新实例）。
  Future<void> retry({required QuizAiConverter converter}) async {
    final text = _text;
    final name = _fileName;
    if (text == null || name == null || busy) return;
    await start(text: text, fileName: name, converter: converter);
  }

  /// 用户主动取消：立即收起进度并释放保活，不等网络请求返回。
  ///
  /// 递增 generation 让迟到的网络回调无法把已取消的任务改回「完成」。
  void cancel() {
    if (!busy) return;
    ++_generation;
    _cancelled = true;
    _phase = QuizConvertPhase.cancelled;
    _error = tr('已取消转换');
    _notify();
    unawaited(KeepAwake.release());
  }

  /// 清空结果，回到「选择文件」状态。
  void reset() {
    ++_generation;
    _cancelled = true;
    _phase = QuizConvertPhase.idle;
    _fileName = null;
    _text = null;
    _fraction = 0;
    _label = '';
    _result = null;
    _error = null;
    unawaited(KeepAwake.release());
    _notify();
  }

  /// 预览解析失败时附加一条错误说明，保留已转换结果供用户重试导入。
  void showImportError(String message) {
    _error = message;
    _notify();
  }

  /// 单例跨用例存在，测试开始前调用，避免上一用例的结果串到下一用例。
  @visibleForTesting
  void resetForTest() {
    reset();
    _keepScreenOn = false;
    _preferencesLoaded = false;
  }

  Future<void> _applyAwake(bool active) => KeepAwake.set(
        cpuAwake: active,
        screenOn: active && _keepScreenOn,
      );

  void _notify() {
    notifyListeners();
  }
}
