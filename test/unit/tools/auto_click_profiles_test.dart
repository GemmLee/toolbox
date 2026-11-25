import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/features/tools/autoclick/auto_click_models.dart';
import 'package:toolbox/features/tools/autoclick/auto_click_profiles.dart';

AutoClickProfile _profile(String id, String name, {int updatedAt = 1}) =>
    AutoClickProfile(
      id: id,
      name: name,
      updatedAt: updatedAt,
      config: AutoClickConfig(
        intervalMs: 300 + updatedAt,
        actions: <AutoClickAction>[
          AutoClickAction(id: 'a-$id', x: 10.0 + updatedAt, y: 20),
        ],
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('方案 JSON 往返保留名称、配置与动作', () {
    final p = _profile('1', '每日签到', updatedAt: 5);
    final restored = AutoClickProfile.fromJson(p.toJson());
    expect(restored.id, '1');
    expect(restored.name, '每日签到');
    expect(restored.updatedAt, 5);
    expect(restored.config.intervalMs, 305);
    expect(restored.config.actions.single.x, 15);
  });

  test('首次加载把旧单配置迁移成默认方案', () async {
    await AutoClickConfigStore.save(
      const AutoClickConfig(intervalMs: 777),
    );
    final profiles = await AutoClickProfileStore.load();
    expect(profiles, hasLength(1));
    expect(profiles.first.name, AutoClickProfileStore.defaultName);
    expect(profiles.first.config.intervalMs, 777);
    final active = await AutoClickProfileStore.activeIdOf(profiles);
    expect(active, profiles.first.id);
  });

  test('无旧配置时给出一套默认方案', () async {
    final profiles = await AutoClickProfileStore.load();
    expect(profiles, hasLength(1));
    expect(profiles.first.config.actions, isNotEmpty);
  });

  test('保存多方案后按修改时间倒序读回，激活 id 保留', () async {
    final list = <AutoClickProfile>[
      _profile('a', 'A', updatedAt: 100),
      _profile('b', 'B', updatedAt: 300),
      _profile('c', 'C', updatedAt: 200),
    ];
    await AutoClickProfileStore.save(list, 'c');
    final loaded = await AutoClickProfileStore.load();
    expect(loaded.map((p) => p.id), <String>['b', 'c', 'a']);
    expect(await AutoClickProfileStore.activeIdOf(loaded), 'c');
  });

  test('导出再解析得到完整方案', () {
    final list = <AutoClickProfile>[
      _profile('a', 'A', updatedAt: 100),
      _profile('b', 'B', updatedAt: 200),
    ];
    final json = AutoClickProfileStore.exportJson(list, 'b');
    final decoded = AutoClickProfileStore.parseJson(json);
    expect(decoded, hasLength(2));
    expect(decoded.first.name, 'A');
    expect(decoded.last.config.intervalMs, 500);
  });

  test('解析坏 JSON / 空方案抛 FormatException', () {
    expect(
      () => AutoClickProfileStore.parseJson('not json'),
      throwsFormatException,
    );
    expect(
      () => AutoClickProfileStore.parseJson('{"profiles": []}'),
      throwsFormatException,
    );
    expect(
      () => AutoClickProfileStore.parseJson('{"profiles": [1, 2]}'),
      throwsFormatException,
    );
  });

  test('导入重新分配 id 且同名加后缀，不与现有冲突', () async {
    await AutoClickProfileStore.save(<AutoClickProfile>[_profile('x', 'A')], 'x');
    final json = AutoClickProfileStore.exportJson(
      <AutoClickProfile>[_profile('imp', 'A'), _profile('imp2', 'B')],
      'imp',
    );
    final ids = await AutoClickProfileStore.import(json);
    expect(ids, hasLength(2));
    final after = await AutoClickProfileStore.load();
    expect(after, hasLength(3));
    final names = after.map((p) => p.name).toList();
    expect(names, contains('A'));
    expect(names, contains('A（导入）'));
    expect(names, contains('B'));
    // id 全部重分配，不含导入文件里的原 id。
    expect(after.map((p) => p.id), isNot(contains('imp')));
  });

  test('create 生成唯一 id 与默认名', () {
    final a = AutoClickProfileStore.create('', AutoClickConfig.defaults());
    final b = AutoClickProfileStore.create('X', AutoClickConfig.defaults());
    expect(a.name, AutoClickProfileStore.defaultName);
    expect(b.name, 'X');
    expect(a.id, isNot(b.id));
  });
}
