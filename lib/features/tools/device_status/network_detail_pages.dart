import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import '../ip_diagnosis/logic/ip_classifier.dart';
import '../ip_diagnosis/logic/ip_diagnosis_service.dart';
import 'ip_diagnosis_card.dart';

/// 总览页的两张简要卡片：IP 检测与网络测速各自只显示几行摘要，
/// 点进去才由 [IpDetailPage] / [SpeedDetailPage] 展示完整分区与测试结果。
/// 两张卡片各用一个页面级 [IpDiagnosisController]（scope 分别为 ip / speed），
/// 只测自己那部分，互不触发对方的外网请求。

class IpBriefCard extends StatelessWidget {
  const IpBriefCard({super.key, required this.controller});

  final IpDiagnosisController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final r = controller.result;
        return SectionCard(
          title: tr('IP 检测'),
          subtitle: tr('连接状态、公网出口与可信度'),
          trailing: const Icon(Icons.chevron_right),
          children: r == null
              ? <Widget>[
                  SmallHint(
                    text: tr('尚未检测，点进详情可开始检测'),
                    textAlign: TextAlign.center,
                  ),
                ]
              : <Widget>[
                  _briefRow('联网状态', _connection(r)),
                  _briefRow(
                    '公网 IP',
                    r.intel.publicIp.ok
                        ? (r.intel.publicIp.value ?? tr('不可用'))
                        : tr('不可用'),
                  ),
                  _briefRow(
                    '出口类型',
                    _categoryLabel(r.classification.category),
                  ),
                  _briefRow('可信度', '${r.trust.score} / 100'),
                ],
        );
      },
    );
  }
}

class SpeedBriefCard extends StatelessWidget {
  const SpeedBriefCard({super.key, required this.controller});

  final IpDiagnosisController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final r = controller.result;
        return SectionCard(
          title: tr('网络测速'),
          subtitle: tr('延迟与上下行速率'),
          trailing: const Icon(Icons.chevron_right),
          children: r == null
              ? <Widget>[
                  SmallHint(
                    text: tr('尚未测速，点进详情可开始测速'),
                    textAlign: TextAlign.center,
                  ),
                ]
              : <Widget>[
                  _briefRow(
                    '下行速率',
                    r.downstream.ok
                        ? formatMBs(r.downstream.megabytesPerSec)
                        : tr('不可用'),
                  ),
                  _briefRow(
                    '上行速率',
                    r.upstream.ok
                        ? formatMBs(r.upstream.megabytesPerSec)
                        : tr('不可用'),
                  ),
                  _briefRow(
                    '平均延迟',
                    r.latency.hasData
                        ? formatMs(r.latency.avgMs)
                        : tr('不可用'),
                  ),
                ],
        );
      },
    );
  }
}

/// IP 检测详情：连接概览 / 公网 IP 与属地 / 可信度。
class IpDetailPage extends StatelessWidget {
  const IpDetailPage({super.key, required this.controller});

  final IpDiagnosisController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('IP 检测'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          IpDiagnosisCard(
            controller: controller,
            mode: IpDetailMode.ip,
            title: tr('检测结果'),
          ),
        ],
      ),
    );
  }
}

/// 网络测速详情：延迟、抖动、上下行速率与多点测速折线。
class SpeedDetailPage extends StatelessWidget {
  const SpeedDetailPage({super.key, required this.controller});

  final IpDiagnosisController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('网络测速'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          IpDiagnosisCard(
            controller: controller,
            mode: IpDetailMode.speed,
            title: tr('测试结果'),
          ),
        ],
      ),
    );
  }
}

Widget _briefRow(String label, String value) => StatRow(
      label: tr(label),
      value: value,
      flexibleValue: true,
    );

String _connection(DiagnosisResult r) {
  final n = r.networkInfo;
  if (!n.systemAvailable) return tr('系统网络信息不可用');
  return n.type == 'none' ? tr('未连接') : tr('已连接');
}

String _categoryLabel(IpCategory c) => tr(switch (c) {
      IpCategory.datacenter => '机房 / 云服务商',
      IpCategory.broadband => '家庭 / 企业宽带',
      IpCategory.mobile => '移动网络',
      IpCategory.vpnProxy => 'VPN / 代理 / 匿名',
      IpCategory.unknown => '未知',
    });
