import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/features/tools/autoclick/auto_click_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('动作序列化往返保留类型、坐标与时长', () {
    const action = AutoClickAction(
      id: 'a',
      type: AutoClickActionType.swipe,
      x: 20,
      y: 30,
      x2: 80,
      y2: 70,
      durationMs: 600,
    );
    final restored = AutoClickAction.fromJson(action.toJson());
    expect(restored.type, AutoClickActionType.swipe);
    expect(restored.x, 20);
    expect(restored.y, 30);
    expect(restored.x2, 80);
    expect(restored.y2, 70);
    expect(restored.durationMs, 600);
    expect(restored.needsEndPoint, isTrue);
    expect(AutoClickActionType.fromId('unknown'), AutoClickActionType.tap);
  });

  test('非法输入被收敛到合法范围', () {
    final config = AutoClickConfig.fromJson(<String, dynamic>{
      'actions': <dynamic>[
        <String, dynamic>{
          'id': 'x',
          'type': 'tap',
          'x': 500,
          'y': -20,
          'durationMs': 1,
        },
      ],
      'intervalMs': 1,
      'randomDelayMs': -5,
      'repeat': 99999,
    });
    expect(config.actions.single.x, 100);
    expect(config.actions.single.y, 0);
    expect(config.actions.single.durationMs, 10);
    expect(config.intervalMs, 50);
    expect(config.randomDelayMs, 0);
    expect(config.repeat, 9999);
  });

  test('默认配置含一个示例点击，可保存到本机并读回', () async {
    final defaults = AutoClickConfig.defaults();
    expect(defaults.actions.single.type, AutoClickActionType.tap);
    expect(await AutoClickConfigStore.load(), isNotNull);

    final changed = defaults.copyWith(
      intervalMs: 1200,
      randomDelayMs: 300,
      repeat: 5,
    );
    await AutoClickConfigStore.save(changed);
    final loaded = await AutoClickConfigStore.load();
    expect(loaded.intervalMs, 1200);
    expect(loaded.randomDelayMs, 300);
    expect(loaded.repeat, 5);
    expect(loaded.toJson()['actions'], isA<List<dynamic>>());
  });
}
