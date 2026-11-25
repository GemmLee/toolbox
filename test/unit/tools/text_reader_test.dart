import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/platform/file_import_bridge.dart';
import 'package:toolbox/core/storage/app_files.dart';
import 'package:toolbox/features/tools/text_reader/document_view.dart';
import 'package:toolbox/features/tools/text_reader/html_parser.dart';
import 'package:toolbox/features/tools/text_reader/markdown_parser.dart';

void main() {
  late Directory root;
  late Directory incoming;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reader_unit');
    incoming = await Directory.systemTemp.createTemp('reader_incoming');
    AppStore.useRootForTest(root);
    FileImportBridge.instance.resetForTest();
  });

  tearDown(() async {
    AppStore.useRootForTest(null);
    FileImportBridge.instance.resetForTest();
    if (root.existsSync()) await root.delete(recursive: true);
    if (incoming.existsSync()) await incoming.delete(recursive: true);
  });

  group('Markdown 解析', () {
    test('块级：标题、段落、列表、引用、代码块、分割线', () {
      final blocks = MarkdownParser.parse(
        '# 标题\n\n普通段落\n\n- A\n- B\n\n1. 一\n2. 二\n\n'
        '> 引用\n\n```dart\nprint(1)\n```\n\n---\n',
      );
      expect(blocks[0].kind, MdBlockKind.heading);
      expect(blocks[0].level, 1);
      expect(blocks[0].text, '标题');
      expect(blocks[1].kind, MdBlockKind.paragraph);
      expect(blocks[2].kind, MdBlockKind.bulletList);
      expect(blocks[2].items, <String>['A', 'B']);
      expect(blocks[3].kind, MdBlockKind.orderedList);
      expect(blocks[3].items, <String>['一', '二']);
      expect(blocks[4].kind, MdBlockKind.quote);
      expect(blocks[4].text, '引用');
      expect(blocks[5].kind, MdBlockKind.code);
      expect(blocks[5].text, 'print(1)');
      expect(blocks[5].language, 'dart');
      expect(blocks[6].kind, MdBlockKind.divider);
    });

    test('行内：粗体、斜体、代码、链接', () {
      final parts = MarkdownParser.parseInline(
        '普通 **粗** *斜* `码` [链接](https://a.com) 尾',
      );
      expect(
        parts.map((e) => e.kind).toList(),
        <MdInlineKind>[
          MdInlineKind.text,
          MdInlineKind.bold,
          MdInlineKind.text,
          MdInlineKind.italic,
          MdInlineKind.text,
          MdInlineKind.code,
          MdInlineKind.text,
          MdInlineKind.link,
          MdInlineKind.text,
        ],
      );
      expect(parts[1].text, '粗');
      expect(parts[7].text, '链接');
      expect(parts[7].href, 'https://a.com');
      expect(
        parts.map((e) => e.text).join(),
        '普通 粗 斜 码 链接 尾',
      );
    });

    test('未闭合代码块按末尾收尾', () {
      final blocks = MarkdownParser.parse('```\nline1\nline2');
      expect(blocks.single.kind, MdBlockKind.code);
      expect(blocks.single.text, 'line1\nline2');
    });

    test('表格：表头、对齐与数据行', () {
      final blocks = MarkdownParser.parse(
        '前文\n\n'
        '| 项目 | 数值 | 说明 |\n'
        '|:--|--:|:--:|\n'
        '| 身高 | 170 | a \\| b |\n'
        '| 体重 | 60 |\n'
        '\n后文\n',
      );
      expect(blocks[1].kind, MdBlockKind.table);
      expect(blocks[1].header, <String>['项目', '数值', '说明']);
      expect(blocks[1].aligns, <MdAlign>[
        MdAlign.left,
        MdAlign.right,
        MdAlign.center,
      ]);
      // 列数不足的行补空串，转义竖线还原。
      expect(blocks[1].rows, <List<String>>[
        <String>['身高', '170', 'a | b'],
        <String>['体重', '60', ''],
      ]);
      expect(blocks[2].kind, MdBlockKind.paragraph);
      expect(blocks[2].text, '后文');
    });

    test('表格分隔行不成立时按段落处理', () {
      final blocks = MarkdownParser.parse('| a | b |\n| c | d |');
      expect(blocks.every((b) => b.kind != MdBlockKind.table), isTrue);
    });

    test('任务列表与嵌套缩进', () {
      final blocks = MarkdownParser.parse('- [ ] 待办\n- [x] 已完成\n  - 子项');
      final list = blocks.single;
      expect(list.kind, MdBlockKind.bulletList);
      expect(list.items, <String>['待办', '已完成', '子项']);
      expect(list.checked, <bool?>[false, true, null]);
      expect(list.indents, <int>[0, 0, 1]);
    });

    test('行内删除线与图片', () {
      final parts = MarkdownParser.parseInline('旧 ~~删掉~~ ![图](a.png)');
      expect(
        parts.map((e) => e.kind).toList(),
        <MdInlineKind>[
          MdInlineKind.text,
          MdInlineKind.strike,
          MdInlineKind.text,
          MdInlineKind.link,
        ],
      );
      expect(parts[1].text, '删掉');
      expect(parts[3].text, '图');
      expect(parts[3].href, 'a.png');
    });

    test('源码分块：长行按字符切、短行合块', () {
      final chunks = chunkSource('a\nb\n${'x' * 25}', maxChars: 10);
      expect(chunks.length, greaterThan(1));
      expect(chunks.join(), contains('xxxx'));
      // 拼回去不能丢字符（分块只在换行/定长处切）。
      final text = List<String>.generate(500, (i) => 'line $i').join('\n');
      expect(chunkSource(text, maxChars: 100).join(), '$text\n');
    });
  });

  group('HTML 转 Markdown', () {
    test('块级：标题 / 段落 / 引用 / 代码块 / 分割线', () {
      final md = HtmlParser.toMarkdown(
        '<h2>小标题</h2><p>正文一段</p><blockquote>引述</blockquote>'
        '<pre><code>a\nb</code></pre><hr/>',
      );
      final blocks = MarkdownParser.parse(md);
      expect(blocks.map((b) => b.kind), contains(MdBlockKind.heading));
      expect(md, contains('## 小标题'));
      expect(md, contains('正文一段'));
      expect(md, contains('> 引述'));
      expect(md, contains('```'));
      expect(md, contains('a\nb'));
      expect(md, contains('---'));
    });

    test('行内：粗体 / 斜体 / 删除线 / 代码 / 链接', () {
      final md = HtmlParser.toMarkdown(
        '<p><b>粗</b><i>斜</i><del>删</del><code>码</code>'
        '<a href="https://x.com">链接</a></p>',
      );
      expect(md, contains('**粗**'));
      expect(md, contains('*斜*'));
      expect(md, contains('~~删~~'));
      expect(md, contains('`码`'));
      expect(md, contains('[链接](https://x.com)'));
    });

    test('列表：无序 / 有序 / 嵌套', () {
      final md = HtmlParser.toMarkdown(
        '<ul><li>甲</li><li>乙<ul><li>子</li></ul></li></ul>'
        '<ol><li>一</li><li>二</li></ol>',
      );
      expect(md, contains('- 甲'));
      expect(md, contains('  - 子'));
      expect(md, contains('1. 一'));
      expect(md, contains('2. 二'));
    });

    test('表格：表头与数据行', () {
      final md = HtmlParser.toMarkdown(
        '<table><tr><th>A</th><th>B</th></tr>'
        '<tr><td>1</td><td>2</td></tr></table>',
      );
      final blocks = MarkdownParser.parse(md);
      expect(
        blocks.any((b) => b.kind == MdBlockKind.table),
        isTrue,
        reason: 'md=$md',
      );
      expect(md, contains('| A | B |'));
      expect(md, contains('| 1 | 2 |'));
    });

    test('实体解码、脚本样式剔除、正文里的 md 特殊字符被转义', () {
      final md = HtmlParser.toMarkdown(
        '<html><head><title>忽略</title><style>.a{}</style></head><body>'
        '<script>alert(1)</script>'
        '<p>A &amp; B &lt; C &#39;D&#39; &nbsp; 5 * 3 #tag</p>'
        '</body></html>',
      );
      expect(md, isNot(contains('alert')));
      expect(md, isNot(contains('忽略')));
      expect(md, contains('A & B < C'));
      // 正文里的 * 被转义，不会被当成 md 强调语法。
      expect(md, contains(r'\*'));
    });

    test('空 html 返回空串', () {
      expect(HtmlParser.toMarkdown(''), isEmpty);
      expect(HtmlParser.toMarkdown('<html><body></body></html>'), isEmpty);
    });
  });

  group('JSON 视图', () {
    test('合法 JSON 美化，非法内容原样返回', () {
      expect(isValidJson('{"a":1}'), isTrue);
      expect(isValidJson('{oops'), isFalse);
      final formatted = formatJson('{"a":1,"b":[true,null]}');
      expect(formatted, contains('"a": 1'));
      expect(formatted, contains('\n  "b"'));
      expect(formatJson('{oops'), '{oops');
    });

    test('着色不丢字符', () {
      const text = '{"a": 1, "ok": true}';
      final spans = jsonSpans(
        text,
        const TextStyle(),
        ColorScheme.fromSeed(seedColor: Colors.blue),
      );
      expect(
        spans.map((s) => (s as TextSpan).text ?? '').join(),
        text,
      );
    });
  });

  group('阅读器编辑覆盖保存', () {
    test('同名 overwrite 直接覆盖原文件，不生成副本', () async {
      final first = await AppStore.saveText(
        category: AppStoreCategory.reader,
        name: 'note.txt',
        content: 'old',
      );
      await AppStore.saveText(
        category: AppStoreCategory.reader,
        name: 'note.txt',
        content: 'new',
        overwrite: true,
      );
      expect(await AppStore.readText(first), 'new');
      final listed = await AppStore.listOf(AppStoreCategory.reader);
      expect(listed, hasLength(1));
      expect(listed.single.name, 'note.txt');
    });
  });

  group('外部文件导入', () {
    test('扩展名白名单', () {
      expect(FileImportBridge.isSupported('a.md'), isTrue);
      expect(FileImportBridge.isSupported('a.markdown'), isTrue);
      expect(FileImportBridge.isSupported('a.html'), isTrue);
      expect(FileImportBridge.isSupported('a.htm'), isTrue);
      expect(FileImportBridge.isSupported('a.HTML'), isTrue);
      expect(FileImportBridge.isSupported('a.json'), isTrue);
      expect(FileImportBridge.isSupported('a.txt'), isTrue);
      expect(FileImportBridge.isSupported('a.MD'), isTrue);
      expect(FileImportBridge.isSupported('a.pdf'), isFalse);
      expect(FileImportBridge.isSupported('a'), isFalse);
    });

    test('归档到「文字阅读器」分类并清理临时源', () async {
      final source = File('${incoming.path}/note.md');
      await source.writeAsString('# Hi');
      final stored = await FileImportBridge.instance
          .adoptPath(source.path, name: 'note.md');
      expect(stored, isNotNull);
      expect(stored!.category, AppStoreCategory.reader);
      expect(stored.name, 'note.md');
      expect(await File(stored.path).readAsString(), '# Hi');
      expect(source.existsSync(), isFalse);
      final listed = await AppStore.listOf(AppStoreCategory.reader);
      expect(listed.map((e) => e.name), contains('note.md'));
      expect(FileImportBridge.instance.takePendingOpen()?.name, 'note.md');
      expect(FileImportBridge.instance.takePendingOpen(), isNull);
    });

    test('同名文件自动加序号', () async {
      final a = File('${incoming.path}/a.txt')..writeAsStringSync('1');
      final b = File('${incoming.path}/b.txt')..writeAsStringSync('2');
      final first =
          await FileImportBridge.instance.adoptPath(a.path, name: 'same.txt');
      final second =
          await FileImportBridge.instance.adoptPath(b.path, name: 'same.txt');
      expect(first!.name, 'same.txt');
      expect(second!.name, 'same(2).txt');
    });

    test('不支持的类型不落盘并计入拒绝数', () async {
      final source = File('${incoming.path}/photo.png');
      await source.writeAsBytes(<int>[1, 2, 3]);
      final stored = await FileImportBridge.instance
          .adoptPath(source.path, name: 'photo.png');
      expect(stored, isNull);
      expect(FileImportBridge.instance.rejected, 1);
      expect(source.existsSync(), isFalse);
      expect(await AppStore.listOf(AppStoreCategory.reader), isEmpty);
    });

    test('手动导入可保留原文件且不请求自动打开', () async {
      final source = File('${incoming.path}/local.json');
      await source.writeAsString('{"k":1}');
      final stored = await FileImportBridge.instance.adoptPath(
        source.path,
        name: 'local.json',
        deleteSource: false,
        requestOpen: false,
      );
      expect(stored, isNotNull);
      expect(source.existsSync(), isTrue);
      expect(FileImportBridge.instance.takePendingOpen(), isNull);
    });
  });
}
