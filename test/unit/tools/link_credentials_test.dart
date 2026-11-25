import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/link_parser/link_credentials.dart';

import '../../support/test_env.dart';

LinkCredential _credential({
  required String platform,
  required String url,
  String cookies = 'authorToken=abc; uid=7',
}) =>
    LinkCredential(
      platform: platform,
      loginUrl: url,
      finalUrl: url,
      cookies: cookies,
      storage: const <String, String>{'credentials_1': 'token-value'},
      savedAt: 1700000000000,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  installCleanEnv();

  test('同一平台重复登录只保留最新一份，JSON 可导出再导入', () async {
    await LinkCredentialStore.save(_credential(
      platform: '夸克网盘',
      url: 'https://pan.quark.cn',
      cookies: 'old=1',
    ));
    await LinkCredentialStore.save(_credential(
      platform: '夸克网盘',
      url: 'https://pan.quark.cn',
      cookies: 'authorToken=new',
    ));
    var all = await LinkCredentialStore.load();
    expect(all, hasLength(1));
    expect(all.single.cookies, 'authorToken=new');

    final json = LinkCredentialStore.exportJson(all);
    await LinkCredentialStore.remove('夸克网盘');
    expect(await LinkCredentialStore.load(), isEmpty);

    expect(await LinkCredentialStore.importJson(json), 1);
    all = await LinkCredentialStore.load();
    expect(all.single.storage['credentials_1'], 'token-value');
  });

  test('Cookie 只交给同主域链接，不泄漏到别的域名', () async {
    final all = <LinkCredential>[
      _credential(platform: '百度网盘', url: 'https://pan.baidu.com/s/1'),
    ];
    expect(
      LinkCredentialStore.headersFor('https://pan.baidu.com/s/2', all)['Cookie'],
      contains('authorToken'),
    );
    expect(
      LinkCredentialStore.headersFor('https://evil.example.com/a', all),
      isEmpty,
    );
  });

  test('登录桥接可被注入，取消登录不产生凭证', () async {
    final bridge = LinkLoginBridge(
      invoker: (method, args) async {
        expect(method, 'openLogin');
        expect(args['platform'], '夸克网盘');
        return null;
      },
    );
    expect(await bridge.open('夸克网盘', 'https://pan.quark.cn'), isNull);
  });
}
