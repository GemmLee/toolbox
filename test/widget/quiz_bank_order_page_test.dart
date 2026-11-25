import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_common.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_page.dart';
import '../support/test_env.dart';

Future<QuizRepository> openRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  final repo = QuizRepository(db);
  for (var i = 0; i < 3; i++) {
    final id = await repo.createBank(name: <String>['A', 'B', 'C'][i]);
    await db.update(
      'banks',
      <String, Object?>{'createdAt': 1000 + i * 1000},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }
  return repo;
}

void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  tearDown(() {
    QuizServices.reset();
    restoreSystemLanguage();
  });

  testWidgets('题库行有排序入口，拖动回调立即持久化，重置恢复默认顺序', (tester) async {
    final repo = await openRepo();
    QuizServices.testRepo = repo;
    await tester.pumpWidget(const MaterialApp(home: QuizPage()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('quiz-bank-order')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quiz-bank-order')));
    await tester.pumpAndSettle();

    expect(find.text('题库顺序'), findsOneWidget);
    expect(find.byKey(const ValueKey('bank-order-list')), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));

    final list =
        tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    list.onReorder(0, 3); // 默认顺序是 C/B/A，把第一项 C 拖到末尾
    await tester.pumpAndSettle();
    expect(
      (await repo.listBanks()).map((b) => b.name).toList(),
      <String>['B', 'A', 'C'],
    );

    await tester.tap(find.byKey(const ValueKey('bank-order-reset')));
    await tester.pumpAndSettle();
    expect(
      (await repo.listBanks()).map((b) => b.name).toList(),
      <String>['C', 'B', 'A'],
    );
  });
}
