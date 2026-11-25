import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/core/settings/settings_controller.dart';
import 'package:toolbox/core/storage/local_store.dart';
import 'package:toolbox/features/tools/assistant/logic/assistant_chunking.dart';
import 'package:toolbox/features/tools/assistant/data/assistant_api.dart';
import 'package:toolbox/features/tools/assistant/data/robust_http.dart';
import 'package:toolbox/features/tools/assistant/data/document_extractor.dart';
import 'package:toolbox/features/tools/assistant/data/skills.dart';
import 'package:toolbox/features/tools/assistant/logic/assistant_controller.dart';
import 'package:toolbox/features/tools/assistant/logic/quiz_result.dart';
import '../../support/test_env.dart';

http.StreamedResponse _sseResponse(List<String> chunks,
    {int statusCode = 200, Map<String, Object?>? usage}) {
  final buffer = StringBuffer();
  for (final delta in chunks) {
    buffer.writeln('data: ${jsonEncode(<String, Object?>{
          'choices': [
            <String, Object?>{
              'delta': <String, Object?>{'content': delta},
            },
          ],
          if (usage != null) 'usage': usage,
        })}');
  }
  buffer.writeln('data: [DONE]');
  return http.StreamedResponse(
    Stream.value(Uint8List.fromList(utf8.encode(buffer.toString()))),
    statusCode,
  );
}

void main() {
  group('OpenAI 兼容客户端', () {
    test('流式解析：增量顺序、usage 上报、[DONE] 结束', () async {
      final client = OpenAiCompatClient(
        client: MockClient.streaming((request, bodyStream) async {
          expect(request.url.path, endsWith('/chat/completions'));
          expect(request.headers['Authorization'], 'Bearer sk-test');
          return _sseResponse(const <String>['你', '好', '！'], usage: {
            'prompt_tokens': 10,
            'completion_tokens': 3,
          });
        }),
      );

      final deltas = <String>[];
      TokenUsage? usage;
      await client
          .streamChat(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        model: 'test-model',
        messages: <ChatMessage>[ChatMessage.user('hi')],
        onUsage: (u) => usage = u,
      )
          .forEach(deltas.add);

      expect(deltas.join(), '你好！');
      final u = usage;
      expect(u, isNotNull);
      expect(u!.promptTokens, 10);
      expect(u.completionTokens, 3);
    });

    test('请求体包含 stream_options.include_usage', () async {
      Map<String, dynamic>? body;
      final client = OpenAiCompatClient(
        client: MockClient.streaming((request, bodyStream) async {
          body = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
          return _sseResponse(const <String>['ok']);
        }),
      );
      await client
          .streamChat(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'k',
        model: 'm',
        messages: <ChatMessage>[ChatMessage.user('hi')],
      )
          .drain<void>();
      expect(body!['stream'], true);
      expect((body!['stream_options'] as Map)['include_usage'], true);
      expect(body!['max_tokens'], kMaxOutputTokens,
          reason: '必须显式给 max_tokens，否则长题库会被默认上限截断');
    });

    test('不支持 stream_options 时 400 自动降级重试', () async {
      var calls = 0;
      final client = OpenAiCompatClient(
        client: MockClient.streaming((request, bodyStream) async {
          calls++;
          final decoded =
              jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
          if (decoded.containsKey('stream_options')) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('{"error":{"message":"stream_options not supported"}}')),
              400,
            );
          }
          return _sseResponse(const <String>['降级成功']);
        }),
      );

      final out = <String>[];
      await client
          .streamChat(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'k',
        model: 'm',
        messages: <ChatMessage>[ChatMessage.user('hi')],
      )
          .forEach(out.add);

      expect(calls, 2);
      expect(out.join(), '降级成功');
    });

    test('非 200 抛出带服务端信息的异常', () async {
      final client = OpenAiCompatClient(
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream.value(utf8.encode(
                '{"error":{"message":"Incorrect API key provided"}}')),
            401,
          );
        }),
      );

      await expectLater(
        client.streamChat(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'bad',
          model: 'm',
          messages: <ChatMessage>[ChatMessage.user('hi')],
        ).drain<void>(),
        throwsA(isA<AssistantApiException>()
            .having((e) => e.message, 'message', contains('Incorrect API key'))
            .having((e) => e.statusCode, 'status', 401)),
      );
    });

    test('余额查询：DeepSeek 去掉 /v1、三家平台解析', () async {
      final uris = <Uri>[];
      final client = OpenAiCompatClient(
        client: MockClient((request) async {
          uris.add(request.url);
          final path = request.url.path;
          if (path.endsWith('/user/balance')) {
            return http.Response(
                jsonEncode({
                  'is_available': true,
                  'balance_infos': [
                    {'currency': 'CNY', 'total_balance': '110.00'}
                  ],
                }),
                200);
          }
          if (path.endsWith('/users/me/balance')) {
            return http.Response(
                jsonEncode({
                  'data': {'available_balance': '42.5'}
                }),
                200);
          }
          if (path.endsWith('/user/info')) {
            return http.Response(
                jsonEncode({
                  'data': {'totalBalance': '7.8'}
                }),
                200);
          }
          return http.Response('not found', 404);
        }),
      );

      final deepseek = await client.queryBalance(
          baseUrl: 'https://api.deepseek.com/v1', apiKey: 'k');
      expect(uris.last.toString(), 'https://api.deepseek.com/user/balance');
      expect(deepseek, '110.00 CNY');

      final moonshot = await client.queryBalance(
          baseUrl: 'https://api.moonshot.cn/v1', apiKey: 'k');
      expect(moonshot, '42.5 CNY');

      final silicon = await client.queryBalance(
          baseUrl: 'https://api.siliconflow.cn/v1', apiKey: 'k');
      expect(silicon, '7.8 CNY');

      final unknown = await client.queryBalance(
          baseUrl: 'https://example.com/v1', apiKey: 'k');
      expect(unknown, isNull);
    });
  });

  group('文档提取', () {
    test('纯文本类直接解码（含 BOM）', () {
      final bytes = Uint8List.fromList(
          [0xEF, 0xBB, 0xBF, ...utf8.encode('第1题：1+1=?\nA. 1\nB. 2')]);
      final doc = DocumentExtractor.extract(fileName: 'questions.md', bytes: bytes);
      expect(doc.text, startsWith('第1题'));
    });

    test('docx：段落与表格', () {
      const documentXml = '''
<?xml version="1.0"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
  <w:p><w:r><w:t>单选题：OSI 共几层？</w:t></w:r></w:p>
  <w:tbl>
    <w:tr><w:tc><w:p><w:r><w:t>题干</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>答案</w:t></w:r></w:p></w:tc></w:tr>
    <w:tr><w:tc><w:p><w:r><w:t>1+1=?</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr>
  </w:tbl>
  <w:p><w:r><w:t>表格之后的一行</w:t></w:r></w:p>
</w:body>
</w:document>''';
      final archive = Archive()
        ..addFile(ArchiveFile('word/document.xml', utf8.encode(documentXml).length,
            Uint8List.fromList(utf8.encode(documentXml))));
      final bytes = ZipEncoder().encode(archive);

      final doc = DocumentExtractor.extract(fileName: '题库.docx', bytes: bytes);
      expect(doc.text, contains('单选题：OSI 共几层？'));
      expect(doc.text, contains('题干\t答案'));
      expect(doc.text, contains('1+1=?\tB'));
      expect(doc.text, contains('表格之后的一行'));
    });

    test('xlsx：共享字符串、内联字符串与数值', () {
      const sharedXml = '<sst><si><t>题干</t></si><si><t>A</t></si></sst>';
      const sheetXml = '''
<worksheet>
  <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1"><v>2</v></c></row>
  <row r="2"><c r="A2" t="s"><v>0</v></c><c r="B2"><v>42</v></c><c r="C2" t="inlineStr"><is><t>True</t></is></c></row>
</worksheet>''';
      final archive = Archive()
        ..addFile(ArchiveFile('xl/sharedStrings.xml', utf8.encode(sharedXml).length,
            Uint8List.fromList(utf8.encode(sharedXml))))
        ..addFile(ArchiveFile('xl/worksheets/sheet1.xml', utf8.encode(sheetXml).length,
            Uint8List.fromList(utf8.encode(sheetXml))));
      final bytes = ZipEncoder().encode(archive);

      final doc = DocumentExtractor.extract(fileName: '题目.xlsx', bytes: bytes);
      expect(doc.text, contains('【Sheet1】'));
      expect(doc.text, contains('题干\tA\t2'));
      expect(doc.text, contains('题干\t42\tTrue'));
    });

    test('不支持的扩展名抛出格式异常', () {
      expect(
        () => DocumentExtractor.extract(
            fileName: 'a.pdf', bytes: utf8.encode('x')),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('技能', () {
    setUp(mockPrefs);

    test('预置技能包含题库转换，且提示词含硬性规则', () async {
      final all = await SkillStore.all();
      final quiz = all.firstWhere((s) => s.id == 'builtin-quiz-convert');
      expect(quiz.name, '题库转换');
      expect(quiz.builtIn, isTrue);
      expect(quiz.prompt, contains('true_false'));
      expect(quiz.prompt, contains('不要用 ``` 代码块包裹'));
      // 判断题绝不输出 options，且选项文本不能带 T/F 标识符。
      expect(quiz.prompt, contains('不要输出 options'));
      expect(quiz.prompt, contains('判断题绝不输出 options'));
      expect(quiz.prompt, contains('选项文本不含 T/F'));
    });

    test('从 Markdown frontmatter 导入：名称/描述/提示词，并可与导出闭环', () async {
      final builtIn = SkillStore.builtIns.first;
      final md = SkillStore.exportMarkdown(builtIn);
      final skill = await SkillStore.importFromFile(
        fileName: '题库转换.md',
        content: md,
      );
      expect(skill.name, builtIn.name);
      expect(skill.description, builtIn.description);
      expect(skill.prompt, builtIn.prompt,
          reason: 'md 正文必须完整还原系统提示词，AI 转换规则不能变');
      expect(await SkillStore.listCustom(), hasLength(1));
    });

    test('旧版 JSON 技能副本会被解包并去重', () async {
      final builtIn = SkillStore.builtIns.first;
      // 旧版本：内置技能是 JSON，导出再导入后整段 JSON 成了提示词。
      final legacyPrompt = jsonEncode(<String, String>{
        'name': builtIn.name,
        'prompt': builtIn.prompt,
      });
      await LocalStore.writeMap('assistant_skills', <String, dynamic>{
        'skills': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'custom-legacy',
            'name': builtIn.name,
            'description': '',
            'prompt': legacyPrompt,
          },
          <String, dynamic>{
            'id': 'custom-keep',
            'name': '翻译',
            'description': '',
            'prompt': '你是翻译助手',
          },
        ],
      });

      final all = await SkillStore.all();
      expect(all.where((s) => s.name == builtIn.name), hasLength(1),
          reason: '与内置技能重复的 JSON 副本必须清掉，只留预置那份');
      expect(all.where((s) => s.name == '翻译'), hasLength(1));
      for (final s in await SkillStore.listCustom()) {
        expect(s.prompt.trimLeft().startsWith('{'), isFalse);
      }
    });

    test('从旧版 Markdown 导入：标题/描述/提示词', () async {
      final skill = await SkillStore.importFromFile(
        fileName: '翻译技能.md',
        content: '# 中英互译\n> 把输入翻译成另一种语言\n你是翻译助手，逐句翻译。',
      );
      expect(skill.name, '中英互译');
      expect(skill.description, '把输入翻译成另一种语言');
      expect(skill.prompt, '你是翻译助手，逐句翻译。');

      final all = await SkillStore.all();
      expect(all.where((s) => s.id == skill.id), hasLength(1));
    });

    test('从 JSON 导入与重名去重、删除', () async {
      await SkillStore.importFromFile(
        fileName: 'a.json',
        content: jsonEncode({
          'name': '摘要',
          'description': '总结文本',
          'prompt': '把文本总结成三句话。',
        }),
      );
      final second = await SkillStore.importFromFile(
        fileName: 'b.json',
        content: jsonEncode({'name': '摘要', 'prompt': '一句话总结。'}),
      );
      expect(second.name, '摘要 (2)');

      var custom = await SkillStore.listCustom();
      expect(custom, hasLength(2));

      await SkillStore.remove(second.id);
      custom = await SkillStore.listCustom();
      expect(custom, hasLength(1));
      expect(custom.first.name, '摘要');
    });

    test('非法技能文件报错', () async {
      expect(
        () => SkillStore.importFromFile(fileName: 'x.json', content: 'not json'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => SkillStore.importFromFile(
            fileName: 'x.json', content: jsonEncode({'name': '无提示词'})),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => SkillStore.importFromFile(
            fileName: 'x.md', content: '---\nname: 空技能\n---\n'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('题库 JSON 提取：代码块 / 裸 JSON / 无 JSON', () {
    const bank =
        '{"version":1,"bankName":"测试","questions":[{"type":"true_false","stem":"1+1=2","answer":["true"]}]}';

    final fenced = extractQuizBankJson('好的，如下：\n```json\n$bank\n```');
    expect(fenced, isNotNull);
    expect(fenced!.bankName, '测试');
    expect(fenced.count, 1);
    expect(jsonDecode(fenced.raw), isA<Map>());

    final bare = extractQuizBankJson('说明文字 $bank 结尾');
    expect(bare, isNotNull);
    expect(bare!.count, 1);

    expect(extractQuizBankJson('没有任何 JSON'), isNull);
    expect(
      extractQuizBankJson('{"version":1,"bankName":"空","questions":[]}'),
      isNull,
    );
  });

  test('长文档分段：每段不超上限且内容不丢', () {
    final text = List.generate(300, (i) => '第$i行内容').join('\n');
    final chunks = splitForConversion(text, max: 200);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.length <= 200), isTrue);
    expect(
      chunks.join('\n').replaceAll(RegExp(r'\s'), ''),
      text.replaceAll(RegExp(r'\s'), ''),
      reason: '分段只是切分，不能丢内容',
    );
  });

  test('题库转换长文档：自动分段请求并合并去重成一个题库', () async {    await LocalStore.remove('app_settings');
    final settings = SettingsController.instance..resetForTest();
    await settings.load();
    await settings.removeAssistantProfile(settings.activeAssistantProfile!.id);
    await settings.addAssistantProfile(
        name: 'T', baseUrl: 'https://x.example/v1', model: 'm', apiKey: 'k');

    var calls = 0;
    final client = OpenAiCompatClient(
      client: MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = (body['messages'] as List).cast<Map>();
        final prompt = messages.last['content'] as String;
        final numbers = RegExp(r'Q(\d+)')
            .allMatches(prompt)
            .map((m) => m.group(1)!)
            .toList();
        final content = jsonEncode(<String, Object?>{
          'version': 1,
          'bankName': '长文档题库',
          'questions': [
            for (final n in numbers)
              <String, Object?>{
                'type': 'true_false',
                'stem': 'Q$n 成立',
                'answer': <String>['true'],
              },
          ],
        });
        return http.Response(
          'data: ${jsonEncode(<String, Object?>{
            'choices': [
              <String, Object?>{
                'delta': <String, Object?>{'content': content},
              },
            ],
          })}\n\ndata: [DONE]\n\n',
          200,
          // 必须带 charset：package:http 在没有 charset 时按 latin1 编码 body，
          // 中文内容会直接抛 "Contains invalid characters"。
          headers: <String, String>{
            'content-type': 'text/event-stream; charset=utf-8',
          },
        );
      }),
    );

    final controller =
        AssistantController(client: client, settings: settings);
    addTearDown(controller.dispose);
    await controller.selectSkill(SkillStore.builtIns.first);

    final source =
        List.generate(600, (i) => 'Q$i 题干内容${'x' * 10}').join('\n');
    await controller.send(source);

    expect(calls, greaterThan(1), reason: '长文档必须拆成多次请求');
    final reply = controller.messages
        .lastWhere((m) => m.role == 'assistant' && !m.error);
    final bank = jsonDecode(reply.content) as Map<String, dynamic>;
    final questions = bank['questions'] as List;
    expect(questions.length, 600, reason: '分段结果要合并且去重');
    expect((questions.first as Map)['id'], 'q-001');
    expect(bank['bankName'], '长文档题库');
    expect(controller.streaming, isFalse);
  });

  test('网络异常翻译：连接中断给出可读提示', () {
    expect(
      describeNetworkError(http.ClientException(
        'Software caused connection abort',
        Uri.parse('https://open.bigmodel.cn/api/paas/v4/chat/completions'),
      )),
      contains('连接被中断'),
    );
    expect(
      describeNetworkError(const SocketException('Failed host lookup')),
      contains('域名'),
    );
  });

  test('分段转换遇到连接中断：自动重试后继续完成', () async {
    await LocalStore.remove('app_settings');
    final settings = SettingsController.instance..resetForTest();
    await settings.load();
    await settings.removeAssistantProfile(settings.activeAssistantProfile!.id);
    await settings.addAssistantProfile(
        name: 'T', baseUrl: 'https://x.example/v1', model: 'm', apiKey: 'k');

    var calls = 0;
    final client = OpenAiCompatClient(
      client: MockClient((request) async {
        calls++;
        // 第一次模拟真实网络错误：服务端/中间链路直接断开连接。
        if (calls == 1) {
          throw http.ClientException(
            'Software caused connection abort',
            request.url,
          );
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final prompt = ((body['messages'] as List).last as Map)['content'] as String;
        final numbers = RegExp(r'Q(\d+)')
            .allMatches(prompt)
            .map((m) => m.group(1)!)
            .toList();
        final content = jsonEncode(<String, Object?>{
          'version': 1,
          'bankName': '重试题库',
          'questions': [
            for (final n in numbers)
              <String, Object?>{
                'type': 'true_false',
                'stem': 'Q$n 成立',
                'answer': <String>['true'],
              },
          ],
        });
        return http.Response(
          'data: ${jsonEncode(<String, Object?>{
            'choices': [
              <String, Object?>{
                'delta': <String, Object?>{'content': content},
              },
            ],
          })}\n\ndata: [DONE]\n\n',
          200,
          // 必须带 charset：package:http 在没有 charset 时按 latin1 编码 body，
          // 中文内容会直接抛 "Contains invalid characters"。
          headers: <String, String>{
            'content-type': 'text/event-stream; charset=utf-8',
          },
        );
      }),
    );

    final controller =
        AssistantController(client: client, settings: settings);
    addTearDown(controller.dispose);
    await controller.selectSkill(SkillStore.builtIns.first);

    final source =
        List.generate(400, (i) => 'Q$i 题干内容${'x' * 12}').join('\n');
    await controller.send(source);

    expect(calls, greaterThan(2), reason: '第一段要先失败一次再重试');
    expect(controller.messages.any((m) => m.error), isFalse);
    final reply = controller.messages
        .lastWhere((m) => m.role == 'assistant' && !m.error);
    final bank = jsonDecode(reply.content) as Map<String, dynamic>;
    expect((bank['questions'] as List).length, 400);
    expect(controller.streaming, isFalse);
  });

  test('题库结果按文件呈现：文件名、大小、截断识别', () {
    const bank =
        '{"version":1,"bankName":"数学/期末 卷","questions":[{"type":"true_false","stem":"1+1=2","answer":["true"]}]}';
    final extract = extractQuizBankJson(bank);
    expect(extract, isNotNull);
    expect(extract!.fileName, '数学_期末_卷.json');
    expect(extract.sizeLabel, endsWith('B'));
    expect(extract.byteSize, utf8.encode(extract.raw).length);

    expect(looksLikeIncompleteJson('{"version":1,"questions":[{"stem":"1'), isTrue);
    expect(looksLikeIncompleteJson('{"a":1}'), isFalse);
    expect(looksLikeIncompleteJson('普通回答'), isFalse);
  });

  test('ChatMessage JSON 往返', () {
    const m = ChatMessage(
      role: 'assistant',
      content: '回复',
      display: null,
      promptTokens: 5,
      completionTokens: 2,
    );
    final back = ChatMessage.fromJson(
        jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
    expect(back.content, '回复');
    expect(back.promptTokens, 5);
    expect(back.completionTokens, 2);
    expect(back.error, isFalse);
  });

  test('AI 多配置：新建/编辑/选择/删除，旧密钥迁移时被清除', () async {
    // 直接写入存储模拟升级前数据（旧版单配置且存有 API Key）。
    await LocalStore.writeMap('app_settings', <String, dynamic>{
      'assistantApiKey': 'sk-legacy-key',
      'assistantBaseUrl': 'https://open.bigmodel.cn/api/paas/v4',
      'assistantModel': 'glm-4-flash',
    });
    final settings = SettingsController.instance..resetForTest();
    await settings.load();

    // 迁移：生成一个 profile，但旧 API Key 被清除
    expect(settings.assistantProfiles.length, 1);
    expect(settings.activeAssistantProfile!.baseUrl,
        'https://open.bigmodel.cn/api/paas/v4');
    expect(settings.assistantApiKey, isEmpty, reason: '旧密钥应被清除');

    // 新建第二个配置：原配置还没有 Key，新配置带了 Key → 自动切过去
    final second = await settings.addAssistantProfile(
      name: '工作号',
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
      apiKey: 'sk-work',
    );
    expect(settings.assistantProfiles.length, 2);
    expect(settings.activeAssistantProfile!.id, second.id);
    expect(settings.assistantApiKey, 'sk-work');

    // 已有可用配置时再新建不抢激活
    final third = await settings.addAssistantProfile(
      name: '备用',
      baseUrl: 'https://api.moonshot.cn/v1',
      model: 'moonshot-v1-8k',
    );
    expect(settings.activeAssistantProfile!.id, second.id,
        reason: '当前配置已填 Key，新增配置不应抢走激活状态');
    await settings.removeAssistantProfile(third.id);

    // 选择
    await settings.setActiveAssistantProfile(second.id);
    expect(settings.activeAssistantProfile!.id, second.id);
    expect(settings.assistantApiKey, 'sk-work');
    expect(settings.assistantBaseUrl, 'https://api.deepseek.com/v1');

    // 编辑
    await settings.updateAssistantProfile(second.id, model: 'deepseek-reasoner');
    expect(settings.assistantModel, 'deepseek-reasoner');

    // 删除激活配置 → 顺延激活第一个
    await settings.removeAssistantProfile(second.id);
    expect(settings.assistantProfiles.length, 1);
    expect(settings.activeAssistantProfile!.name, '默认');
    expect(settings.assistantConfigured, isFalse,
        reason: '迁移后的默认配置没有 Key');

    // 至少保留一个配置由 UI 层保证；数据层允许删到空
    await settings.removeAssistantProfile(settings.activeAssistantProfile!.id);
    expect(settings.assistantProfiles, isEmpty);
    expect(settings.assistantConfigured, isFalse);
  });

  test('新建首个配置自动激活且兼容视图同步', () async {
    await LocalStore.remove('app_settings');
    final settings = SettingsController.instance..resetForTest();
    await settings.load();
    await settings.removeAssistantProfile(settings.activeAssistantProfile!.id);

    final p = await settings.addAssistantProfile(
      name: 'A',
      baseUrl: 'https://x.example/v1',
      model: 'm1',
      apiKey: 'k1',
    );
    expect(settings.activeAssistantProfile!.id, p.id);
    expect(settings.assistantConfigured, isTrue);
    expect(settings.assistantApiKey, 'k1');
  });

  test('编辑后的 API Key 在重启（重新 load）后仍生效', () async {
    await LocalStore.remove('app_settings');
    final settings = SettingsController.instance..resetForTest();
    await settings.load();
    await settings.removeAssistantProfile(settings.activeAssistantProfile!.id);

    final p = await settings.addAssistantProfile(
      name: 'GLM',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-4-flash',
      apiKey: 'k-first',
    );
    expect(settings.assistantConfigured, isTrue);

    // 模拟「第二次打开」：内存重置后从磁盘重新加载，Key 不应丢失。
    settings.resetForTest();
    await settings.load();
    expect(settings.activeAssistantProfile!.id, p.id);
    expect(settings.activeAssistantProfile!.apiKey, 'k-first');
    expect(settings.assistantConfigured, isTrue);

    // 换 Key 后再重启，新 Key 同样持久化。
    await settings.updateAssistantProfile(p.id, apiKey: 'k-second');
    settings.resetForTest();
    await settings.load();
    expect(settings.activeAssistantProfile!.apiKey, 'k-second');
  });

  test('设置变化时对话控制器收到通知（配置状态即时刷新）', () async {
    await LocalStore.remove('app_settings');
    final settings = SettingsController.instance..resetForTest();
    await settings.load();
    await settings.removeAssistantProfile(settings.activeAssistantProfile!.id);

    final controller = AssistantController(settings: settings);
    addTearDown(controller.dispose);
    expect(controller.configured, isFalse);

    var notified = 0;
    controller.addListener(() => notified++);
    await settings.addAssistantProfile(
      name: 'A',
      baseUrl: 'https://x.example/v1',
      model: 'm1',
      apiKey: 'k1',
    );
    expect(notified, greaterThan(0));
    expect(controller.configured, isTrue);
  });

  test('多对话：新建/切换/重命名/删除并持久化', () async {
    await LocalStore.remove('assistant_sessions');
    await LocalStore.remove('assistant_chat');
    await LocalStore.remove('app_settings');
    final settings = SettingsController.instance..resetForTest();
    await settings.load();

    final c = AssistantController(settings: settings)..resetForTest();
    addTearDown(c.dispose);
    await c.load();
    expect(c.sessions.length, 1, reason: '没有历史时至少有一个空对话');

    final first = c.activeSession!;
    await c.renameSession(first.id, '数学题库');
    final second = await c.newSession();
    expect(c.sessions.length, 2);
    expect(c.activeSessionId, second.id);
    // 连点「新对话」不该堆出一串空对话
    final again = await c.newSession();
    expect(again.id, second.id);

    await c.selectSession(first.id);
    expect(c.activeSession!.title, '数学题库');

    // 重新加载：对话列表与当前选中都应恢复
    final c2 = AssistantController(settings: settings)..resetForTest();
    addTearDown(c2.dispose);
    await c2.load();
    expect(c2.sessions.length, 2);
    expect(c2.sessions.any((s) => s.title == '数学题库'), isTrue);
    expect(c2.activeSessionId, first.id);

    // 删除当前对话 → 自动落到剩余对话
    await c2.deleteSession(first.id);
    expect(c2.sessions.length, 1);
    expect(c2.activeSessionId, isNot(first.id));
  });

  test('技能随对话持久化：切换回来/重启后仍保留，新对话沿用', () async {
    await LocalStore.remove('assistant_sessions');
    await LocalStore.remove('assistant_chat');
    await LocalStore.remove('app_settings');
    final settings = SettingsController.instance..resetForTest();
    await settings.load();

    final c = AssistantController(settings: settings)..resetForTest();
    addTearDown(c.dispose);
    await c.load();

    final quiz = SkillStore.builtIns.first;
    final first = c.activeSession!;
    expect(c.activeSkill, isNull, reason: '新对话默认自由对话');

    await c.selectSkill(quiz);
    expect(c.activeSkill?.id, quiz.id);
    expect(first.skillId, quiz.id, reason: '技能要写进这段对话');

    // 先给这段对话起个名（空对话会被「新对话」复用）
    await c.renameSession(first.id, '题库转换');
    // 新对话沿用当前技能，再单独改成自由对话
    final second = await c.newSession();
    expect(second.id, isNot(first.id));
    expect(c.activeSkill?.id, quiz.id, reason: '新对话沿用当前技能');
    await c.selectSkill(null);
    expect(second.skillId, isEmpty);

    // 切回第一段：技能恢复成题库转换
    await c.selectSession(first.id);
    expect(c.activeSkill?.id, quiz.id, reason: '切换对话不能把技能重置成无');

    // 重启（重新读盘）后仍然是第一段对话 + 题库技能
    final c2 = AssistantController(settings: settings)..resetForTest();
    addTearDown(c2.dispose);
    await c2.load();
    expect(c2.activeSessionId, first.id);
    expect(c2.activeSkill?.id, quiz.id, reason: '重启后技能要跟着对话恢复');

    // 切到第二段：它自己是自由对话
    await c2.selectSession(second.id);
    expect(c2.activeSkill, isNull);
  });

  test('旧版单会话历史迁移成一个对话，旧键被清除', () async {
    await LocalStore.remove('assistant_sessions');
    await LocalStore.writeMap('assistant_chat', <String, dynamic>{
      'messages': <Map<String, dynamic>>[
        const ChatMessage(content: '旧对话内容', role: 'user').toJson(),
      ],
    });

    final c = AssistantController()..resetForTest();
    addTearDown(c.dispose);
    await c.load();
    expect(c.sessions.length, 1);
    expect(c.messages.first.content, '旧对话内容');
    expect(await LocalStore.readMap('assistant_chat'), isNull,
        reason: '迁移完成后旧历史键应删除');
  });

  test('生成被中断：下次打开时草稿转成消息且不重复', () async {
    await LocalStore.remove('assistant_chat');
    await LocalStore.writeMap('assistant_sessions', <String, dynamic>{
      'activeId': 's1',
      'sessions': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 's1',
          'title': '中断的对话',
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
          'draft': '已经生成到一半的内容',
          'messages': <Map<String, dynamic>>[],
        },
      ],
    });

    final c = AssistantController()..resetForTest();
    addTearDown(c.dispose);
    await c.load();
    expect(c.messages.length, 1);
    expect(c.messages.single.content, '已经生成到一半的内容');

    final stored = await LocalStore.readMap('assistant_sessions');
    final sessions = stored!['sessions'] as List;
    expect((sessions.first as Map)['draft'], '',
        reason: '恢复后草稿要清空，否则每次打开都会多一条');
  });

  test('生成中切换对话：结果写回原对话，不串到新对话', () async {
    await LocalStore.remove('assistant_sessions');
    await LocalStore.remove('assistant_chat');
    await LocalStore.remove('app_settings');
    final settings = SettingsController.instance..resetForTest();
    await settings.load();
    await settings.removeAssistantProfile(settings.activeAssistantProfile!.id);
    await settings.addAssistantProfile(
        name: 'T', baseUrl: 'https://x.example/v1', model: 'm', apiKey: 'k');

    final client = OpenAiCompatClient(
      client: MockClient.streaming((request, bodyStream) async {
        final stream = StreamController<List<int>>();
        Future<void>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          stream.add(Uint8List.fromList(utf8.encode(
              'data: {"choices":[{"delta":{"content":"答案"}}]}\n\n'
              'data: [DONE]\n\n')));
          await stream.close();
        });
        return http.StreamedResponse(stream.stream, 200);
      }),
    );

    final c = AssistantController(client: client, settings: settings)
      ..resetForTest();
    addTearDown(c.dispose);
    await c.load();

    final originId = c.activeSessionId;
    final pending = c.send('问题');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final other = await c.newSession();
    expect(c.activeSessionId, other.id);
    expect(c.isGenerating(originId), isTrue);
    expect(c.messages, isEmpty, reason: '新对话里不该看到另一段的进度');

    await pending;

    expect(c.isGenerating(originId), isFalse);
    final origin = c.sessions.firstWhere((s) => s.id == originId);
    expect(origin.messages.last.content, '答案');
    expect(c.sessions.firstWhere((s) => s.id == other.id).messages, isEmpty);
  });

  test('智能助手配置持久化与用量累计', () async {
    await LocalStore.remove('app_settings');
    final settings = SettingsController.instance..resetForTest();
    settings.language = AppLanguage.system;
    await settings.load();

    await settings.addAssistantProfile(
      name: 'Kimi',
      baseUrl: 'https://api.moonshot.cn/v1',
      model: 'moonshot-v1-8k',
      apiKey: 'sk-abc',
    );
    expect(settings.assistantConfigured, isTrue);

    await settings.addAssistantUsage(100, 20);
    await settings.addAssistantUsage(50, 5);
    expect(settings.assistantTokensIn, 150);
    expect(settings.assistantTokensOut, 25);

    await settings.resetAssistantUsage();
    expect(settings.assistantTokensIn, 0);
    expect(settings.assistantTokensOut, 0);
  });

  group('网络兜底', () {
    test('识别 DNS 解析失败，其它 SocketException 不误判', () {
      expect(
        isDnsFailure(const SocketException(
            "Failed host lookup: 'x.com'",
            osError: OSError('No address associated with hostname', 7))),
        isTrue,
      );
      expect(
        isDnsFailure(const SocketException('Connection refused',
            osError: OSError('Connection refused', 111))),
        isFalse,
      );
      expect(isDnsFailure(StateError('boom')), isFalse);
    });

    test('默认客户端带 DNS 兜底（不抛异常即可构造）', () {
      final client = createRobustHttpClient();
      addTearDown(client.close);
      expect(client, isNotNull);
    });
  });

  test('错误信息按 UTF-8 解码：响应头无 charset 时中文不乱码，并带出 code', () async {
    final payload = utf8.encode(jsonEncode(<String, dynamic>{
      'error': <String, dynamic>{
        'code': '1211',
        'message': '模型不存在，请检查模型代码',
      },
    }));
    final client = MockClient((request) async => http.Response.bytes(
        payload, 400,
        headers: <String, String>{'content-type': 'application/json'}));
    final api = OpenAiCompatClient(client: client);

    await expectLater(
      api.chat(
        baseUrl: 'https://example.com/v1',
        apiKey: 'k',
        model: 'bad-model',
        messages: <ChatMessage>[ChatMessage.user('hi')],
      ),
      throwsA(isA<AssistantApiException>()
          .having((e) => e.message, 'message', contains('模型不存在'))
          .having((e) => e.message, 'code', contains('1211'))),
    );
  });

  test('模型为空时回退到平台默认模型', () async {
    String? sentModel;
    final client = MockClient((request) async {
      sentModel =
          (jsonDecode(request.body) as Map<String, dynamic>)['model'] as String?;
      return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': 'ok'},
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'});
    });
    final api = OpenAiCompatClient(client: client);
    final reply = await api.chat(
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      apiKey: 'k',
      model: '  ',
      messages: <ChatMessage>[ChatMessage.user('hi')],
    );
    expect(reply, 'ok');
    expect(sentModel, 'glm-5.3', reason: 'GLM 默认回退到官方最新旗舰模型');
  });
}
