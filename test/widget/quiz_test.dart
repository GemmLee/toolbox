import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/core/platform/keep_awake.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/features/tools/assistant/data/assistant_api.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_ai_convert.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_ai_explainer.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_folders.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_import.dart';
import 'package:toolbox/features/tools/quiz/ui/bank_detail_page.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_ai_import_page.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_ai_panel.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_answer_page.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_common.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_excel_import_page.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_question_detail.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_question_edit_page.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_page.dart';
import 'package:toolbox/features/tools/quiz/ui/quiz_practice_page.dart';
import 'package:toolbox/features/tools/quiz/state/quiz_conversion_controller.dart';
import 'package:toolbox/features/tools/quiz/state/quiz_session_controller.dart';
import '../support/test_env.dart';

// ---------- 测试夹具 ----------

/// 演示题库：2 题（单选 + 判断）。第一题用于验证「答错后给出正确答案与解析」。
const String kBank = '''
{
  "version": 1,
  "bankName": "演示题库",
  "questions": [
    {
      "id": "q1",
      "type": "single",
      "stem": "1 + 1 等于多少？",
      "options": [
        {"key": "A", "text": "1"},
        {"key": "B", "text": "2"}
      ],
      "answer": ["B"],
      "analysis": "基础加法"
    },
    {
      "id": "q2",
      "type": "trueFalse",
      "stem": "地球是圆的。",
      "answer": ["true"]
    }
  ]
}
''';

/// 生成 [count] 道单选题，用来验证大题量下的答题卡分页。
String _bigBank(int count) => jsonEncode(<String, dynamic>{
      'version': 1,
      'bankName': '大题库',
      'questions': <Map<String, dynamic>>[
        for (var i = 1; i <= count; i++)
          <String, dynamic>{
            'id': 'q$i',
            'type': 'single',
            'stem': '题目 $i',
            'options': <Map<String, String>>[
              <String, String>{'key': 'A', 'text': 'A'},
              <String, String>{'key': 'B', 'text': 'B'},
            ],
            'answer': <String>['B'],
          },
      ],
    });

/// 单选题库之外的一道多选题，用于验证「一键全选」。
String _multiBank() => jsonEncode(<String, dynamic>{
      'version': 1,
      'bankName': '多选题库',
      'questions': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'm1',
          'type': 'multiple',
          'stem': '以下哪些是偶数？',
          'options': <Map<String, String>>[
            <String, String>{'key': 'A', 'text': '2'},
            <String, String>{'key': 'B', 'text': '3'},
            <String, String>{'key': 'C', 'text': '4'},
          ],
          'answer': <String>['A', 'C'],
        },
      ],
    });

/// 打开一个独立的内存库，每个用例互不影响（widget 测试用 no-isolate 工厂）。
Future<QuizRepository> openRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

/// 题目 AI 解析用的样例题。
const Question _question = Question(
  id: 'q1',
  bankId: 'bank-1',
  type: QuestionType.single,
  stem: '水的沸点在标准大气压下是多少？',
  options: <OptionItem>[
    OptionItem(key: 'A', text: '90℃'),
    OptionItem(key: 'B', text: '100℃'),
  ],
  answer: <String>['B'],
  contentHash: 'hash-1',
);

/// 配置一套可用的 AI；[apiKey] 传空串即模拟「未配置」。
void _configureAi({String apiKey = 'sk-test'}) {
  final settings = SettingsController.instance;
  settings.resetForTest();
  settings.setLanguage(AppLanguage.simplifiedChinese);
  settings.addAssistantProfile(
    name: 'test',
    baseUrl: 'https://api.example.com/v1',
    model: 'test-model',
    apiKey: apiKey,
  );
}

/// 造一个 OpenAI 兼容的 SSE 流；[data] 为单个文本或分片列表。
http.StreamedResponse _sse(Object data) {
  final parts = data is List
      ? data.map((e) => '$e').toList(growable: false)
      : <String>['$data'];
  final body = StringBuffer();
  for (final part in parts) {
    final payload = jsonEncode(<String, dynamic>{
      'choices': <Map<String, dynamic>>[
        <String, dynamic>{
          'index': 0,
          'delta': <String, dynamic>{'content': part},
        },
      ],
    });
    body.write('data: $payload\n\n');
  }
  body.write('data: [DONE]\n\n');
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body.toString())),
    200,
    headers: <String, String>{'content-type': 'text/event-stream'},
  );
}

/// AI 返回的题库 JSON（2 题，题库名「AI题库」）。
const String _bankJson = '''
{
  "version": 1,
  "bankName": "AI题库",
  "questions": [
    {
      "id": "a1",
      "type": "single",
      "stem": "1+1=?",
      "options": [
        {"key": "A", "text": "1"},
        {"key": "B", "text": "2"}
      ],
      "answer": ["B"]
    },
    {
      "id": "a2",
      "type": "fill",
      "stem": "中国的首都是____。",
      "answer": ["北京"]
    }
  ]
}
''';

/// 假的转换器：先报 40% 进度，等测试放行后返回预设结果或抛出预设错误。
class _FakeConverter extends QuizAiConverter {
  _FakeConverter({this.result, this.error});

  final QuizConvertResult? result;
  final String? error;
  final Completer<void> gate = Completer<void>();

  @override
  Future<QuizConvertResult> convert(
    String text, {
    void Function(QuizConvertProgress progress)? onProgress,
    bool Function()? cancelled,
  }) async {
    onProgress?.call(
      const QuizConvertProgress(
        fraction: 0.4,
        label: '转换中…',
        done: 1,
        total: 3,
      ),
    );
    await gate.future;
    if (error != null) throw QuizConvertException(error!);
    return result!;
  }
}

/// 在内存里构造一个最小 xlsx（inlineStr），供 Excel 导入页面测试使用。
List<int> _xlsxBytes(List<List<String>> rows) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final sheet = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/'
        'spreadsheetml/2006/main"><sheetData>');
  for (var r = 0; r < rows.length; r++) {
    sheet.write('<row r="${r + 1}">');
    for (var c = 0; c < rows[r].length; c++) {
      final value = rows[r][c];
      if (value.isEmpty) continue;
      final ref = '${String.fromCharCode(65 + c)}${r + 1}';
      sheet.write('<c r="$ref" t="inlineStr"><is><t xml:space="preserve">'
          '${esc(value)}</t></is></c>');
    }
    sheet.write('</row>');
  }
  sheet.write('</sheetData></worksheet>');
  final archive = Archive()
    ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', sheet.toString()));
  return ZipEncoder().encode(archive);
}

Future<QuizRepository> _openRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

/// 中文本地化下 pageBack 找不到英文提示，直接点 AppBar 返回按钮。
Future<void> goBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton).first);
  await tester.pumpAndSettle();
}

/// 卡片首页较高时，把下方的「记录」区滚进可视区域。
Future<void> scrollToRecords(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    320,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 20,
  );
  await tester.pumpAndSettle();
}

Future<void> tapCard(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  // ---------- 题库页面 ----------
  late QuizRepository repo;

  setUp(() async {
    mockPrefs();
    await useChineseUi();
    repo = await openRepo();
    QuizServices.testRepo = repo;
    // 转换控制器是进程级单例，用例之间必须清空，避免状态串场。
    QuizConversionController.instance.resetForTest();
    KeepAwake.resetForTest();
  });

  tearDown(() async {
    QuizConversionController.instance.resetForTest();
    KeepAwake.resetForTest();
    QuizServices.reset();
    QuizAiService.instance = QuizAiService();
    await restoreSystemLanguage();
  });

  testWidgets('首页：空态与入口', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: QuizPage()));
    await tester.pumpAndSettle();

    // 工具改名为「刷题助手」，首页只有搜索 / 设置；导入统一走题库行入口
    expect(find.text('刷题助手'), findsWidgets);
    expect(find.textContaining('还没有题库'), findsOneWidget);
    expect(find.byKey(const ValueKey('quiz-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('quiz-import')), findsNothing);
  });

  testWidgets('导入题库后以题库卡片呈现，可二次确认删除', (tester) async {
    final preview = QuizImporter.parse(kBank);
    await QuizImporter.commit(repo, preview);

    await tester.pumpWidget(const MaterialApp(home: QuizPage()));
    await tester.pumpAndSettle();

    expect(find.text('演示题库'), findsOneWidget);
    // 每个题库自带错题 / 收藏计数
    expect(find.textContaining('共 2 题 · 错题 0 · 收藏 0'), findsOneWidget);

    // 删除需二次确认
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除题库'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('删除后该题库的错题、收藏与考试记录都会一并删除'),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await repo.listBanks()).length, 1);
  });

  testWidgets('题库菜单提供导出入口', (tester) async {
    await QuizImporter.commit(repo, QuizImporter.parse(kBank));

    await tester.pumpWidget(const MaterialApp(home: QuizPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bank-export')), findsOneWidget);
    expect(find.text('导出题库'), findsOneWidget);
    expect(find.byKey(const ValueKey('bank-export-excel')), findsOneWidget);
    expect(find.text('导出 Excel'), findsOneWidget);
  });

  testWidgets('题库详情：卡片入口与记录都在题库内部，空态各自独立', (tester) async {
    final preview = QuizImporter.parse(kBank);
    final result = await QuizImporter.commit(repo, preview);
    await repo.addWrong(
        result.bankId, (await repo.questionsOfBank(result.bankId)).first.id);
    final bank = (await repo.listBanks()).first;

    await tester
        .pumpWidget(MaterialApp(home: BankDetailPage(repo: repo, bank: bank)));
    await tester.pumpAndSettle();

    // 卡片首页：统计 2×2 在左，预览 / 错题竖排右侧，收藏 / 笔记另起一行
    expect(find.byKey(const ValueKey('bank-card-stats')), findsOneWidget);
    expect(find.byKey(const ValueKey('bank-card-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('bank-card-wrong')), findsOneWidget);
    expect(find.byKey(const ValueKey('bank-card-favorite')), findsOneWidget);
    expect(find.byKey(const ValueKey('bank-card-notes')), findsOneWidget);
    expect(find.text('共 2 题'), findsOneWidget);
    expect(find.text('1 道错题'), findsOneWidget);
    expect(find.text('收藏 0 题'), findsOneWidget);
    expect(find.text('0 条笔记'), findsOneWidget);

    final big = tester.getSize(find.byKey(const ValueKey('bank-card-stats')));
    final small =
        tester.getSize(find.byKey(const ValueKey('bank-card-preview')));
    // 2×2 大卡 = 两个小卡 + 中间 gap；三列网格下 gap 占比使面积比略大于 4。
    const gridGap = 10.0;
    expect(big.width, closeTo(small.width * 2 + gridGap, 0.5));
    expect(big.height, closeTo(small.height * 2 + gridGap, 0.5));
    expect(big.width / small.width, closeTo(2, 0.15));
    expect(big.height / small.height, closeTo(2, 0.15));

    await tapCard(tester, 'bank-card-wrong');
    expect(find.text('开始错题练习'), findsOneWidget);
    await goBack(tester);

    await tapCard(tester, 'bank-card-favorite');
    expect(find.text('这个题库还没有收藏'), findsOneWidget);
    await goBack(tester);

    await tapCard(tester, 'bank-card-stats');
    expect(find.text('统计详情'), findsOneWidget);
    expect(find.text('刷题进度'), findsOneWidget);
    await goBack(tester);

    await tapCard(tester, 'bank-card-preview');
    expect(find.text('题库预览'), findsWidgets);
    expect(find.text('1 + 1 等于多少？'), findsOneWidget);
  });

  testWidgets('窄屏（360dp）下题库卡片与详情页不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final preview = QuizImporter.parse(kBank);
    final result = await QuizImporter.commit(repo, preview);
    await repo.addWrong(
        result.bankId, (await repo.questionsOfBank(result.bankId)).first.id);

    await tester.pumpWidget(const MaterialApp(home: QuizPage()));
    await tester.pumpAndSettle();
    expect(find.text('演示题库'), findsOneWidget);

    await tester.tap(find.text('演示题库'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bank-card-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('bank-card-stats')), findsOneWidget);
    expect(find.byKey(const ValueKey('bank-exam')), findsOneWidget);
  });

  testWidgets('练习设置：框获得焦点后隐藏占位 0，输入数字不会与 0 重叠', (tester) async {
    final preview = QuizImporter.parse(kBank);
    final result = await QuizImporter.commit(repo, preview);

    await tester.pumpWidget(MaterialApp(
      home: QuizConfigPage(repo: repo, bankId: result.bankId),
    ));
    await tester.pumpAndSettle();

    // 随机模式才需要填抽题数量
    await tester.tap(find.byKey(const ValueKey('mode-random')));
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('count-single'));
    expect(field, findsOneWidget);
    // 初始应为空字符串（"0" 只作为 hintText 显示），否则会和光标叠在一起
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(tester.widget<TextField>(field).decoration!.hintText, '0');

    // 点进输入框出现光标后，灰色 0 立即消失
    await tester.tap(field);
    await tester.pump();
    expect(tester.widget<TextField>(field).decoration!.hintText, isNull);

    await tester.enterText(field, '3');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '3');

    // 再输入其他题型，两个框互不影响
    await tester.enterText(find.byKey(const ValueKey('count-multiple')), '2');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '3');
  });

  testWidgets('随机练习：只刷没做过的题开关与剩余题量', (tester) async {
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final questions = await repo.questionsOfBank(result.bankId);
    // 先做完一道单选，另一道判断仍算「没做过」。
    final c = QuizSessionController(repo);
    await c.start(bankId: result.bankId, mode: QuizMode.all);
    await c.answer(questions.first.id, <String>['A']);
    c.dispose();

    await tester.pumpWidget(MaterialApp(
      home: QuizConfigPage(repo: repo, bankId: result.bankId),
    ));
    await tester.pumpAndSettle();

    const switchKey = ValueKey('config-only-unseen');
    expect(find.byKey(switchKey), findsOneWidget, reason: '练习模式都显示该开关');
    await tester.tap(find.byKey(const ValueKey('mode-random')));
    await tester.pumpAndSettle();
    expect(find.byKey(switchKey), findsOneWidget);
    expect(find.text('库存 1 题'), findsNWidgets(2));

    await tester.tap(find.byKey(switchKey));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(switchKey)).value, isTrue);
    expect(find.text('未做 1 题'), findsOneWidget, reason: '开关打开后抽题库存改为「未做」口径');
    expect(find.text('库存 1 题'), findsNothing);

    // 开始按钮能带着 onlyUnseen 真正建起会话，且只有没做过的那道题。
    await tester.tap(find.byKey(const ValueKey('config-start')));
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 1 题'), findsOneWidget);
    final session = (await repo.sessionsOfBank(result.bankId))
        .firstWhere((s) => s.mode == QuizMode.random);
    expect(session.config.onlyUnseen, isTrue);
  });

  testWidgets('随机练习：没做过的题刷完时给出提示；考试模式不显示开关', (tester) async {
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final questions = await repo.questionsOfBank(result.bankId);
    final c = QuizSessionController(repo);
    await c.start(bankId: result.bankId, mode: QuizMode.all);
    for (final q in questions) {
      await c.answer(q.id, <String>['A']);
    }
    c.dispose();

    await tester.pumpWidget(MaterialApp(
      home: QuizConfigPage(repo: repo, bankId: result.bankId),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-random')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('config-only-unseen')));
    await tester.pumpAndSettle();
    expect(find.text('没做过的题已刷完，关闭该选项可重新练习'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('config-start')));
    await tester.pumpAndSettle();
    expect(find.text('没做过的题已刷完，关闭该选项可重新练习'), findsWidgets);
    expect(find.text('第 1 / 2 题'), findsNothing);

    // 卸载旧的配置页，避免 State 被新树复用（否则 _mode 仍是随机）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(
      home: QuizConfigPage(repo: repo, bankId: result.bankId, exam: true),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('config-only-unseen')), findsOneWidget);
  });

  testWidgets('答题页视觉：主题色渐变背景、已答进度条与选项描边行', (tester) async {
    final preview = QuizImporter.parse(kBank);
    final result = await QuizImporter.commit(repo, preview);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: OutlinedButton(
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => QuizConfigPage(
                    repo: repo,
                    bankId: result.bankId,
                    initialMode: QuizMode.all,
                  ),
                ));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 关闭题目乱序，保证第 1 题是单选 1+1
    await tester
        .ensureVisible(find.byKey(const ValueKey('config-shuffle-questions')));
    await tester.tap(find.byKey(const ValueKey('config-shuffle-questions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('config-start')));
    await tester.pumpAndSettle();

    // 渐变背景与进度条都在树上
    expect(find.byType(QuizBackdrop), findsOneWidget);
    final progress =
        tester.widget<QuizProgressBar>(find.byType(QuizProgressBar));
    expect(progress.answered, 0);
    expect(progress.total, 2);

    // 进度条在 AppBar 的 bottom 里（LinearProgressIndicator 一条）
    final bar = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, 0);

    // 题干回到纯文本（不再套强调卡），选项行只留一圈细描边
    final stemFinder = find.text('1 + 1 等于多少？');
    expect(stemFinder, findsOneWidget);
    expect(tester.widget<Text>(stemFinder).style?.fontWeight, FontWeight.w600);

    final optionRow =
        tester.widget<Container>(find.byKey(const ValueKey('opt-bg-A')));
    final decoration = optionRow.decoration! as BoxDecoration;
    expect(decoration.border, isNotNull);
    // 未作答时只有描边，不铺底色
    expect(decoration.color, isNull);

    // 答一题后进度推进 1/2
    await tester.tap(find.byKey(const ValueKey('opt-A')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('answer-confirm')));
    await tester.pumpAndSettle();
    final progress2 =
        tester.widget<QuizProgressBar>(find.byType(QuizProgressBar));
    expect(progress2.answered, 1);
  });

  testWidgets('答题页：练习确认后显示答案与解析，答题卡可跳题', (tester) async {
    final preview = QuizImporter.parse(kBank);
    final result = await QuizImporter.commit(repo, preview);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: OutlinedButton(
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => QuizConfigPage(
                    repo: repo,
                    bankId: result.bankId,
                    initialMode: QuizMode.all,
                  ),
                ));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 关闭题目乱序，保证第 1 题是单选 1+1
    await tester
        .ensureVisible(find.byKey(const ValueKey('config-shuffle-questions')));
    await tester.tap(find.byKey(const ValueKey('config-shuffle-questions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('config-start')));
    await tester.pumpAndSettle();

    expect(find.text('第 1 / 2 题'), findsOneWidget);
    // 选 A（错误答案）并确认 → 显示正确答案与解析
    await tester.tap(find.byKey(const ValueKey('opt-A')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('answer-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('正确答案：B'), findsOneWidget);
    expect(find.text('基础加法'), findsOneWidget);

    // 收藏第 1 题：「答错 + 收藏」完全靠颜色叠加区分（红底 + 深色粗边框）
    await tester.tap(find.byKey(const ValueKey('answer-favorite')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('answer-sheet')));
    await tester.pumpAndSettle();
    expect(find.text('答题卡'), findsOneWidget);

    BoxDecoration cellDeco(int i) => tester
        .widget<Container>(find.byKey(ValueKey<String>('sheet-$i')))
        .decoration! as BoxDecoration;
    final theme =
        Theme.of(tester.element(find.byKey(const ValueKey('sheet-0'))));

    final combined = cellDeco(0);
    expect(combined.color, Colors.red.withOpacity(0.38));
    expect((combined.border! as Border).top.color, theme.colorScheme.onSurface);
    expect((combined.border! as Border).top.width, 2.5);
    expect(combined.boxShadow, isNotNull); // 当前题的主题色外圈
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sheet-0')),
        matching: find.byType(Icon),
      ),
      findsNothing, // 星标 / 错题角标已移除
    );
    expect(tester.getSize(find.byKey(const ValueKey('sheet-0'))),
        const Size(34, 34));

    final plain = cellDeco(1);
    expect(plain.color, theme.colorScheme.outline.withOpacity(0.10));
    expect((plain.border! as Border).top.width, 1);
    expect(plain.boxShadow, isNull);

    // 答题卡跳到第 2 题
    await tester.tap(find.byKey(const ValueKey('sheet-1')));
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 2 题'), findsOneWidget);
  });

  testWidgets('多选题：一键全选 / 清空全选', (tester) async {
    final result =
        await QuizImporter.commit(repo, QuizImporter.parse(_multiBank()));
    final controller = QuizSessionController(repo);
    expect(
      await controller.start(
        bankId: result.bankId,
        mode: QuizMode.all,
        config: const QuizConfig(shuffleQuestions: false),
      ),
      isTrue,
    );

    await tester.pumpWidget(MaterialApp(
      home: QuizAnswerPage(repo: repo, controller: controller),
    ));
    await tester.pumpAndSettle();

    bool checked(String key) => tester
        .widget<CheckboxListTile>(find.byKey(ValueKey<String>('opt-$key')))
        .value!;

    expect(find.text('一键全选'), findsOneWidget);
    expect(<bool>[checked('A'), checked('B'), checked('C')],
        <bool>[false, false, false]);

    // 按钮在选项下方，且与最后一个选项留有距离。
    final lastOptionBottom =
        tester.getBottomLeft(find.byKey(const ValueKey<String>('opt-C'))).dy;
    final buttonTop =
        tester.getTopLeft(find.byKey(const ValueKey('opt-select-all'))).dy;
    expect(buttonTop, greaterThan(lastOptionBottom));
    expect(buttonTop - lastOptionBottom, greaterThanOrEqualTo(8));

    await tester.tap(find.byKey(const ValueKey('opt-select-all')));
    await tester.pumpAndSettle();
    expect(<bool>[checked('A'), checked('B'), checked('C')],
        <bool>[true, true, true]);
    expect(find.text('清空全选'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('opt-select-all')));
    await tester.pumpAndSettle();
    expect(<bool>[checked('A'), checked('B'), checked('C')],
        <bool>[false, false, false]);
    expect(find.text('一键全选'), findsOneWidget);
  });

  testWidgets('答题页可编辑当前题，保存后立即显示新题干', (tester) async {
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final controller = QuizSessionController(repo);
    expect(
      await controller.start(
        bankId: result.bankId,
        mode: QuizMode.all,
        config: const QuizConfig(shuffleQuestions: false),
      ),
      isTrue,
    );

    await tester.pumpWidget(MaterialApp(
      home: QuizAnswerPage(repo: repo, controller: controller),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('answer-edit')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('answer-edit')));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionEditPage), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('question-edit-stem')), '改过的题干');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('question-edit-save')));
    await tester.pumpAndSettle();

    expect(find.byType(QuestionEditPage), findsNothing);
    expect(find.text('改过的题干'), findsOneWidget);
    final reread = await repo.questionById(controller.current!.id);
    expect(reread!.stem, '改过的题干');
  });

  testWidgets('答题卡：格子缩小后每栏 80 题，可滚动且能跳到任意题', (tester) async {
    final result =
        await QuizImporter.commit(repo, QuizImporter.parse(_bigBank(173)));
    final controller = QuizSessionController(repo);
    expect(
      await controller.start(
        bankId: result.bankId,
        mode: QuizMode.all,
        config: const QuizConfig(shuffleQuestions: false),
      ),
      isTrue,
    );
    // 从第 85 题打开答题卡，应直接落在 81-160 栏。
    controller.goTo(84);

    await tester.pumpWidget(MaterialApp(
      home: QuizAnswerPage(repo: repo, controller: controller),
    ));
    await tester.pumpAndSettle();
    expect(find.text('第 85 / 173 题'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('answer-sheet')));
    await tester.pumpAndSettle();

    // 173 题只需 3 栏（此前 40 题一栏要 5 栏），打开即定位到当前栏
    expect(find.byKey(const ValueKey('answer-sheet-scroll')), findsOneWidget);
    expect(find.text('1-80'), findsOneWidget);
    expect(find.text('81-160'), findsOneWidget);
    expect(find.text('161-173'), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-group-3')), findsNothing);
    expect(find.byKey(const ValueKey('sheet-80')), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-159')), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-160')), findsNothing);
    expect(find.byKey(const ValueKey('sheet-0')), findsNothing);

    // 答题卡支持左右滑动翻栏：右滑回上一栏、左滑去下一栏。
    await tester.drag(
      find.byKey(const ValueKey('answer-sheet-pager')),
      const Offset(520, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-79')), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-80')), findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('answer-sheet-pager')),
      const Offset(-520, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-80')), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-0')), findsNothing);

    await tester.tap(find.text('1-80'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-79')), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-80')), findsNothing);

    await tester.tap(find.text('161-173'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-160')), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-172')), findsOneWidget);

    // 最后一栏的题号同样可以点击跳题
    await tester.tap(find.byKey(const ValueKey('sheet-164')));
    await tester.pumpAndSettle();
    expect(find.text('第 165 / 173 题'), findsOneWidget);

    // 卸载页面即可释放控制器与其计时器（页面负责 dispose）。
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('记录栏：长按可删除误点产生的记录', (tester) async {
    final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
    final c = QuizSessionController(repo);
    await c.start(bankId: result.bankId, mode: QuizMode.all);
    c.dispose();

    final bank = (await repo.listBanks()).first;
    await tester
        .pumpWidget(MaterialApp(home: BankDetailPage(repo: repo, bank: bank)));
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(ListTile, '顺序练习');
    await scrollToRecords(tester, tile);
    expect(find.text('记录'), findsOneWidget);
    // 记录区不再放操作提示小字，长按删除仍可用。
    expect(find.text('长按记录可删除'), findsNothing);
    expect(tile, findsOneWidget);

    await tester.longPress(tile);
    await tester.pumpAndSettle();
    expect(find.text('删除记录'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('这个题库还没有练习或考试记录'), findsOneWidget);
    expect(await repo.sessionsOfBank(bank.id), isEmpty);
  });

  testWidgets('记录：点进去直接回到上次刷到的题目', (tester) async {
    final result =
        await QuizImporter.commit(repo, QuizImporter.parse(_bigBank(5)));
    final c = QuizSessionController(repo);
    await c.start(
      bankId: result.bankId,
      mode: QuizMode.all,
      config: const QuizConfig(shuffleQuestions: false),
    );
    c.goTo(3);
    await c.saveProgress();
    c.dispose();

    final bank = (await repo.listBanks()).first;
    await tester
        .pumpWidget(MaterialApp(home: BankDetailPage(repo: repo, bank: bank)));
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(ListTile, '顺序练习');
    await scrollToRecords(tester, tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('第 4 / 5 题'), findsOneWidget);
  });

  testWidgets('答题页：左右滑动切换上 / 下一题', (tester) async {
    final result =
        await QuizImporter.commit(repo, QuizImporter.parse(_bigBank(3)));
    final c = QuizSessionController(repo);
    await c.start(
      bankId: result.bankId,
      mode: QuizMode.all,
      config: const QuizConfig(shuffleQuestions: false),
    );
    await tester.pumpWidget(MaterialApp(
      home: QuizAnswerPage(repo: repo, controller: c),
    ));
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 3 题'), findsOneWidget);

    await tester.drag(
        find.byKey(const ValueKey('answer-body-0')), const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 3 题'), findsOneWidget);

    await tester.drag(
        find.byKey(const ValueKey('answer-body-1')), const Offset(160, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 3 题'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // ---------- 题目 AI 解析 ----------
  group('提示词', () {
    test('带上题干、选项、正确答案与我的作答', () {
      final prompt = buildQuizExplainPrompt(_question, myAnswer: 'A');
      expect(prompt, contains('水的沸点在标准大气压下是多少？'));
      expect(prompt, contains('B. 100℃（正确答案）'));
      expect(prompt, contains('我的作答：A（错）'));
      expect(prompt, contains('干扰项为什么错'));
    });

    test('没有作答与选项时不留空段', () {
      const q = Question(
        id: 'q2',
        bankId: 'b',
        type: QuestionType.fill,
        stem: '中国的首都是____。',
        answer: <String>['北京'],
      );
      final prompt = buildQuizExplainPrompt(q);
      expect(prompt, contains('参考答案：北京'));
      expect(prompt, isNot(contains('我的作答')));
      expect(prompt, isNot(contains('选项：')));
    });

    test('清洗 Markdown 记号', () {
      expect(
        cleanAiAnalysis('**结论**：选 B\n\n\n# 考点\n- 沸腾\n* 汽化'),
        '结论：选 B\n\n考点\n· 沸腾\n· 汽化',
      );
    });
  });

  group('AI 解析面板', () {
    Future<void> pumpGeneratedPanel(
      WidgetTester tester,
      String text, {
      required Question question,
      Future<void> Function(String text)? onSaveAnalysis,
    }) async {
      _configureAi();
      QuizAiService.instance = QuizAiService(
        client: OpenAiCompatClient(
          client: MockClient.streaming(
            (request, bodyStream) async => _sse(<String>[text]),
          ),
        ),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuizAiExplanation(
            question: question,
            onSaveAnalysis: onSaveAnalysis,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-explain')));
      await tester.pumpAndSettle();
    }

    testWidgets('未配置 API Key 时提示去配置', (tester) async {
      _configureAi(apiKey: '');
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: QuizAiExplanation(question: _question)),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ai-explain')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('请先在「用户 → AI 配置」中填写 API Key'), findsOneWidget);
    });

    testWidgets('点击后流式展示解析，并标注仅供参考', (tester) async {
      _configureAi();
      final client = OpenAiCompatClient(
        client: MockClient.streaming((request, bodyStream) async {
          final body = jsonDecode(await bodyStream.bytesToString())
              as Map<String, dynamic>;
          final messages = (body['messages'] as List).cast<Map>();
          expect(messages.first['role'], 'system');
          expect('${messages.last['content']}', contains('水的沸点'));
          return _sse(const <String>['标准大气压下', '水的沸点是 100℃。']);
        }),
      );
      QuizAiService.instance = QuizAiService(client: client);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: QuizAiExplanation(question: _question)),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-explain')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ai-explain')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('ai-explain-panel')), findsOneWidget);
      expect(find.text('标准大气压下水的沸点是 100℃。'), findsOneWidget);
      expect(find.text('仅供参考'), findsOneWidget);

      // 结果已缓存：重新进入同一道题直接显示，不再请求接口。
      final cached = await QuizAiService.instance.cached(_question);
      expect(cached, '标准大气压下水的沸点是 100℃。');
    });

    testWidgets('生成完成后可直接把 AI 解析添加为题目解析', (tester) async {
      await repo.insertQuestions(<Question>[_question]);
      await pumpGeneratedPanel(
        tester,
        '标准大气压下是 100℃。',
        question: _question,
        onSaveAnalysis: (text) async {
          await repo.saveAnalysis(_question, text);
        },
      );

      expect(find.byKey(const ValueKey('ai-explain-save')), findsOneWidget);
      expect(find.text('添加解析'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-explain-save')));
      await tester.pumpAndSettle();

      expect(
        (await repo.questionById('q1'))!.analysis,
        '标准大气压下是 100℃。',
      );
      expect(find.text('已写入解析'), findsOneWidget);
    });

    testWidgets('已有解析时需确认才覆盖，取消不改动', (tester) async {
      final old = _question.withContent(
        stem: _question.stem,
        options: _question.options,
        answer: _question.answer,
        analysis: '旧解析',
      );
      await repo.insertQuestions(<Question>[old]);
      await pumpGeneratedPanel(
        tester,
        '新 AI 解析',
        question: old,
        onSaveAnalysis: (text) async {
          await repo.saveAnalysis(old, text);
        },
      );

      expect(find.text('覆盖解析'), findsOneWidget);
      final save = find.byKey(const ValueKey('ai-explain-save'));
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('AI 解析将覆盖原有解析，确定吗？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((await repo.questionById('q1'))!.analysis, '旧解析');

      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.tap(find.text('覆盖'));
      await tester.pumpAndSettle();
      expect((await repo.questionById('q1'))!.analysis, '新 AI 解析');
    });

    testWidgets('切换题目时清空上一题的解析', (tester) async {
      _configureAi();
      QuizAiService.instance = QuizAiService(
        client: OpenAiCompatClient(
          client: MockClient.streaming(
              (request, bodyStream) async => _sse(const <String>['第一题解析'])),
        ),
      );

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: QuizAiExplanation(question: _question)),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-explain')));
      await tester.pumpAndSettle();
      expect(find.text('第一题解析'), findsOneWidget);

      const next = Question(
        id: 'q3',
        bankId: 'bank-1',
        type: QuestionType.single,
        stem: '另一道题',
        options: <OptionItem>[OptionItem(key: 'A', text: '甲')],
        answer: <String>['A'],
        contentHash: 'hash-3',
      );

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: QuizAiExplanation(question: next)),
      ));
      await tester.pumpAndSettle();
      expect(find.text('第一题解析'), findsNothing);
      expect(find.byKey(const ValueKey('ai-explain')), findsOneWidget);
    });
  });

  // ---------- AI 导入 ----------
  final settings = SettingsController.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings.resetForTest();
    await settings.load();
    settings.setLanguage(AppLanguage.simplifiedChinese);
  });

  group('题库 AI 转换服务', () {
    test('未配置 API Key 时直接报错', () async {
      final converter = QuizAiConverter();
      expect(converter.configured, isFalse);
      expect(
        () => converter.convert('1. 1+1=? A.1 B.2 答案 B'),
        throwsA(isA<QuizConvertException>()),
      );
    });

    test('流式返回后解析成题库 JSON 并回报进度', () async {
      await settings.addAssistantProfile(
        name: 'test',
        baseUrl: 'https://api.example.com/v1',
        model: 'test-model',
        apiKey: 'sk-test',
      );
      final converter = QuizAiConverter(
        client: OpenAiCompatClient(
          client: MockClient.streaming((request, bodyStream) async {
            final raw = await bodyStream.bytesToString();
            final body = jsonDecode(raw) as Map<String, dynamic>;
            expect(body['model'], 'test-model');
            expect(body['stream'], isTrue);
            return _sse(_bankJson);
          }),
        ),
      );

      final fractions = <double>[];
      final result = await converter.convert(
        '1. 1+1=? A.1 B.2 答案 B\n2. 中国首都 答案 北京',
        onProgress: (p) => fractions.add(p.fraction),
      );
      expect(result.count, 2);
      expect(result.bankName, 'AI题库');
      expect(result.warning, isNull);
      expect(fractions.first, lessThan(0.5));
      expect(fractions.last, 1);
      // 产出的 JSON 可被导入器解析
      expect(jsonDecode(result.rawJson)['questions'], hasLength(2));
    });

    test('空文本报错', () async {
      await settings.addAssistantProfile(
        name: 'test',
        baseUrl: 'https://api.example.com/v1',
        model: 'test-model',
        apiKey: 'sk-test',
      );
      final converter = QuizAiConverter();
      expect(
        () => converter.convert('   '),
        throwsA(isA<QuizConvertException>()),
      );
    });
  });

  group('AI 导入页面', () {
    testWidgets('转换进度 → 结果卡片 → 确认导入入库', (tester) async {
      final repo = await _openRepo();
      QuizServices.testRepo = repo;
      final fake = _FakeConverter(
        result: const QuizConvertResult(
          rawJson: _bankJson,
          bankName: 'AI题库',
          count: 2,
        ),
      );

      await tester.pumpWidget(MaterialApp(
        home: QuizAiImportPage(
          repo: repo,
          converter: fake,
          initialFile: (name: 'demo.txt', bytes: utf8.encode('题目内容')),
        ),
      ));
      await tester.pump();
      await tester.pump();

      // 进度条 + 百分比
      expect(find.byKey(const ValueKey('quiz-ai-progress')), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);

      fake.gate.complete();
      await tester.pumpAndSettle();

      // 结果卡片
      expect(find.byKey(const ValueKey('quiz-ai-result')), findsOneWidget);
      expect(find.text('AI题库'), findsOneWidget);
      expect(find.text('已转换 2 题'), findsOneWidget);

      // 确定导入 → 预览页 → 确认导入
      await tester.tap(find.byKey(const ValueKey('quiz-ai-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('导入预览'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('import-confirm')));
      await tester.pumpAndSettle();

      final banks = await repo.listBanks();
      expect(banks.any((b) => b.name == 'AI题库'), isTrue);
      QuizServices.reset();
    });

    testWidgets('转换失败展示错误并可重试', (tester) async {
      final repo = await _openRepo();
      QuizServices.testRepo = repo;
      final fake = _FakeConverter(error: '网络错误：连接被中断');
      fake.gate.complete();

      await tester.pumpWidget(MaterialApp(
        home: QuizAiImportPage(
          repo: repo,
          converter: fake,
          initialFile: (name: 'demo.txt', bytes: utf8.encode('题目内容')),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('转换失败'), findsOneWidget);
      expect(find.text('网络错误：连接被中断'), findsOneWidget);
      expect(find.text('重新转换'), findsOneWidget);
      QuizServices.reset();
    });

    testWidgets('息屏保活开关可切换并持久化', (tester) async {
      final repo = await _openRepo();
      QuizServices.testRepo = repo;
      final fake = _FakeConverter(
        result: const QuizConvertResult(
          rawJson: _bankJson,
          bankName: 'AI题库',
          count: 2,
        ),
      );
      fake.gate.complete();

      await tester.pumpWidget(MaterialApp(
        home: QuizAiImportPage(repo: repo, converter: fake),
      ));
      await tester.pumpAndSettle();

      final toggle = find.byKey(const ValueKey('quiz-ai-keep-awake'));
      expect(toggle, findsOneWidget);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(QuizConversionController.instance.keepScreenOn, isTrue);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      QuizServices.reset();
    });

    testWidgets('退出页面不中断转换，返回后直接看到结果', (tester) async {
      final repo = await _openRepo();
      QuizServices.testRepo = repo;
      final fake = _FakeConverter(
        result: const QuizConvertResult(
          rawJson: _bankJson,
          bankName: '后台题库',
          count: 2,
        ),
      );

      await tester.pumpWidget(MaterialApp(
        home: QuizAiImportPage(
          repo: repo,
          converter: fake,
          initialFile: (name: 'demo.txt', bytes: utf8.encode('题目内容')),
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('quiz-ai-progress')), findsOneWidget);
      expect(KeepAwake.cpuAwake, isTrue, reason: '转换期间应持有 CPU 唤醒锁');

      // 模拟用户切到别的页面：旧页面 dispose，任务必须继续。
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      expect(QuizConversionController.instance.busy, isTrue);

      fake.gate.complete();
      await tester.pumpAndSettle();
      expect(QuizConversionController.instance.phase, QuizConvertPhase.done);
      expect(KeepAwake.cpuAwake, isFalse, reason: '完成后必须释放唤醒锁');

      // 重新进入同一个工具，直接展示后台完成的结果。
      await tester.pumpWidget(MaterialApp(
        home: QuizAiImportPage(repo: repo, converter: fake),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('quiz-ai-result')), findsOneWidget);
      expect(find.text('后台题库'), findsOneWidget);
      QuizServices.reset();
    });
  });

  group('答题页功能按钮与错选/漏选标注', () {
    Future<QuizSessionController> startSession(
      String bank, {
      QuizMode mode = QuizMode.all,
    }) async {
      final result = await QuizImporter.commit(repo, QuizImporter.parse(bank));
      final controller = QuizSessionController(repo);
      expect(
        await controller.start(
          bankId: result.bankId,
          mode: mode,
          config: const QuizConfig(shuffleQuestions: false),
        ),
        isTrue,
      );
      return controller;
    }

    /// 选项标注底色：读显式容器的 decoration（不再走 ListTile.tileColor，
    /// 后者经 Ink 画在 Material 墨层，会被页面渐变背景盖住）。
    Color? bgOf(WidgetTester tester, String key) {
      final finder = find.byKey(ValueKey<String>('opt-bg-$key'));
      if (finder.evaluate().isEmpty) return null;
      final container = tester.widget<Container>(finder);
      return (container.decoration as BoxDecoration?)?.color;
    }

    /// 选项文字色（选对的正确选项变绿）。
    Color? textOf(WidgetTester tester, String key) {
      final finder = find.byKey(ValueKey<String>('opt-$key'));
      for (final element in finder.evaluate()) {
        final widget = element.widget;
        if (widget is RadioListTile<String>) {
          return (widget.title as Text?)?.style?.color;
        }
        if (widget is CheckboxListTile) {
          return (widget.title as Text?)?.style?.color;
        }
      }
      return null;
    }

    testWidgets('编辑按钮留在题干行，收藏与答题卡移到底部功能行右侧', (tester) async {
      final controller = await startSession(kBank);
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      final typeY = tester.getCenter(find.text('单选')).dy;
      expect(find.byKey(const ValueKey('answer-edit')), findsOneWidget);
      expect(
        tester.getCenter(find.byKey(const ValueKey('answer-edit'))).dy,
        closeTo(typeY, 8),
      );

      // 收藏 / 答题卡在底部功能行（明显低于题干行），AppBar 里没有。
      final confirmY =
          tester.getCenter(find.byKey(const ValueKey('answer-confirm'))).dy;
      for (final key in <String>['answer-favorite', 'answer-sheet']) {
        final finder = find.byKey(ValueKey<String>(key));
        expect(finder, findsOneWidget);
        expect(tester.getCenter(finder).dy, greaterThan(confirmY));
      }
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byKey(const ValueKey('answer-sheet')),
        ),
        findsNothing,
      );

      // 左下角统计：初始「已答 0 · 错 0」。
      expect(find.byKey(const ValueKey('answer-stats')), findsOneWidget);
      expect(find.text('已答 0'), findsOneWidget);
      expect(find.text('错 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('答错后左下角统计推进：已答 +1、错 +1 标红', (tester) async {
      final controller = await startSession(kBank);
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      // 第 1 题单选，正确答案 B，错选 A。
      await tester.tap(find.byKey(const ValueKey('opt-A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('已答 1'), findsOneWidget);
      expect(find.text('错 1'), findsOneWidget);

      // 错数标红。
      final wrongStyle = tester.widget<Text>(find.text('错 1')).style;
      expect(wrongStyle?.color, Colors.red);
    });

    testWidgets('未答按钮跳到序号最靠前的未作答题，并实时更新数量', (tester) async {
      final result =
          await QuizImporter.commit(repo, QuizImporter.parse(_bigBank(3)));
      final controller = QuizSessionController(repo);
      expect(
        await controller.start(
          bankId: result.bankId,
          mode: QuizMode.all,
          config: const QuizConfig(shuffleQuestions: false),
        ),
        isTrue,
      );
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      final jump = find.byKey(const ValueKey('answer-jump-unanswered'));
      expect(jump, findsOneWidget);
      expect(find.text('未答 3'), findsOneWidget);

      // 答错第 1 题，答错不自动跳题。
      await tester.tap(find.byKey(const ValueKey('opt-A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('未答 2'), findsOneWidget);

      // 跳到第 3 题并答错，此时只剩第 2 题未答。
      await tester.tap(find.byKey(const ValueKey('answer-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-next')));
      await tester.pumpAndSettle();
      expect(find.text('第 3 / 3 题'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('opt-A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('未答 1'), findsOneWidget);

      await tester.tap(jump);
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 3 题'), findsOneWidget, reason: '应回到序号最靠前的未作答题');
      expect(find.text('未答 1'), findsOneWidget, reason: '当前题仍未作答');

      // 把最后一题也答掉，按钮归零后不可再点。
      await tester.tap(find.byKey(const ValueKey('opt-A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('未答 0'), findsOneWidget);
      expect(tester.widget<TextButton>(jump).onPressed, isNull,
          reason: '没有未答题时按钮不可点');
      expect(tester.takeException(), isNull);
    });

    testWidgets('错题练习中也能用未答按钮跳到最早未作答题', (tester) async {
      final result =
          await QuizImporter.commit(repo, QuizImporter.parse(_bigBank(3)));
      // 先把 3 题都放进错题本，建立一次包含未作答题的错题练习。
      for (final q
          in await repo.questionsOfBank(result.bankId, limit: 100000)) {
        await repo.addWrong(result.bankId, q.id);
      }
      final controller = QuizSessionController(repo);
      expect(
        await controller.start(
          bankId: result.bankId,
          mode: QuizMode.wrong,
          config: const QuizConfig(shuffleQuestions: false),
        ),
        isTrue,
      );
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      expect(find.text('未答 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('opt-A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('未答 2'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('answer-jump-unanswered')));
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 3 题'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('单选/判断答错：错选红底、漏选绿底，确认前不标注', (tester) async {
      final controller = await startSession(kBank);
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      expect(bgOf(tester, 'A'), isNull);
      expect(bgOf(tester, 'B'), isNull);

      // 单选正确答案为 B，错选 A。
      await tester.tap(find.byKey(const ValueKey('opt-A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();
      expect(bgOf(tester, 'A'), Colors.red.withOpacity(0.18));
      expect(bgOf(tester, 'B'), Colors.green.withOpacity(0.18));
      // 错选不是「选对」，文字不变色。
      expect(textOf(tester, 'A'), isNull);
      // 底色必须由显式容器画：tileColor 经 Ink 画在 Material 墨层，
      // 会被页面渐变背景盖住（真实设备上表现为「标注消失」）。
      expect(
        tester
            .widget<RadioListTile<String>>(find.byKey(const ValueKey('opt-A')))
            .tileColor,
        isNull,
      );

      // 判断题正确答案为「正确」，错选「错误」。
      await tester.tap(find.byKey(const ValueKey('answer-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('opt-false')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();
      expect(bgOf(tester, 'false'), Colors.red.withOpacity(0.18));
      expect(bgOf(tester, 'true'), Colors.green.withOpacity(0.18));
    });

    testWidgets('多选题答错：错选红底、漏选绿底，选对的选项文字变绿', (tester) async {
      final controller = await startSession(_multiBank());
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      // 正确答案 A、C；选 A（对）+ B（错）→ 漏选 C。
      await tester.tap(find.byKey(const ValueKey('opt-A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('opt-B')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();

      // 选对的 A 不着底、文字变绿；错选 B 红底；漏选 C 绿底。
      expect(bgOf(tester, 'A'), isNull);
      expect(textOf(tester, 'A'), Colors.green.shade700);
      expect(bgOf(tester, 'B'), Colors.red.withOpacity(0.18));
      expect(textOf(tester, 'B'), isNull);
      expect(bgOf(tester, 'C'), Colors.green.withOpacity(0.18));
      expect(textOf(tester, 'C'), isNull);
    });

    testWidgets('答对后选中的选项文字变绿', (tester) async {
      final controller = await startSession(kBank);
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      // 第 1 题单选，正确答案 B，选 B。
      await tester.tap(find.byKey(const ValueKey('opt-B')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();
      // 正确答案 B 被选中：不着底、文字变绿。
      expect(bgOf(tester, 'B'), isNull);
      expect(textOf(tester, 'B'), Colors.green.shade700);
      // 未选中的干扰项不标注。
      expect(bgOf(tester, 'A'), isNull);
      expect(textOf(tester, 'A'), isNull);
    });

    testWidgets('考试模式不提前标注，深色主题标注底色更明显', (tester) async {
      final exam = await startSession(_multiBank(), mode: QuizMode.exam);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: QuizAnswerPage(
            key: const ValueKey('exam-page'), repo: repo, controller: exam),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('opt-B')));
      await tester.pumpAndSettle();
      expect(bgOf(tester, 'B'), isNull);
      expect(textOf(tester, 'B'), isNull);

      // 深色主题下同样的标注用更高不透明度保证可见。
      final practice = await startSession(_multiBank());
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: QuizAnswerPage(
            key: const ValueKey('practice-page'),
            repo: repo,
            controller: practice),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('opt-B')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();
      expect(bgOf(tester, 'B'), Colors.red.withOpacity(0.32));
      expect(bgOf(tester, 'A'), Colors.green.withOpacity(0.32));
      expect(bgOf(tester, 'C'), Colors.green.withOpacity(0.32));
    });
  });

  group('练习设置：数量微调 / 确认后禁止修改 / 答对切下一题', () {
    testWidgets('抽题数量可用加减号微调，减到 0 自动清空', (tester) async {
      final result =
          await QuizImporter.commit(repo, QuizImporter.parse(_bigBank(6)));
      await tester.pumpWidget(MaterialApp(
        home: QuizConfigPage(
            repo: repo, bankId: result.bankId, initialMode: QuizMode.random),
      ));
      await tester.pumpAndSettle();

      final field = find.byKey(const ValueKey('count-single'));
      await tester.ensureVisible(field);
      String text() => tester.widget<TextField>(field).controller!.text;
      expect(text(), isEmpty, reason: '默认不预填数量');

      await tester.tap(find.byKey(const ValueKey('count-single-plus')));
      await tester.pumpAndSettle();
      expect(text(), '1');

      await tester.tap(find.byKey(const ValueKey('count-single-plus')));
      await tester.pumpAndSettle();
      expect(text(), '2');

      await tester.tap(find.byKey(const ValueKey('count-single-minus')));
      await tester.pumpAndSettle();
      expect(text(), '1');

      // 减到 0：不写 0，直接回到空态（占位 0 只作为 hint 显示）。
      await tester.tap(find.byKey(const ValueKey('count-single-minus')));
      await tester.pumpAndSettle();
      expect(text(), isEmpty);
    });

    testWidgets('确认后禁止修改：已确认的题目选项变灰不可再选', (tester) async {
      final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
      final controller = QuizSessionController(repo);
      expect(
        await controller.start(
          bankId: result.bankId,
          mode: QuizMode.all,
          config: const QuizConfig(
            shuffleQuestions: false,
            lockAfterConfirm: true,
          ),
        ),
        isTrue,
      );
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      RadioListTile<String> tile(String key) =>
          tester.widget<RadioListTile<String>>(
              find.byKey(ValueKey<String>('opt-$key')));

      // 确认前可以改选。
      expect(tile('B').onChanged, isNotNull);
      await tester.tap(find.byKey(const ValueKey('opt-A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();

      // 确认后被锁住：选项回调为 null，点另一个选项也不会改变答案。
      expect(tile('A').onChanged, isNull);
      expect(tile('B').onChanged, isNull);
      await tester.tap(find.byKey(const ValueKey('opt-B')));
      await tester.pumpAndSettle();
      expect(tile('A').groupValue, 'A');
      expect(tile('B').groupValue, 'A');
    });

    testWidgets('答对切换下一题：确认答对后自动跳到下一题，答错留在原题', (tester) async {
      final result =
          await QuizImporter.commit(repo, QuizImporter.parse(_bigBank(2)));
      final controller = QuizSessionController(repo);
      expect(
        await controller.start(
          bankId: result.bankId,
          mode: QuizMode.all,
          config: const QuizConfig(
            shuffleQuestions: false,
            autoNextOnCorrect: true,
          ),
        ),
        isTrue,
      );
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 题'), findsOneWidget);

      // 第 1 题答对 → 不用点右侧箭头，直接进第 2 题。
      await tester.tap(find.byKey(const ValueKey('opt-B')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 2 题'), findsOneWidget);

      // 第 2 题答错 → 留在原题显示答案与解析。
      await tester.tap(find.byKey(const ValueKey('opt-A')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 2 题'), findsOneWidget);
      expect(find.text('正确答案：B'), findsOneWidget);
    });

    testWidgets('错题练习：答对累计到设定次数才移出错题本', (tester) async {
      final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
      final questions = await repo.questionsOfBank(result.bankId);
      final target = questions.firstWhere((q) => q.type == QuestionType.single);

      // 先用一次普通练习答错，把它写进错题本。
      final seed = QuizSessionController(repo);
      await seed.start(
        bankId: result.bankId,
        mode: QuizMode.all,
        config: const QuizConfig(shuffleQuestions: false),
      );
      await seed.answer(target.id, <String>['A']);
      await seed.submit();
      seed.dispose();

      Future<bool> drill(int threshold) async {
        final c = QuizSessionController(repo);
        final ok = await c.start(
          bankId: result.bankId,
          mode: QuizMode.wrong,
          config: QuizConfig(
            shuffleQuestions: false,
            wrongRemoveThreshold: threshold,
          ),
        );
        expect(ok, isTrue);
        await c.answer(target.id, target.answer);
        await c.submit();
        c.dispose();
        final wrong = await repo.wrongQuestions(bankId: result.bankId);
        return wrong.any((q) => q.id == target.id);
      }

      expect(await drill(2), isTrue, reason: '答对 1 次还没到阈值 2');
      expect(await drill(2), isFalse, reason: '答对第 2 次后移出错题本');
    });
  });

  group('简易刷题', () {
    Future<QuizSessionController> start(
      String bank, {
      QuizMode mode = QuizMode.all,
      bool simple = true,
    }) async {
      final result = await QuizImporter.commit(repo, QuizImporter.parse(bank));
      final controller = QuizSessionController(repo);
      expect(
        await controller.start(
          bankId: result.bankId,
          mode: mode,
          config: QuizConfig(shuffleQuestions: false, simpleMode: simple),
        ),
        isTrue,
      );
      return controller;
    }

    testWidgets('配置页开关默认关闭，标题旁有说明气泡', (tester) async {
      final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));
      await tester.pumpWidget(MaterialApp(
        home: QuizConfigPage(repo: repo, bankId: result.bankId),
      ));
      await tester.pumpAndSettle();

      final sw = find.byKey(const ValueKey('config-simple-mode'));
      await tester.ensureVisible(sw);
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);

      await tester.tap(find.byKey(const ValueKey('config-simple-mode-hint')));
      await tester.pumpAndSettle();
      expect(find.textContaining('选完即自动确认'), findsWidgets);
    });

    testWidgets('练习单选：选完直接判分，没有确认与上一题 / 下一题', (tester) async {
      final controller = await start(kBank);
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('answer-confirm')), findsNothing);
      expect(find.byKey(const ValueKey('answer-prev')), findsNothing);
      expect(find.byKey(const ValueKey('answer-next')), findsNothing);

      // 不点任何按钮，选 B（正确答案）后立刻出结果。
      await tester.tap(find.byKey(const ValueKey('opt-B')));
      await tester.pumpAndSettle();
      expect(find.text('正确答案：B'), findsOneWidget);
      expect(controller.stateOf(controller.current!.id), AnswerState.correct);
    });

    testWidgets('练习多选：仍保留确认按钮，但没有翻页按钮', (tester) async {
      final controller = await start(_multiBank());
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('answer-confirm')), findsOneWidget);
      expect(find.byKey(const ValueKey('answer-prev')), findsNothing);
      expect(find.byKey(const ValueKey('answer-next')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('opt-A')));
      await tester.pumpAndSettle();
      // 多选点了不会立刻判分。
      expect(
          controller.stateOf(controller.current!.id), AnswerState.unanswered);
    });

    testWidgets('考试：去掉翻页按钮，保留交卷', (tester) async {
      final controller = await start(_multiBank(), mode: QuizMode.exam);
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('answer-prev')), findsNothing);
      expect(find.byKey(const ValueKey('answer-next')), findsNothing);
      expect(find.byKey(const ValueKey('answer-submit')), findsOneWidget);
    });

    testWidgets('关闭简易刷题后确认与翻页按钮都回来', (tester) async {
      final controller = await start(kBank, simple: false);
      await tester.pumpWidget(MaterialApp(
        home: QuizAnswerPage(repo: repo, controller: controller),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('answer-confirm')), findsOneWidget);
      expect(find.byKey(const ValueKey('answer-prev')), findsOneWidget);
      expect(find.byKey(const ValueKey('answer-next')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('opt-B')));
      await tester.pumpAndSettle();
      expect(
          controller.stateOf(controller.current!.id), AnswerState.unanswered);
    });
  });

  group('Excel 导入页面', () {
    testWidgets('转换 → 结果卡 → 查看并导入 → 预览入库', (tester) async {
      final repo = await _openRepo();
      QuizServices.testRepo = repo;
      final bytes = _xlsxBytes(<List<String>>[
        <String>['题干', '选项A', '选项B', '', '答案'],
        <String>['1 + 1 = ?', 'A. 1', 'B. 2', '', 'B'],
        <String>['中国在哪个洲？', 'A. 亚洲', 'B. 欧洲', '', 'A'],
        <String>['1 + 1 = ?', 'A. 1', 'B. 2', '', 'B'], // 重复题
      ]);

      await tester.pumpWidget(MaterialApp(
        home: QuizExcelImportPage(
          repo: repo,
          initialFile: (name: '口算题.xlsx', bytes: bytes),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('quiz-excel-result')), findsOneWidget);
      expect(find.text('口算题'), findsOneWidget);
      expect(find.text('成功 2 题 · 去重 1 题 · 跳过 0 行'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('quiz-excel-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('导入预览'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('import-confirm')));
      await tester.pumpAndSettle();

      final banks = await repo.listBanks();
      expect(banks.any((b) => b.name == '口算题'), isTrue);
      QuizServices.reset();
    });

    testWidgets('无效文件显示错误，无题目时查看按钮禁用', (tester) async {
      final repo = await _openRepo();
      QuizServices.testRepo = repo;

      await tester.pumpWidget(MaterialApp(
        home: QuizExcelImportPage(
          repo: repo,
          initialFile: (name: 'bad.xlsx', bytes: utf8.encode('not a zip')),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('转换失败'), findsOneWidget);
      expect(find.text('重新选择'), findsOneWidget);
      QuizServices.reset();
    });
  });

  group('题目详情面板', () {
    testWidgets('顶部收藏星标为主题色，编辑同行；左右滑动切题', (tester) async {
      final bankId = await repo.createBank(name: '详情测试');
      final questions = <Question>[
        Question(
            id: 'd1',
            bankId: bankId,
            type: QuestionType.single,
            stem: '详情第一题',
            orderNo: 1),
        Question(
            id: 'd2',
            bankId: bankId,
            type: QuestionType.fill,
            stem: '详情第二题',
            orderNo: 2),
      ];
      await repo.insertQuestions(questions);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuestionDetailSheet(
            repo: repo,
            questions: questions,
            initialIndex: 0,
            favoriteIds: const <String>{},
            wrongIds: const <String>{},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('详情第一题'), findsOneWidget);
      final fav = tester
          .widget<IconButton>(find.byKey(const ValueKey('detail-favorite')));
      expect(fav.icon, isA<Icon>());
      expect(
          (fav.icon as Icon).color,
          Theme.of(tester.element(find.byType(QuestionDetailSheet)))
              .colorScheme
              .primary,
          reason: '收藏星标使用主题色');
      expect(find.byKey(const ValueKey('detail-edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-remove-wrong')), findsNothing);
      expect(find.text('1 / 2'), findsOneWidget);

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('详情第二题'), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);
    });

    testWidgets('错题带移出错题按钮，点收藏星标就地更新不关闭面板', (tester) async {
      final bankId = await repo.createBank(name: '详情错题');
      final q = Question(
          id: 'dw1',
          bankId: bankId,
          type: QuestionType.single,
          stem: '错题详情',
          orderNo: 1);
      await repo.insertQuestions(<Question>[q]);
      await repo.addWrong(bankId, q.id);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuestionDetailSheet(
            repo: repo,
            questions: <Question>[q],
            initialIndex: 0,
            favoriteIds: const <String>{},
            wrongIds: <String>{q.id},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('detail-remove-wrong')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('detail-favorite')));
      await tester.pumpAndSettle();
      expect(await repo.isFavorite(bankId, q.id), isTrue);
      expect(find.byKey(const ValueKey('detail-favorite')), findsOneWidget,
          reason: '收藏后面板不关闭');

      await tester.tap(find.byKey(const ValueKey('detail-remove-wrong')));
      await tester.pumpAndSettle();
      expect((await repo.wrongIds(bankId: bankId)).contains(q.id), isFalse);
      expect(find.byKey(const ValueKey('detail-remove-wrong')), findsNothing);
    });
  });

  group('题库分类文件夹', () {
    testWidgets('可新建文件夹、移动题库进去，折叠状态持久化', (tester) async {
      final result = await QuizImporter.commit(repo, QuizImporter.parse(kBank));

      await tester.pumpWidget(const MaterialApp(home: QuizPage()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('quiz-folder-create')), findsOneWidget);

      // 新建文件夹
      await tester.tap(find.byKey(const ValueKey('quiz-folder-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '理科');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('理科'), findsOneWidget);
      final folders = await QuizFoldersData.load(repo);
      expect(folders.folders.single.name, '理科');
      final folderId = folders.folders.single.id;

      // 题库默认在未分类；通过卡片更多菜单移入文件夹
      expect(find.text('未分类'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bank-move-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('理科').last);
      await tester.pumpAndSettle();
      expect((await QuizFoldersData.load(repo)).folderIdOf(result.bankId),
          folderId);

      // 折叠文件夹，状态写回仓库
      await tester.tap(find.byKey(ValueKey('quiz-folder-toggle-$folderId')));
      await tester.pumpAndSettle();
      expect(
          (await QuizFoldersData.load(repo)).folders.single.expanded, isFalse);
      expect(find.text('演示题库'), findsNothing);
    });
  });
}
