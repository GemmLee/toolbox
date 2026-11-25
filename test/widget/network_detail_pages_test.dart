import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/features/tools/device_status/ip_diagnosis_card.dart';
import 'package:toolbox/features/tools/device_status/network_detail_pages.dart';
import '../support/test_env.dart';

/// 「IP 检测 / 网络测速」拆成简要卡片 + 详情页之后的界面约束：
/// 卡片只显示摘要，详情页各自只出一半分区。
void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  tearDown(restoreSystemLanguage);

  testWidgets('未检测时两张简要卡片都给出进入详情的引导', (tester) async {
    final controller = IpDiagnosisController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            IpBriefCard(controller: controller),
            const SizedBox(height: 12),
            SpeedBriefCard(controller: controller),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('IP 检测'), findsOneWidget);
    expect(find.text('网络测速'), findsOneWidget);
    expect(find.text('尚未检测，点进详情可开始检测'), findsOneWidget);
    expect(find.text('尚未测速，点进详情可开始测速'), findsOneWidget);
    // 简要卡片不带分区详情，也不自己发起诊断。
    expect(find.text('连接概览'), findsNothing);
    expect(find.byKey(const ValueKey('ip-start')), findsNothing);
  });

  testWidgets('IP 详情页只显示 IP 相关分区，带「检测结果」标题', (tester) async {
    final controller = IpDiagnosisController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(home: IpDetailPage(controller: controller)));
    await tester.pumpAndSettle();

    expect(find.text('IP 检测'), findsOneWidget, reason: 'AppBar 标题');
    expect(find.text('检测结果'), findsOneWidget);
    expect(find.text('网络测速'), findsNothing);
    // 空闲态由卡片内的按钮触发诊断。
    expect(find.byKey(const ValueKey('ip-start')), findsOneWidget);
  });

  testWidgets('测速详情页标题与 IP 详情页区分', (tester) async {
    final controller = IpDiagnosisController();
    addTearDown(controller.dispose);

    await tester
        .pumpWidget(MaterialApp(home: SpeedDetailPage(controller: controller)));
    await tester.pumpAndSettle();

    expect(find.text('网络测速'), findsOneWidget);
    expect(find.text('测试结果'), findsOneWidget);
    expect(find.byKey(const ValueKey('ip-start')), findsOneWidget);
  });
}
