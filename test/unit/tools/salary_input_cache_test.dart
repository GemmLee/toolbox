import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolbox/features/tools/salary/salary_input_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('输入快照存取往返，保留未完成的小数与比例文本', () async {
    const snapshot = SalaryInputSnapshot(
      cityId: 'ningbo',
      values: <String, String>{
        'gross': '12.',
        'socialBase': '',
        'personal.pension': '8',
      },
      cumulative: false,
      month: 7,
      ratesCustomized: true,
    );
    await SalaryInputCache.save(snapshot);
    final loaded = await SalaryInputCache.load();
    expect(loaded, isNotNull);
    expect(loaded!.cityId, 'ningbo');
    expect(loaded.valueOf('gross'), '12.');
    expect(loaded.valueOf('socialBase'), '');
    expect(loaded.valueOf(SalaryInputSnapshot.personalKey('pension')), '8');
    expect(loaded.cumulative, isFalse);
    expect(loaded.month, 7);
    expect(loaded.ratesCustomized, isTrue);
  });

  test('没有缓存时返回 null，clear 后不再恢复', () async {
    expect(await SalaryInputCache.load(), isNull);
    await SalaryInputCache.save(const SalaryInputSnapshot(
      cityId: 'hangzhou',
      values: <String, String>{'gross': '9000'},
    ));
    expect(await SalaryInputCache.load(), isNotNull);
    await SalaryInputCache.clear();
    expect(await SalaryInputCache.load(), isNull);
  });
}
