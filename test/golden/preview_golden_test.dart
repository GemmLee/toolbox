import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/app.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/features/tools/builtin_tools.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_common.dart';
import '../support/test_env.dart';

/// 临时脚本：把关键页面渲染成 PNG，用于人工核对配色与间距。
/// 运行：flutter test test/_preview_golden_test.dart --update-goldens
Future<void> loadCjkFont() async {
  final bytes = File('C:/Windows/Fonts/NotoSansSC-VF.ttf').readAsBytesSync();
  final loader = FontLoader('Roboto')
    ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

Future<void> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  registerBuiltinTools();
  await tester.pumpWidget(const ToolboxApp());
  await tester.pumpAndSettle();
}

/// 预览用的题库样本：真实截图才有回归价值，不注入会渲染成 sqflite 报错页。
const List<String> _previewBanks = <String>[
  '''
{
  "version": 1,
  "bankName": "英语四级词汇",
  "questions": [
    {"id": "e1", "type": "single", "stem": "abandon 的意思是？",
     "options": [{"key": "A", "text": "放弃"}, {"key": "B", "text": "获得"},
                 {"key": "C", "text": "建议"}, {"key": "D", "text": "比较"}],
     "answer": ["A"], "analysis": "abandon 表示放弃、抛弃。"},
    {"id": "e2", "type": "trueFalse", "stem": "bargain 只能作名词使用。",
     "answer": ["false"], "analysis": "bargain 也可作动词，表示讨价还价。"}
  ]
}
''',
  '''
{
  "version": 1,
  "bankName": "计算机网络",
  "questions": [
    {"id": "n1", "type": "single", "stem": "TCP 三次握手的第二个报文是？",
     "options": [{"key": "A", "text": "SYN"}, {"key": "B", "text": "SYN+ACK"},
                 {"key": "C", "text": "ACK"}, {"key": "D", "text": "FIN"}],
     "answer": ["B"], "analysis": "服务端以 SYN+ACK 回应客户端。"},
    {"id": "n2", "type": "multiple", "stem": "下列属于传输层协议的有？",
     "options": [{"key": "A", "text": "TCP"}, {"key": "B", "text": "UDP"},
                 {"key": "C", "text": "IP"}, {"key": "D", "text": "ICMP"}],
     "answer": ["A", "B"], "analysis": "IP 与 ICMP 属于网络层。"}
  ]
}
''',
];

Future<void> seedQuizPreview() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  final repo = QuizRepository(db);
  for (final bank in _previewBanks) {
    await QuizImporter.commit(repo, QuizImporter.parse(bank));
  }
  QuizServices.testRepo = repo;
  addTearDown(QuizServices.reset);
}

void main() {
  setUpAll(loadCjkFont);
  // 金图只跑浅色 + 固定主题色，其余环境统一走夹具。
  setUp(() async {
    mockPrefs();
    await useChineseUi();
    await SettingsController.instance.setThemeMode(ThemeMode.light);
    await SettingsController.instance.setThemeColor('skyBlue');
  });

  testWidgets('preview: overview light', (tester) async {
    await pumpApp(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/01-overview-light.png'),
    );
  });

  testWidgets('preview: user light', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('用户'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/02-user-light.png'),
    );
  });

  testWidgets('preview: overview dark', (tester) async {
    SettingsController.instance.setThemeMode(ThemeMode.dark);
    await pumpApp(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/03-overview-dark.png'),
    );
  });

  testWidgets('preview: theme color page', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('用户'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题色'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/04-theme-color.png'),
    );
  });

  testWidgets('preview: quiz page', (tester) async {
    await seedQuizPreview();
    await pumpApp(tester);
    await tester.tap(find.text('刷题助手'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/05-quiz.png'),
    );
  });

  testWidgets('preview: quiz search tab', (tester) async {
    await seedQuizPreview();
    await pumpApp(tester);
    await tester.tap(find.text('刷题助手'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quiz-tab-search')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/07-quiz-search.png'),
    );
  });
}
