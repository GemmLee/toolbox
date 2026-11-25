import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_folders.dart';

Future<QuizRepository> _openRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

void main() {
  group('题库分类文件夹', () {
    test('新建 / 归属 / 折叠状态随仓库持久化', () async {
      final repo = await _openRepo();
      final a = await repo.createBank(name: 'A');
      final b = await repo.createBank(name: 'B');
      final banks = <Bank>[
        Bank(id: a, name: 'A'),
        Bank(id: b, name: 'B'),
      ];
      const folder = QuizFolder(id: 'f1', name: '理科');

      await QuizFoldersData.save(
        repo,
        QuizFoldersData(
          folders: <QuizFolder>[folder],
          assign: <String, String>{a: 'f1'},
        ),
      );

      final loaded = await QuizFoldersData.load(repo);
      expect(loaded.folders.single.name, '理科');
      expect(loaded.folders.single.expanded, isTrue);
      expect(loaded.folderIdOf(a), 'f1');
      expect(loaded.folderIdOf(b), isNull);
      expect(loaded.banksOf('f1', banks).map((e) => e.id), <String>[a]);
      expect(loaded.banksOf(null, banks).map((e) => e.id), <String>[b]);

      // 折叠状态单独保存，下次进入仍是收起的。
      await QuizFoldersData.save(
          repo,
          loaded.copyWith(
            folders: <QuizFolder>[folder.copyWith(expanded: false)],
            uncategorizedExpanded: false,
          ));
      final again = await QuizFoldersData.load(repo);
      expect(again.folders.single.expanded, isFalse);
      expect(again.uncategorizedExpanded, isFalse);
    });

    test('删文件夹时移除归属，题库本身不删除；坏 JSON 安全兜底', () async {
      final repo = await _openRepo();
      final id = await repo.createBank(name: 'A');
      final data = QuizFoldersData(
        folders: <QuizFolder>[
          const QuizFolder(id: 'f1', name: '理科'),
          const QuizFolder(id: 'f2', name: '文科'),
        ],
        assign: <String, String>{id: 'f1'},
      );
      final assign = Map<String, String>.from(data.assign)
        ..removeWhere((_, value) => value == 'f1');
      final after = data.copyWith(
        folders: data.folders.where((f) => f.id != 'f1').toList(),
        assign: assign,
      );
      await QuizFoldersData.save(repo, after);

      final loaded = await QuizFoldersData.load(repo);
      expect(loaded.folders.map((f) => f.id), <String>['f2']);
      expect(loaded.folderIdOf(id), isNull);
      expect((await repo.listBanks()).single.id, id, reason: '题库仍在');

      await repo.setSetting(QuizFoldersData.storeKey, '{not json');
      expect(await QuizFoldersData.load(repo), isA<QuizFoldersData>());
      expect((await QuizFoldersData.load(repo)).folders, isEmpty);
    });
  });
}
