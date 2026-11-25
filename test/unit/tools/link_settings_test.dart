import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/features/tools/link_parser/link_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LinkSettingsStore.resetForTest();
  });

  test('默认保存到应用存储空间，限速为不限', () {
    const settings = LinkSettings();
    expect(settings.saveTarget, LinkSaveTarget.appStorage);
    expect(settings.toPhone, isFalse);
    expect(settings.speedLimitBps, 0);
    expect(settings.threads, 4);
    expect(settings.concurrency, 2);
  });

  test('JSON 往返保留每一项，非法值夹到合法区间', () {
    const settings = LinkSettings(
      saveTarget: LinkSaveTarget.phone,
      phoneDir: 'Toolbox/视频',
      threads: 8,
      concurrency: 3,
      speedLimitBps: 1048576,
      retries: 2,
    );
    final restored = LinkSettings.fromJson(
      jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
    );
    expect(restored.saveTarget, LinkSaveTarget.phone);
    expect(restored.phoneDir, 'Toolbox/视频');
    expect(restored.threads, 8);
    expect(restored.concurrency, 3);
    expect(restored.speedLimitBps, 1048576);
    expect(restored.retries, 2);

    final clamped = LinkSettings.fromJson(const <String, dynamic>{
      'threads': 99,
      'concurrency': 0,
      'retries': -1,
    });
    expect(clamped.threads, 16);
    expect(clamped.concurrency, 1);
    expect(clamped.retries, 0);
  });

  test('保存后 current 立即变化，重新读取拿到同一份', () async {
    await LinkSettingsStore.save(
      const LinkSettings(saveTarget: LinkSaveTarget.phone, concurrency: 3),
    );
    expect(LinkSettingsStore.current.value.toPhone, isTrue);

    LinkSettingsStore.resetForTest();
    final loaded = await LinkSettingsStore.load();
    expect(loaded.toPhone, isTrue);
    expect(loaded.concurrency, 3);
    expect(LinkSettingsStore.current.value.concurrency, 3);
  });

  test('手机目录路径补齐 Download 前缀并过滤非法段', () {
    expect(phoneRelativeDir('Toolbox/链接解析'), 'Download/Toolbox/链接解析');
    expect(phoneRelativeDir('Download/Movies'), 'Download/Movies');
    expect(phoneRelativeDir('/Toolbox//A/'), 'Download/Toolbox/A');
    expect(phoneRelativeDir('../etc'), 'Download/etc');
    expect(phoneRelativeDir(''), 'Download');
  });
}
