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

  group('更新清单', () {
    test('解析字段并拼出公开 R2 直链（中文文件名编码）', () {
      final info = AppUpdateInfo.fromJson(<String, dynamic>{
        'version': '1.0.7',
        'versionCode': 8,
        'notes': '修复问题',
        'apkFile': 'XMtools-1.0.7.apk',
      });
      expect(info.version, '1.0.7');
      expect(info.versionCode, 8);
      expect(
        info.apkUrl(AppUpdateService.kPublicResourceBaseUrl),
        'https://xmonline-sgcc.r2.dev/xmapk/XMtools-1.0.7.apk',
      );
      const fallback = AppUpdateInfo(version: '1.0.8');
      expect(
        fallback.apkUrl('https://example.r2.dev/'),
        'https://example.r2.dev/xmapk/XMtools-1.0.8.apk',
      );
    });

    test('fetch 读取 version.json；HTTP 非 200 抛异常', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/xmapk/version.json');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'version': '1.0.7',
            'notes': '新版本',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final service = AppUpdateService(client: client);
      final info = await service.fetch();
      expect(info.version, '1.0.7');
      expect(info.notes, '新版本');
      service.dispose();

      final failing = AppUpdateService(
        client: MockClient((_) async => http.Response('missing', 404)),
      );
      expect(failing.fetch(), throwsA(isA<AppUpdateException>()));
      failing.dispose();
    });
  });
}
