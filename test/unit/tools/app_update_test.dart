import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/features/user/app_update_service.dart';

void main() {
  group('版本比较', () {
    test('逐段比较，段数不足补零', () {
      expect(isNewerVersion('1.0.7', '1.0.6'), isTrue);
      expect(isNewerVersion('1.1.0', '1.0.9'), isTrue);
      expect(isNewerVersion('2.0.0', '1.9.9'), isTrue);
      expect(isNewerVersion('1.0.6', '1.0.6'), isFalse);
      expect(isNewerVersion('1.0.5', '1.0.6'), isFalse);
      expect(isNewerVersion('1.0', '1.0.0'), isFalse);
    });

    test('忽略 v 前缀与构建元数据', () {
      expect(isNewerVersion('v1.0.7+8', '1.0.6'), isTrue);
      expect(isNewerVersion('1.0.6-beta', '1.0.6'), isFalse);
    });
  });

  group('Release 更新信息', () {
    test('解析 tag 与 APK asset 直链', () {
      final info = AppUpdateInfo.fromReleaseJson(<String, dynamic>{
        'tag_name': 'v1.0.7',
        'body': '修复问题',
        'html_url': 'https://github.com/GemmLee/toolbox/releases/tag/v1.0.7',
        'assets': <Object?>[
          <String, Object?>{
            'name': 'notes.txt',
            'browser_download_url': 'https://example.com/notes.txt',
          },
          <String, Object?>{
            'name': 'XMtools-1.0.7.apk',
            'browser_download_url':
                'https://github.com/GemmLee/toolbox/releases/download/v1.0.7/XMtools-1.0.7.apk',
          },
        ],
      });
      expect(info.version, '1.0.7');
      expect(info.notes, '修复问题');
      expect(
        info.openUrl,
        'https://github.com/GemmLee/toolbox/releases/download/v1.0.7/XMtools-1.0.7.apk',
      );

      const noAsset = AppUpdateInfo(
        version: '1.0.8',
        releaseUrl: 'https://github.com/GemmLee/toolbox/releases/tag/v1.0.8',
      );
      expect(noAsset.openUrl,
          'https://github.com/GemmLee/toolbox/releases/tag/v1.0.8');
    });

    test('fetch 读取最新 Release；404 与格式错误抛异常', () async {
      final service = AppUpdateService(
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://api.github.com/repos/GemmLee/toolbox/releases/latest',
          );
          return http.Response(
            jsonEncode(<String, dynamic>{
              'tag_name': 'v1.0.7',
              'body': '新版本',
              'assets': <Object?>[
                <String, Object?>{
                  'name': 'XMtools-1.0.7.apk',
                  'browser_download_url': 'https://download.example/x.apk',
                },
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      final info = await service.fetch();
      expect(info.version, '1.0.7');
      expect(info.notes, '新版本');
      expect(info.openUrl, 'https://download.example/x.apk');
      service.dispose();

      final failing = AppUpdateService(
        client: MockClient((_) async => http.Response('not found', 404)),
      );
      expect(failing.fetch(),
          throwsA(isA<AppUpdateException>().having((e) => e.message, 'message',
              contains('暂无发布版本'))));
      failing.dispose();

      final broken = AppUpdateService(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(broken.fetch(), throwsA(isA<AppUpdateException>()));
      broken.dispose();
    });
  });
}
