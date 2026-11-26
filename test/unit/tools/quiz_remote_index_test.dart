import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/quiz/logic/quiz_remote_index.dart';

void main() {
  group('QuizRemoteFile 解析与展示', () {
    test('字段解析、题型分布、大小、下载地址', () {
      final file = QuizRemoteFile.fromJson(<String, dynamic>{
        'id': 'songbiandian-ruzhu',
        'title': '送变电准入考试',
        'file': '题库-送变电准入考试.json',
        'size': 562240,
        'questions': 725,
        'types': <String, dynamic>{
          'single': 477,
          'multiple': 98,
          'true_false': 150
        },
      });
      expect(file.title, '送变电准入考试');
      expect(file.dir, 'quiz-bank');
      expect(file.questions, 725);
      expect(file.types['true_false'], 150);
      expect(file.metaLabel, contains('725 题'));
      expect(file.metaLabel, contains('单选 477'));
      expect(file.metaLabel, contains('多选 98'));
      expect(file.metaLabel, contains('判断 150'));
      expect(file.sizeLabel, '549 KB');
      final url = file.downloadUrl('https://example.r2.dev/');
      expect(
          url,
          'https://example.r2.dev/quiz-bank/'
          '${Uri.encodeComponent('题库-送变电准入考试.json')}');
    });

    test('空标题回退到文件名，缺字段不抛错', () {
      final file = QuizRemoteFile.fromJson(<String, dynamic>{
        'file': 'a.json',
        'types': <String, dynamic>{'single': '12', 'bad': 0},
      });
      expect(file.title, 'a.json');
      expect(file.questions, 0);
      expect(file.types['single'], 12);
      expect(file.types.containsKey('bad'), isFalse);
      expect(file.sizeLabel, '');
    });
  });

  group('QuizIndexService 拉取', () {
    test('成功解析 files 数组', () async {
      final body = jsonEncode(<String, dynamic>{
        'version': 1,
        'files': <dynamic>[
          <String, dynamic>{
            'id': 'bank-1',
            'title': '题库一',
            'file': 'a.json',
            'questions': 10,
          },
        ],
      });
      final service = QuizIndexService(
        client: MockClient(
            (_) async => http.Response.bytes(utf8.encode(body), 200)),
      );
      final files = await service.fetch();
      expect(files, hasLength(1));
      expect(files.single.title, '题库一');
      expect(service.indexUrl,
          '${QuizIndexService.kDefaultQuizResourceBaseUrl}/quiz-bank/index.json');
      service.dispose();
    });

    test('非 200 抛可直接展示的异常', () async {
      final service = QuizIndexService(
        client: MockClient((_) async => http.Response('not found', 404)),
      );
      expect(
          service.fetch,
          throwsA(isA<QuizIndexException>().having(
              (e) => e.message, 'message', contains('请稍后重试'))));
      service.dispose();
    });

    test('files 为空或缺失时抛异常', () async {
      final service = QuizIndexService(
        client: MockClient(
          (_) async => http.Response.bytes(utf8.encode('{"files":[]}'), 200),
        ),
      );
      expect(service.fetch, throwsA(isA<QuizIndexException>()));
      service.dispose();
    });
  });
}
