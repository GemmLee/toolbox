import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/chess/chess_sound.dart';
import 'package:toolbox/features/tools/chess/game_controller.dart';

import '../../support/test_env.dart';

class _FakePlayer implements ChessSoundPlayer {
  final List<ChessSoundKind> played = <ChessSoundKind>[];

  @override
  Future<void> play(ChessSoundKind kind) async {
    played.add(kind);
  }
}

void main() {
  installCleanEnv();

  late _FakePlayer player;
  final sound = ChessSound.instance;

  setUp(() {
    player = _FakePlayer();
    sound
      ..player = player
      ..enabled = true
      ..timelineEnabled = false; // 跳过真实时间等待
  });

  tearDown(() {
    sound
      ..player = null
      ..enabled = true
      ..timelineEnabled = true;
  });

  test('播放顺序：落子 → 吃 → 将军', () {
    expect(
      ChessSound.plan(
        const ChessMoveFeedback(captured: false, check: false),
      ),
      <ChessSoundKind>[ChessSoundKind.move],
    );
    expect(
      ChessSound.plan(
        const ChessMoveFeedback(captured: true, check: false),
      ),
      <ChessSoundKind>[ChessSoundKind.move, ChessSoundKind.capture],
    );
    expect(
      ChessSound.plan(
        const ChessMoveFeedback(captured: true, check: true),
      ),
      <ChessSoundKind>[
        ChessSoundKind.move,
        ChessSoundKind.capture,
        ChessSoundKind.check,
      ],
    );
  });

  test('普通走子只播放落子撞击声', () async {
    await sound.onMove(
      const ChessMoveFeedback(captured: false, check: false),
    );
    expect(player.played, <ChessSoundKind>[ChessSoundKind.move]);
  });

  test('吃子且将军时三种配音依次播放', () async {
    await sound.onMove(
      const ChessMoveFeedback(captured: true, check: true),
    );
    expect(player.played, <ChessSoundKind>[
      ChessSoundKind.move,
      ChessSoundKind.capture,
      ChessSoundKind.check,
    ]);
  });

  test('关闭音效后不播放任何声音', () async {
    sound.enabled = false;
    await sound.onMove(
      const ChessMoveFeedback(captured: true, check: true),
    );
    expect(player.played, isEmpty);
  });

  test('播放器抛异常时静默降级，不影响对局', () async {
    sound.player = _ThrowingPlayer();
    await expectLater(
      sound.onMove(const ChessMoveFeedback(captured: true, check: true)),
      completes,
    );
  });

  test('音频资源路径与打包资源一致', () {
    expect(AssetChessSoundPlayer.files[ChessSoundKind.move],
        'sounds/move.wav');
    expect(AssetChessSoundPlayer.files[ChessSoundKind.capture],
        'sounds/eat.mp3');
    expect(AssetChessSoundPlayer.files[ChessSoundKind.check],
        'sounds/check.mp3');
  });
}

class _ThrowingPlayer implements ChessSoundPlayer {
  @override
  Future<void> play(ChessSoundKind kind) async => throw StateError('no plugin');
}
