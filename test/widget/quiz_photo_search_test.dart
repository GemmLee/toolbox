import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/core/platform/ocr.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_photo_search_page.dart';
import '../support/test_env.dart';

Future<QuizRepository> openPhotoRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  final repo = QuizRepository(db);
  final bankId = await repo.createBank(name: '计算机网络');
  await repo.insertQuestions(<Question>[
    Question(
      id: 'q1',
      bankId: bankId,
      type: QuestionType.single,
      stem: 'TCP 三次握手的第二个报文是什么？',
      options: const <OptionItem>[
        OptionItem(key: 'A', text: 'SYN'),
        OptionItem(key: 'B', text: 'SYN+ACK'),
        OptionItem(key: 'C', text: 'ACK'),
        OptionItem(key: 'D', text: 'FIN'),
      ],
      answer: const <String>['B'],
      analysis: '服务端以 SYN+ACK 回应客户端。',
      orderNo: 1,
    ),
    Question(
      id: 'q2',
      bankId: bankId,
      type: QuestionType.single,
      stem: '下列哪个属于物理层设备？',
      options: const <OptionItem>[
        OptionItem(key: 'A', text: '集线器'),
        OptionItem(key: 'B', text: '交换机'),
      ],
      answer: const <String>['A'],
      orderNo: 2,
    ),
  ]);
  return repo;
}

OcrResult ocrOf(String text) => OcrResult(
      text: text,
      lines: <OcrLine>[
        OcrLine(text: text, left: 0, top: 0, width: 200, height: 20),
      ],
    );

void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  tearDown(restoreSystemLanguage);

  testWidgets('拍照后匹配到题目：显示题干、选项，正确答案标绿', (tester) async {
    final repo = await openPhotoRepo();
    OcrImageSource? source;
    await tester.pumpWidget(MaterialApp(
      home: QuizPhotoSearchPage(
        repo: repo,
        picker: (picked) async {
          source = picked;
          return '/no/such/image.png';
        },
        recognizer: (_) async =>
            ocrOf('2. TCP 三次握手的第二个报文是什么？\nA. SYN  B. SYN+ACK'),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('photo-search-camera')));
    await tester.pumpAndSettle();

    expect(source, OcrImageSource.camera);
    expect(find.byKey(const ValueKey('photo-search-result')), findsOneWidget);
    expect(find.text('TCP 三次握手的第二个报文是什么？'), findsOneWidget);
    expect(find.text('计算机网络'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('photo-search-answer')))
          .data,
      'B',
    );

    // 正确答案 B 有绿色底，A 没有。
    final correct = tester.widget<Container>(
      find.byKey(const ValueKey('photo-option-B')),
    );
    expect((correct.decoration as BoxDecoration?)?.color, isNotNull);
    final wrong = tester.widget<Container>(
      find.byKey(const ValueKey('photo-option-A')),
    );
    expect((wrong.decoration as BoxDecoration?)?.color, isNull);
  });

  testWidgets('题库里没有相似题时给出提示并可看识别文字', (tester) async {
    final repo = await openPhotoRepo();
    await tester.pumpWidget(MaterialApp(
      home: QuizPhotoSearchPage(
        repo: repo,
        picker: (_) async => '/no/such/image.png',
        recognizer: (_) async => ocrOf('今天天气不错，适合出门散步'),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('photo-search-gallery')));
    await tester.pumpAndSettle();

    expect(find.text('题库里没有找到这道题'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('photo-search-ocr-text')))
          .data,
      '今天天气不错，适合出门散步',
    );
  });

  testWidgets('识别不到文字时提示换图，不进入匹配', (tester) async {
    final repo = await openPhotoRepo();
    await tester.pumpWidget(MaterialApp(
      home: QuizPhotoSearchPage(
        repo: repo,
        picker: (_) async => '/no/such/image.png',
        recognizer: (_) async => const OcrResult(text: '', lines: <OcrLine>[]),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('photo-search-camera')));
    await tester.pumpAndSettle();

    expect(find.text('没有识别到文字，试试更清晰的图片'), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-search-result')), findsNothing);
  });
}
