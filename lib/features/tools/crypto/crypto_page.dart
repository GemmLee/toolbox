import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import 'decrypt_view.dart';
import 'encrypt_view.dart';
import 'hash_view.dart';

/// 加密解密工具：AES / DES / RSA 加解密，以及哈希摘要。
class CryptoPage extends StatefulWidget {
  const CryptoPage({super.key});

  @override
  State<CryptoPage> createState() => _CryptoPageState();
}

class _CryptoPageState extends State<CryptoPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('加密解密')),
        bottom: TabBar(
          controller: _tabs,
          tabs: <Widget>[
            Tab(text: tr('加密')),
            Tab(text: tr('解密')),
            Tab(text: tr('哈希')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const <Widget>[
          EncryptView(),
          DecryptView(),
          HashView(),
        ],
      ),
    );
  }
}
