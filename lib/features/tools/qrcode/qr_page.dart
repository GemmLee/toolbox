import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import 'qr_generate_view.dart';
import 'qr_scan_view.dart';

/// 二维码与条码工具：生成（二维码 / 常见一维码）与识别（拍照、相册）。
class QrPage extends StatefulWidget {
  const QrPage({super.key});

  @override
  State<QrPage> createState() => _QrPageState();
}

class _QrPageState extends State<QrPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final TextEditingController _text = TextEditingController();
  CodeKind _kind = CodeKind.all.first;

  @override
  void dispose() {
    _tabs.dispose();
    _text.dispose();
    super.dispose();
  }

  /// 识别页把内容交回生成页。
  void _useText(String value) {
    _text.text = value;
    _text.selection = TextSelection.collapsed(offset: value.length);
    _tabs.animateTo(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('二维码与条码')),
        bottom: TabBar(
          controller: _tabs,
          tabs: <Widget>[
            Tab(text: tr('生成')),
            Tab(text: tr('识别')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: <Widget>[
          QrGenerateView(
            controller: _text,
            kind: _kind,
            onKindChanged: (kind) => setState(() => _kind = kind),
          ),
          QrScanView(onUseText: _useText),
        ],
      ),
    );
  }
}
