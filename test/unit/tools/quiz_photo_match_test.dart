import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_models.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_repository.dart';
import 'package:toolbox/features/tools/quiz/data/quiz_schema.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_photo_match.dart';

Future<QuizRepository> openMatchRepo() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await migrateQuiz(db, 0, quizSchemaVersion);
  return QuizRepository(db);
}

Question single(
  String id,
  String bankId, {
  required String stem,
  required List<OptionItem> options,
  required List<String> answer,
  int orderNo = 0,
}) =>
    Question(
      id: id,
      bankId: bankId,
      type: QuestionType.single,
      stem: stem,
      options: options,
      answer: answer,
      orderNo: orderNo,
    );

void main() {
  group('归一化与相似度', () {
    test('去掉空白与标点，只留文字与数字', () {
      expect(normalizeForMatch('  1. TCP 三次握手？\n'), '1tcp三次握手');
      expect(normalizeForMatch('《计算机》网络（第2版）'), '计算机网络第2版');
    });

    test('完全相同的题干相似度为 1', () {
      expect(similarityOf('TCP 三次握手', 'tcp三次握手'), 1);
    });

    test('OCR 整段包含题干时给近似满分', () {
      final score = similarityOf(
        '3. 下列哪个是传输层协议 下列哪个是传输层协议',
        '下列哪个是传输层协议',
      );
      expect(score, greaterThan(0.9));
    });

    test('不相关题目分数明显更低', () {
      final near = similarityOf('TCP 三次握手的第二个报文是什么', 'TCP 三次握手的第二个报文是');
      final far = similarityOf('TCP 三次握手的第二个报文是什么', '下列哪个属于物理层设备');
      expect(near, greaterThan(far));
      expect(far, lessThan(0.3));
    });
  });

  group('拍照搜题选最佳匹配', () {
    test('从题库里挑出最接近的一道，并带回题库名', () async {
      final repo = await openMatchRepo();
      final bankId = await repo.createBank(name: '计算机网络');
      await repo.insertQuestions(<Question>[
        single(
          'q1',
          bankId,
          stem: 'TCP 三次握手的第二个报文是什么？',
          options: const <OptionItem>[
            OptionItem(key: 'A', text: 'SYN'),
            OptionItem(key: 'B', text: 'SYN+ACK'),
            OptionItem(key: 'C', text: 'ACK'),
            OptionItem(key: 'D', text: 'FIN'),
          ],
          answer: const <String>['B'],
          orderNo: 1,
        ),
        single(
          'q2',
          bankId,
          stem: '下列哪个属于物理层设备？',
          options: const <OptionItem>[
            OptionItem(key: 'A', text: '集线器'),
            OptionItem(key: 'B', text: '交换机'),
          ],
          answer: const <String>['A'],
          orderNo: 2,
        ),
      ]);

      final match = await bestMatchForText(
        repo,
        '2. TCP 三次握手的第二个报文是什么？\nA. SYN  B. SYN+ACK',
      );
      expect(match, isNotNull);
      expect(match!.question.id, 'q1');
      expect(match.bankName, '计算机网络');
      expect(match.score, greaterThan(0.5));
    });

    test('OCR 只拍到选项时也能命中', () async {
      final repo = await openMatchRepo();
      final bankId = await repo.createBank(name: '英语四级');
      await repo.insertQuestions(<Question>[
        single(
          'q1',
          bankId,
          stem: 'abandon 的意思是？',
          options: const <OptionItem>[
            OptionItem(key: 'A', text: '放弃'),
            OptionItem(key: 'B', text: '获得'),
            OptionItem(key: 'C', text: '建议'),
            OptionItem(key: 'D', text: '比较'),
          ],
          answer: const <String>['A'],
        ),
      ]);
      final match = await bestMatchForText(repo, 'A. 放弃  B. 获得  C. 建议  D. 比较');
      expect(match, isNotNull);
      expect(match!.question.id, 'q1');
    });

    test('框住题干和选项时两边都要对上，选项顺序无关', () async {
      final repo = await openMatchRepo();
      final bankId = await repo.createBank(name: '网络');
      await repo.insertQuestions(<Question>[
        single(
          'q1',
          bankId,
          stem: '下列哪个是传输层协议？',
          options: const <OptionItem>[
            OptionItem(key: 'A', text: 'IP'),
            OptionItem(key: 'B', text: 'TCP'),
            OptionItem(key: 'C', text: 'ICMP'),
            OptionItem(key: 'D', text: 'ARP'),
          ],
          answer: const <String>['B'],
          orderNo: 1,
        ),
        single(
          'q2',
          bankId,
          stem: '下列哪个是应用层协议？',
          options: const <OptionItem>[
            OptionItem(key: 'A', text: 'HTTP'),
            OptionItem(key: 'B', text: 'SMTP'),
            OptionItem(key: 'C', text: 'FTP'),
            OptionItem(key: 'D', text: 'DNS'),
          ],
          answer: const <String>['A'],
          orderNo: 2,
        ),
      ]);

      // 选项顺序被 OCR 读乱、字母还带全角，仍然必须选中 q1。
      final match = await bestMatchForText(
        repo,
        '下列哪个是传输层协议？\nＤ．ARP　Ｂ．TCP　Ａ．IP　Ｃ．ICMP',
      );
      expect(match, isNotNull);
      expect(match!.question.id, 'q1');
    });

    test('题干对得上但选项全不对时不出结果', () async {
      final repo = await openMatchRepo();
      final bankId = await repo.createBank(name: '网络');
      await repo.insertQuestions(<Question>[
        single(
          'q1',
          bankId,
          stem: '下列哪个是传输层协议？',
          options: const <OptionItem>[
            OptionItem(key: 'A', text: 'IP'),
            OptionItem(key: 'B', text: 'TCP'),
            OptionItem(key: 'C', text: 'ICMP'),
            OptionItem(key: 'D', text: 'ARP'),
          ],
          answer: const <String>['B'],
          orderNo: 1,
        ),
        single(
          'q2',
          bankId,
          stem: '下列哪个是应用层协议？',
          options: const <OptionItem>[
            OptionItem(key: 'A', text: 'HTTP'),
            OptionItem(key: 'B', text: 'SMTP'),
            OptionItem(key: 'C', text: 'FTP'),
            OptionItem(key: 'D', text: 'DNS'),
          ],
          answer: const <String>['A'],
          orderNo: 2,
        ),
      ]);

      // 只有题干像、选项完全是另一套：宁可判为未匹配，也不给一个错答案。
      final match = await bestMatchForText(
        repo,
        '下列哪个是传输层协议？\nA. HTTP  B. 邮件  C. 网页  D. 文件',
      );
      expect(match, isNull);
    });

    test('解析 OCR 文本：题干与选项分别取出', () {
      final parsed = parseOcrStructured(
        '3. 下列哪个是传输层协议？\nA. IP\nB. TCP\nC. ICMP',
      );
      expect(parsed.stem, contains('传输层协议'));
      expect(parsed.options, <String>['IP', 'TCP', 'ICMP']);

      // 没有选项标记：整段当题干，选项为空，调用方退回只看题干的路径。
      final plain = parseOcrStructured('TCP 三次握手的第二个报文是什么');
      expect(plain.options, isEmpty);
      expect(plain.stem, contains('三次握手'));
    });

    test('题库里没有相似题时返回 null', () async {
      final repo = await openMatchRepo();
      final bankId = await repo.createBank(name: '空题库');
      await repo.insertQuestions(<Question>[
        single(
          'q1',
          bankId,
          stem: 'TCP 三次握手的第二个报文是什么？',
          options: const <OptionItem>[OptionItem(key: 'A', text: 'SYN')],
          answer: const <String>['A'],
        ),
      ]);
      expect(await bestMatchForText(repo, '今天天气不错'), isNull);
      expect(await bestMatchForText(repo, ''), isNull);
    });

    test('题库索引带中文答案，判断题不输出 true/false 选项', () async {
      final repo = await openMatchRepo();
      final bankId = await repo.createBank(name: '索引测试');
      await repo.insertQuestions(<Question>[
        single(
          'q1',
          bankId,
          stem: '题干',
          options: const <OptionItem>[OptionItem(key: 'A', text: '选项一')],
          answer: const <String>['A'],
        ),
        Question(
          id: 'q2',
          bankId: bankId,
          type: QuestionType.trueFalse,
          stem: '判断题题干',
          options: const <OptionItem>[],
          answer: const <String>['true'],
          orderNo: 1,
        ),
      ]);
      final index = await repo.quickSearchIndex();
      expect(index, hasLength(2));
      expect(
        index.first.keys.toSet(),
        <String>{'stem', 'type', 'bankId', 'options', 'answer', 'answerText'},
      );
      expect(index.first['bankId'], bankId);
      expect(index.first['stem'], '题干');
      expect(index.first['answerText'], 'A');
      expect(
        (index.first['options'] as List<Map<String, dynamic>>).first['correct'],
        isTrue,
      );
      // 判断题：不给选项（App 侧固定补正确/错误），答案必须是中文文案而不是 true。
      expect(index.last['type'], 'true_false');
      expect(index.last['options'], isEmpty);
      final judgeText = index.last['answerText'] as String;
      expect(judgeText, isNotEmpty);
      expect(judgeText.toLowerCase(), isNot('true'));
      expect(judgeText.toLowerCase(), isNot('false'));
    });

    test('便捷搜题可以限定题库：索引与匹配都只看该题库', () async {
      final repo = await openMatchRepo();
      final bankA = await repo.createBank(name: '题库甲');
      final bankB = await repo.createBank(name: '题库乙');
      await repo.insertQuestions(<Question>[
        single(
          'qa1',
          bankA,
          stem: '计算机网络的传输层协议有哪些',
          options: const <OptionItem>[OptionItem(key: 'A', text: 'TCP')],
          answer: const <String>['A'],
        ),
        single(
          'qb1',
          bankB,
          stem: '数据结构里的二叉搜索树有什么特点',
          options: const <OptionItem>[OptionItem(key: 'A', text: '左小右大')],
          answer: const <String>['A'],
        ),
      ]);

      final all = await repo.quickSearchIndex();
      expect(all, hasLength(2));

      final scoped = await repo.quickSearchIndex(bankId: bankB);
      expect(scoped, hasLength(1));
      expect(scoped.single['stem'], contains('二叉搜索树'));
      expect(scoped.single['bankId'], bankB);

      // 匹配也只在所选题库里找：甲的题在乙的范围里必须搜不到。
      final hit = await bestMatchForText(repo, '二叉搜索树有什么特点', bankId: bankB);
      expect(hit?.question.id, 'qb1');
      final miss = await bestMatchForText(
        repo,
        '计算机网络的传输层协议有哪些',
        bankId: bankB,
      );
      expect(miss, isNull);
    });
  });
}
