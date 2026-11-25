import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_remote_index.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_common.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_remote_page.dart';
import '../support/test_env.dart';

const String _indexBody = '{"version":1,"files":['
    '{"id":"bank-1","title":"题库一","file":"题库一.json",'
    '"questions":725,"size":562240,'
    '"types":{"single":477,"multiple":98,"true_false":150}}]}';

QuizIndexService _serviceWith(String body) => QuizIndexService(
      client:
          MockClient((_) async => http.Response.bytes(utf8.encode(body), 200)),
    );

Future<QuizRepository> _openRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
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

  testWidgets('在线题库列出文件名/题数/题型/大小', (tester) async {
    final repo = await _openRepo();
    await tester.pumpWidget(MaterialApp(
      home: QuizRemotePage(
        repo: repo,
        service: _serviceWith(_indexBody),
        cache:
            QuizIndexCache(now: () => DateTime.fromMillisecondsSinceEpoch(0)),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('quiz-remote-list')), findsOneWidget);
    expect(find.text('题库一'), findsOneWidget);
    expect(find.text('题库一.json'), findsOneWidget);
    expect(find.textContaining('725 题'), findsOneWidget);
    expect(find.textContaining('单选 477'), findsOneWidget);
    expect(find.textContaining('多选 98'), findsOneWidget);
    expect(find.textContaining('判断 150'), findsOneWidget);
    expect(find.text('549 KB'), findsOneWidget);
  });
}
