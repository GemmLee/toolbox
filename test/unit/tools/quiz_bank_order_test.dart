import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_backup_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';

Future<QuizRepository> openRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

Future<String> addBank(QuizRepository repo, String name, int createdAt) async {
  final id = await repo.createBank(name: name);
  await repo.db.update(
    'banks',
    <String, Object?>{'createdAt': createdAt},
    where: 'id = ?',
    whereArgs: <Object?>[id],
  );
  return id;
}

void main() {
  late QuizRepository repo;

  setUp(() async {
    repo = await openRepo();
  });

  Future<List<String>> names() async =>
      (await repo.listBanks()).map((b) => b.name).toList(growable: false);

  test('题库顺序：默认按导入时间倒序，自定义顺序持久化', () async {
    final a = await addBank(repo, 'A', 1000);
    final b = await addBank(repo, 'B', 2000);
    final c = await addBank(repo, 'C', 3000);
    expect(await names(), <String>['C', 'B', 'A']);

    await repo.saveBankOrder(<String>[a, c, b]);
    expect(await names(), <String>['A', 'C', 'B']);

    // 顺序里没记录的新题库排在末尾，不会打乱已有排序。
    await addBank(repo, 'D', 4000);
    expect(await names(), <String>['A', 'C', 'B', 'D']);

    // 删除题库后顺序里残留的 id 自动跳过。
    await repo.deleteBank(b);
    expect(await names(), <String>['A', 'C', 'D']);

    await repo.resetBankOrder();
    expect(await names(), <String>['D', 'C', 'A']);
  });

  test('顺序随整库备份导出 / 恢复', () async {
    final a = await addBank(repo, 'A', 1000);
    final b = await addBank(repo, 'B', 2000);
    final c = await addBank(repo, 'C', 3000);
    await repo.saveBankOrder(<String>[c, a, b]);

    final data = await QuizBackupRepository(repo.db).export();
    expect(jsonEncode(data), contains(QuizRepository.bankOrderKey));

    final restored = await openRepo();
    await QuizBackupRepository(restored.db).restore(data);
    expect(
      (await restored.listBanks()).map((bank) => bank.name).toList(),
      <String>['C', 'A', 'B'],
    );
  });
}
