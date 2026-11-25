import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/widgets/app_widgets.dart';
import 'decibel_meter.dart';
import 'decibel_view.dart';
import 'light_meter.dart';
import 'light_view.dart';
import 'measure_geometry.dart';
import 'protractor_view.dart';
import 'ruler_view.dart';

/// 测量工具：屏幕尺子、量角器、分贝仪与光强计。
///
/// 尺子按「逻辑像素 / 厘米」绘制，默认值来自 Android 的 160dpi 名义换算，
/// 可用银行卡短边（53.98mm）校准到接近真实尺寸。
class MeasurePage extends StatefulWidget {
  const MeasurePage({
    super.key,
    this.decibelController,
    this.lightController,
    this.initialPxPerCm,
  });

  /// 测试注入的分贝控制器。
  final DecibelController? decibelController;

  /// 测试注入的光强控制器。
  final LightMeterController? lightController;

  /// 测试注入的初始校准值，省去异步读取。
  final double? initialPxPerCm;

  @override
  State<MeasurePage> createState() => _MeasurePageState();
}

class _MeasurePageState extends State<MeasurePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  /// 当前全屏的工具：null 普通；0 尺子；1 量角器。
  int? _fullscreen;

  double _pxPerCm = MeasureGeometry.nominalPxPerCm;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.initialPxPerCm != null) {
      _pxPerCm = widget.initialPxPerCm!;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final value = await MeasureGeometry.loadPxPerCm();
    if (!mounted) return;
    setState(() {
      _pxPerCm = value;
      _loading = false;
    });
  }

  Future<void> _reset() async {
    await MeasureGeometry.savePxPerCm(MeasureGeometry.nominalPxPerCm);
    if (!mounted) return;
    setState(() => _pxPerCm = MeasureGeometry.nominalPxPerCm);
    showToast(context, tr('已恢复默认校准'));
  }

  Future<void> _calibrate() async {
    var draft = _pxPerCm;
    final result = await showDialog<double>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return StatefulBuilder(
          builder: (context, setLocal) => AlertDialog(
            title: Text(tr('校准尺子')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('拿一张银行卡或身份证，用短边（53.98mm）贴住手机屏幕，拖动滑块让下面的线段与卡片短边等长。'),
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final maxWidth = constraints.maxWidth;
                    final target = MeasureGeometry.cardShortSideCm * draft;
                    final width = target.clamp(24.0, maxWidth);
                    return Container(
                      height: 34,
                      width: width,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(0.14),
                        border: Border.all(
                          color: theme.colorScheme.primary,
                          width: 1.4,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '53.98 mm',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    );
                  },
                ),
                Slider(
                  value: draft.clamp(
                    MeasureGeometry.minPxPerCm,
                    MeasureGeometry.maxPxPerCm,
                  ),
                  min: MeasureGeometry.minPxPerCm,
                  max: MeasureGeometry.maxPxPerCm,
                  onChanged: (v) => setLocal(() => draft = v),
                ),
                Text(
                  '${tr('当前')}：${draft.toStringAsFixed(1)} ${tr('逻辑像素/厘米')}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr('取消')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(draft),
                child: Text(tr('保存')),
              ),
            ],
          ),
        );
      },
    );
    if (result == null) return;
    await MeasureGeometry.savePxPerCm(result);
    if (!mounted) return;
    setState(() => _pxPerCm = result);
    showToast(context, tr('校准已保存'));
  }

  // ---------------- 全屏模式 ----------------

  Future<void> _enterFullscreen(int tool) async {
    setState(() => _fullscreen = tool);
    // 全屏测量：隐藏系统状态栏 / 导航栏，并转到横屏以获得更长的测量范围。
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } catch (_) {
      // 测试环境或个别设备不支持系统 UI 控制时不影响功能。
    }
  }

  Future<void> _exitFullscreen() async {
    setState(() => _fullscreen = null);
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
    } catch (_) {
      // 同上，忽略。
    }
  }

  /// 全屏时的退出按钮。
  Widget _exitButton() {
    return IconButton.filledTonal(
      key: const ValueKey('measure-exit-fullscreen'),
      onPressed: _exitFullscreen,
      icon: const Icon(Icons.fullscreen_exit, size: 22),
      tooltip: tr('退出全屏'),
      style: IconButton.styleFrom(
        backgroundColor:
            Theme.of(context).colorScheme.surface.withOpacity(0.72),
      ),
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    // 页面销毁时把系统 UI / 方向恢复默认，防止状态残留。
    try {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
    } catch (_) {
      // 忽略。
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fullscreen = _fullscreen;
    if (fullscreen != null && !_loading) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _exitFullscreen();
        },
        child: Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: fullscreen == 0
              ? RulerView(
                  key: const ValueKey('ruler-fullscreen'),
                  pxPerCm: _pxPerCm,
                  onCalibrate: _calibrate,
                  onReset: _reset,
                  fullscreen: true,
                  onExitFullscreen: _exitButton(),
                )
              : ProtractorView(
                  key: const ValueKey('protractor-fullscreen'),
                  fullscreen: true,
                  onExitFullscreen: _exitButton(),
                ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('测量工具')),
        bottom: TabBar(
          controller: _tabs,
          tabs: <Widget>[
            Tab(icon: const Icon(Icons.straighten, size: 18), text: tr('尺子')),
            Tab(
              icon: const Icon(Icons.architecture, size: 18),
              text: tr('量角器'),
            ),
            Tab(icon: const Icon(Icons.graphic_eq, size: 18), text: tr('分贝仪')),
            Tab(
              icon: const Icon(Icons.light_mode_outlined, size: 18),
              text: tr('光强计'),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: <Widget>[
                Padding(
                  // 左右不留白：尺子 0 刻度要贴合屏幕左边缘。
                  padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
                  child: RulerView(
                    pxPerCm: _pxPerCm,
                    onCalibrate: _calibrate,
                    onReset: _reset,
                    onFullscreen: () => _enterFullscreen(0),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: ProtractorView(
                    onFullscreen: () => _enterFullscreen(1),
                  ),
                ),
                DecibelView(controller: widget.decibelController),
                LightView(controller: widget.lightController),
              ],
            ),
      backgroundColor: theme.colorScheme.surface,
    );
  }
}
