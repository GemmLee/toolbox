import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import '../../../core/storage/local_store.dart';
import 'game_controller.dart';

/// 三种对局配音。
enum ChessSoundKind { move, capture, check }

/// 音效播放器抽象：测试可注入假实现，不依赖音频插件。
abstract interface class ChessSoundPlayer {
  Future<void> play(ChessSoundKind kind);
}

/// 工程内置音频资源播放器。
class AssetChessSoundPlayer implements ChessSoundPlayer {
  AssetChessSoundPlayer();

  static const Map<ChessSoundKind, String> files = <ChessSoundKind, String>{
    ChessSoundKind.move: 'sounds/move.wav',
    ChessSoundKind.capture: 'sounds/eat.mp3',
    ChessSoundKind.check: 'sounds/check.mp3',
  };

  AudioPlayer? _player;

  @override
  Future<void> play(ChessSoundKind kind) async {
    final player = _player ??= AudioPlayer();
    // 单播放器串行播放，避免吃子与将军的女声互相盖住。
    await player.stop();
    await player.play(AssetSource(files[kind]!));
  }

  void dispose() {
    _player?.dispose();
    _player = null;
  }
}

/// 对局配音调度。
///
/// 一步棋里可能同时发生「吃子」和「将军」，按 先落子 → 吃 → 将军 的
/// 顺序错开播放，而不是叠在一起。所有播放都是 fire-and-forget，
/// 不阻塞落子与 AI 走子。
class ChessSound {
  ChessSound._();

  static final ChessSound instance = ChessSound._();

  static const String _storeKey = 'chess_sound_settings';
  static const Duration captureDelay = Duration(milliseconds: 90);
  static const Duration checkDelay = Duration(milliseconds: 330);

  bool enabled = true;

  /// 测试时置 false，去掉真实时间等待。
  bool timelineEnabled = true;

  ChessSoundPlayer? _injected;
  AssetChessSoundPlayer? _assetPlayer;

  set player(ChessSoundPlayer? value) => _injected = value;

  ChessSoundPlayer get _effective =>
      _injected ?? (_assetPlayer ??= AssetChessSoundPlayer());

  /// 从本地设置恢复开关（读取失败时保持默认开启）。
  Future<void> load() async {
    try {
      final data = await LocalStore.readMap(_storeKey);
      final value = data?['enabled'];
      if (value is bool) enabled = value;
    } catch (_) {
      // 存储插件不可用时静默跳过。
    }
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    try {
      await LocalStore.writeMap(_storeKey, <String, dynamic>{'enabled': value});
    } catch (_) {
      // 同上：开关至少在本次会话内生效。
    }
  }

  /// 一步棋对应的音效序列（纯函数，便于回归测试）。
  static List<ChessSoundKind> plan(ChessMoveFeedback feedback) =>
      <ChessSoundKind>[
        ChessSoundKind.move,
        if (feedback.captured) ChessSoundKind.capture,
        if (feedback.check) ChessSoundKind.check,
      ];

  /// 落子后播放配音；音频插件不可用时静默降级，绝不影响对局。
  Future<void> onMove(ChessMoveFeedback feedback) async {
    if (!enabled) return;
    try {
      for (final kind in plan(feedback)) {
        if (timelineEnabled && kind == ChessSoundKind.capture) {
          await Future<void>.delayed(captureDelay);
        }
        if (timelineEnabled && kind == ChessSoundKind.check) {
          await Future<void>.delayed(checkDelay);
        }
        await _effective.play(kind);
      }
    } catch (_) {
      // 无音频插件（widget 测试、部分桌面端）时不影响对局。
    }
  }
}
