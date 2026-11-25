import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/storage/app_files.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/mini_segmented.dart';
import 'watermark_engine.dart';
import 'watermark_font_store.dart';
import 'watermark_live_data.dart';

/// 把槽位 [from] 的字段移到 [to]（其余槽位顺次补位，便于测试）。
List<WatermarkItem?> reorderWatermarkSlot(
  List<WatermarkItem?> slots,
  int from,
  int to,
) {
  if (from == to ||
      from < 0 ||
      to < 0 ||
      from >= slots.length ||
      to >= slots.length) {
    return slots;
  }
  final next = List<WatermarkItem?>.from(slots);
  final item = next.removeAt(from);
  next.insert(to, item);
  return next;
}

/// 图片水印：给照片加文字水印，预置平铺 / 居中 / 角落三种版式，
/// 字号、密度、斜率、透明度、黑白颜色均可调，导出 PNG 到存储空间。
/// 字体不内置，按需由用户导入 .ttf/.otf。
class WatermarkPage extends StatefulWidget {
  const WatermarkPage({
    super.key,
    this.fontStore,
    this.liveData,
  });

  /// 可注入的字体仓库（测试用）。
  final WatermarkFontStore? fontStore;

  /// 可注入的实时数据采集（测试用）。
  final WatermarkLiveData? liveData;

  @override
  State<WatermarkPage> createState() => _WatermarkPageState();
}

class _WatermarkPageState extends State<WatermarkPage> {
  late final WatermarkFontStore _fonts =
      widget.fontStore ?? WatermarkFontStore();
  late final WatermarkLiveData _live = widget.liveData ?? WatermarkLiveData();
  List<UserWatermarkFont> _userFonts = const <UserWatermarkFont>[];

  ui.Image? _image;
  String _text = '';
  WatermarkSettings _settings = const WatermarkSettings(text: '');

  /// 角落水印 3×2 空白模板：6 个槽位，null 表示尚未填入字段。
  /// 长按可把已填字段拖到其它槽位（含空槽），顺序即拼接顺序。
  List<WatermarkItem?> _slots = List<WatermarkItem?>.filled(6, null);
  int _itemSeq = 0;

  /// 预览用的实时快照（采集后定格，导出/拍照与预览一致）。
  WatermarkSnapshot _snapshot = const WatermarkSnapshot();

  bool _picking = false;
  bool _saving = false;
  bool _importingFont = false;
  bool _collecting = false;
  bool _slidersExpanded = true;

  @override
  void initState() {
    super.initState();
    _loadFonts();
  }

  Future<void> _loadFonts() async {
    await _fonts.registerAll();
    final fonts = await _fonts.load();
    if (!mounted) return;
    setState(() => _userFonts = fonts);
  }

  Future<void> _importFont() async {
    if (_importingFont) return;
    setState(() => _importingFont = true);
    try {
      final font = await _fonts.importFont();
      if (!mounted) return;
      if (font != null) {
        await _loadFonts();
        if (!mounted) return;
        _update(_settings.copyWith(fontFamily: font.family));
      }
    } catch (e) {
      if (mounted) showToast(context, trf('字体导入失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _importingFont = false);
    }
  }

  Future<void> _removeFont(UserWatermarkFont font) async {
    await _fonts.remove(font);
    if (!mounted) return;
    final resetting = _settings.fontFamily == font.family;
    setState(() {
      _userFonts = _userFonts.where((f) => f.family != font.family).toList();
      if (resetting) {
        _settings = _settings.copyWith(fontFamily: null);
      }
    });
  }

  /// 已填入的槽位（保持模板顺序），空槽不参与渲染。
  List<WatermarkItem> get _filledItems =>
      _slots.whereType<WatermarkItem>().toList(growable: false);

  /// 角落多行模式只需有图且至少填了一格；其余版式沿用文本框。
  bool get _isMultiLine =>
      _settings.type == WatermarkType.corner && _filledItems.isNotEmpty;
  bool get _ready =>
      _image != null && (_isMultiLine || _text.trim().isNotEmpty);

  /// 把 3×2 模板压成引擎用的行；自定义字段直接取上方「水印文字」。
  List<WatermarkRow> get _rowsFromSlots {
    final rows = <WatermarkRow>[];
    for (var i = 0; i < _slots.length; i += 2) {
      final items = <WatermarkItem>[];
      for (final item in _slots.sublist(i, i + 2).whereType<WatermarkItem>()) {
        items.add(item.field == WatermarkField.custom
            ? WatermarkItem(field: item.field, customText: _text, id: item.id)
            : item);
      }
      if (items.isNotEmpty) rows.add(WatermarkRow(id: 'row-$i', items: items));
    }
    return rows;
  }

  WatermarkSettings get _renderSettings =>
      _settings.copyWith(rows: _rowsFromSlots);

  Future<void> _pickImage({ImageSource source = ImageSource.gallery}) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2560,
        imageQuality: 95,
      );
      if (picked == null) return;
      final bytes = await File(picked.path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() => _image = frame.image);

      // 拍照（相机）时在按下快门的此刻采集实时信息并自动烧录水印。
      if (source == ImageSource.camera && _isMultiLine) {
        await _autoSaveCaptured(frame.image);
      }
    } catch (e) {
      if (mounted) showToast(context, trf('读取图片失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 采集实时信息 → 定格快照 → 把水印烧录进刚拍的照片并自动保存。
  Future<void> _autoSaveCaptured(ui.Image image) async {
    setState(() => _collecting = true);
    try {
      final fields = _filledItems.map((i) => i.field);
      final needsGeo = fields
          .any((f) => f == WatermarkField.geo || f == WatermarkField.altitude);
      final needsTemp = fields.any((f) => f == WatermarkField.temperature);
      final snapshot = await _live.collect(
        includeGeo: needsGeo,
        includeTemperature: needsTemp,
      );
      if (!mounted) return;
      setState(() => _snapshot = snapshot);

      final rendered =
          await renderWatermarked(image, _renderSettings, snapshot: snapshot);
      final byteData =
          await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw StateError('导出图片失败');
      final stored = await AppStore.saveBytes(
        category: AppStoreCategory.other,
        name: 'watermark-camera-${_stamp()}.png',
        bytes: byteData.buffer.asUint8List(),
      );
      if (!mounted) return;
      showToast(context, trf('已拍照并添加水印：{n}', {'n': stored.name}));
    } catch (e) {
      if (mounted) showToast(context, trf('拍照水印失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _collecting = false);
    }
  }

  String _stamp() {
    final now = DateTime.now();
    return '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
  }

  void _update(WatermarkSettings settings) {
    setState(() => _settings = settings.copyWith(text: _text));
  }

  static const List<WatermarkField> _candidateFields = <WatermarkField>[
    WatermarkField.date,
    WatermarkField.time,
    WatermarkField.geo,
    WatermarkField.altitude,
    WatermarkField.temperature,
    WatermarkField.custom,
  ];

  String _fieldLabel(WatermarkField field) => switch (field) {
        WatermarkField.custom => tr('自定义'),
        WatermarkField.date => tr('日期'),
        WatermarkField.time => tr('时间'),
        WatermarkField.temperature => tr('温度'),
        WatermarkField.altitude => tr('海拔'),
        WatermarkField.geo => tr('经纬度'),
      };

  /// 点击空格后从下拉选字段填入；重复点已填格可换字段，清空则置空。
  void _setSlot(int index, WatermarkField? field) {
    setState(() {
      _slots[index] = field == null
          ? null
          : WatermarkItem(field: field, id: 'item-${_itemSeq++}');
    });
  }

  /// 长按拖动：把 [from] 的字段移动到 [to]，其余顺次补位。
  void _moveSlot(int from, int to) {
    setState(() => _slots = reorderWatermarkSlot(_slots, from, to));
  }

  /// 点击槽位弹出字段菜单；已填的槽还能清空。
  Future<void> _pickSlotField(int index, TapDownDetails details) async {
    final choice = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx,
        details.globalPosition.dy,
      ),
      items: [
        for (final field in _candidateFields)
          PopupMenuItem<int>(
            key: ValueKey('wm-slot-$index-$field'),
            value: field.index,
            child: Text(_fieldLabel(field)),
          ),
        if (_slots[index] != null)
          PopupMenuItem<int>(
            key: ValueKey('wm-slot-$index-clear'),
            value: -1,
            child: Text(tr('清空')),
          ),
      ],
    );
    if (choice == null || !mounted) return;
    _setSlot(index, choice == -1 ? null : WatermarkField.values[choice]);
  }

  Widget _slotCell(BuildContext context, int index) {
    final item = _slots[index];
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<int>(
      key: ValueKey('wm-slot-$index'),
      onAcceptWithDetails: (details) => _moveSlot(details.data, index),
      builder: (context, candidates, rejected) {
        final cell = Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: item == null
                ? scheme.surfaceContainerHighest.withOpacity(0.25)
                : scheme.primary.withOpacity(0.08),
            border: Border.all(
              color: candidates.isNotEmpty
                  ? scheme.primary
                  : scheme.outlineVariant.withOpacity(0.6),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: item == null
              ? Icon(Icons.add, size: 16, color: scheme.outline)
              : Text(
                  item.field == WatermarkField.custom && _text.trim().isNotEmpty
                      ? _text.trim()
                      : _fieldLabel(item.field),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        );
        final tappable = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _pickSlotField(index, details),
          child: cell,
        );
        if (item == null) return tappable;
        return LongPressDraggable<int>(
          data: index,
          feedback: Material(
            elevation: 2,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(width: 90, child: cell),
          ),
          childWhenDragging: Opacity(opacity: 0.4, child: tappable),
          child: tappable,
        );
      },
    );
  }

  Future<void> _save() async {
    final image = _image;
    if (image == null || !_ready || _saving) return;
    setState(() => _saving = true);
    try {
      final rendered =
          await renderWatermarked(image, _renderSettings, snapshot: _snapshot);
      final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('导出图片失败');
      final stored = await AppStore.saveBytes(
        category: AppStoreCategory.other,
        name: 'watermark-${_stamp()}.png',
        bytes: bytes.buffer.asUint8List(),
      );
      if (!mounted) return;
      showToast(context, trf('已保存到存储空间：{n}', {'n': stored.name}));
    } catch (e) {
      if (mounted) showToast(context, trf('保存失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final image = _image;

    return Scaffold(
      appBar: AppBar(title: Text(tr('图片水印'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
        children: [
          // 预览
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  if (image == null)
                    Container(
                      height: 200,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.image_outlined,
                              size: 40, color: scheme.outline),
                          const SizedBox(height: 8),
                          Text(
                            tr('先选择一张照片'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    AspectRatio(
                      aspectRatio: image.width / image.height,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CustomPaint(
                          painter: _WatermarkPreviewPainter(
                            image: image,
                            settings: _renderSettings,
                            snapshot: _snapshot,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('wm-pick'),
                          onPressed: _picking ? null : () => _pickImage(),
                          icon: const Icon(Icons.photo_library_outlined,
                              size: 18),
                          label: Text(image == null ? tr('选择照片') : tr('更换照片')),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('wm-camera'),
                          onPressed: _picking
                              ? null
                              : () => _pickImage(source: ImageSource.camera),
                          icon: const Icon(Icons.camera_alt_outlined, size: 18),
                          label: Text(tr('拍照水印')),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('wm-save'),
                      onPressed:
                          _ready && !_saving && !_collecting ? _save : null,
                      icon: _saving || _collecting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_rounded, size: 18),
                      label: Text(_collecting ? tr('正在添加水印…') : tr('保存图片')),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 样式设置
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('wm-text'),
                    decoration: InputDecoration(
                      labelText: tr('水印文字'),
                      hintText: tr('例如：仅供个人使用'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (value) => setState(() {
                      _text = value.trim();
                      _settings = _settings.copyWith(text: _text);
                    }),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        tr('水印版式'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      MiniSegmented<WatermarkType>(
                        options: [
                          MiniSegmentedOption(
                            value: WatermarkType.tile,
                            label: tr('平铺'),
                            key: const ValueKey('wm-type-tile'),
                          ),
                          MiniSegmentedOption(
                            value: WatermarkType.center,
                            label: tr('居中'),
                            key: const ValueKey('wm-type-center'),
                          ),
                          MiniSegmentedOption(
                            value: WatermarkType.corner,
                            label: tr('角落'),
                            key: const ValueKey('wm-type-corner'),
                          ),
                        ],
                        selected: _settings.type,
                        onChanged: (type) =>
                            _update(_settings.copyWith(type: type)),
                      ),
                      const Spacer(),
                      IconButton(
                        key: const ValueKey('wm-sliders-toggle'),
                        icon: Icon(
                          _slidersExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 18,
                        ),
                        tooltip: _slidersExpanded ? tr('收起') : tr('展开调节'),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                            width: 30, height: 30),
                        onPressed: () => setState(
                            () => _slidersExpanded = !_slidersExpanded),
                      ),
                    ],
                  ),
                  if (_slidersExpanded) ...[
                    const SizedBox(height: 6),
                    _SliderTile(
                      key: const ValueKey('wm-size'),
                      label: tr('大小'),
                      value: _settings.sizeFactor,
                      min: 0.02,
                      max: 0.12,
                      display:
                          '${(_settings.sizeFactor * 100).toStringAsFixed(1)}%',
                      onChanged: (v) =>
                          _update(_settings.copyWith(sizeFactor: v)),
                    ),
                    if (_settings.type == WatermarkType.tile)
                      _SliderTile(
                        key: const ValueKey('wm-density'),
                        label: tr('密度'),
                        value: _settings.density,
                        min: 0.4,
                        max: 2.5,
                        display: _settings.density.toStringAsFixed(1),
                        onChanged: (v) =>
                            _update(_settings.copyWith(density: v)),
                      ),
                    _SliderTile(
                      key: const ValueKey('wm-angle'),
                      label: tr('斜率'),
                      value: _settings.angleDeg,
                      min: -90,
                      max: 90,
                      display: '${_settings.angleDeg.toStringAsFixed(0)}°',
                      onChanged: (v) =>
                          _update(_settings.copyWith(angleDeg: v)),
                    ),
                    _SliderTile(
                      key: const ValueKey('wm-opacity'),
                      label: tr('透明度'),
                      value: _settings.opacity,
                      min: 0.05,
                      max: 1,
                      display:
                          '${(_settings.opacity * 100).toStringAsFixed(0)}%',
                      onChanged: (v) => _update(_settings.copyWith(opacity: v)),
                    ),
                  ],
                  if (_settings.type == WatermarkType.corner) ...[
                    const SizedBox(height: 12),
                    Text(
                      tr('水印内容'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      key: const ValueKey('wm-field-list'),
                      child: Column(
                        children: [
                          for (var row = 0; row < 3; row++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  for (var col = 0; col < 2; col++) ...[
                                    if (col > 0) const SizedBox(width: 6),
                                    Expanded(
                                        child:
                                            _slotCell(context, row * 2 + col)),
                                  ],
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          tr('水印位置'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        MiniSegmented<WatermarkCorner>(
                          options: const [
                            MiniSegmentedOption(
                              value: WatermarkCorner.topLeft,
                              label: '↖',
                              key: ValueKey('wm-corner-tl'),
                            ),
                            MiniSegmentedOption(
                              value: WatermarkCorner.topRight,
                              label: '↗',
                              key: ValueKey('wm-corner-tr'),
                            ),
                            MiniSegmentedOption(
                              value: WatermarkCorner.bottomLeft,
                              label: '↙',
                              key: ValueKey('wm-corner-bl'),
                            ),
                            MiniSegmentedOption(
                              value: WatermarkCorner.bottomRight,
                              label: '↘',
                              key: ValueKey('wm-corner-br'),
                            ),
                          ],
                          selected: _settings.corner,
                          onChanged: (c) =>
                              _update(_settings.copyWith(corner: c)),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        tr('字体'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            ChoiceChip(
                              key: const ValueKey('wm-font-default'),
                              label: Text(tr('默认')),
                              selected: _settings.fontFamily == null,
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) =>
                                  _update(_settings.copyWith(fontFamily: null)),
                            ),
                            for (final font in _userFonts)
                              InputChip(
                                key: ValueKey('wm-font-${font.family}'),
                                label: Text(font.name),
                                selected: _settings.fontFamily == font.family,
                                visualDensity: VisualDensity.compact,
                                labelStyle: TextStyle(fontFamily: font.family),
                                onPressed: () => _update(_settings.copyWith(
                                    fontFamily: font.family)),
                                onDeleted: () => _removeFont(font),
                                deleteIcon: const Icon(Icons.close, size: 15),
                              ),
                            ActionChip(
                              key: const ValueKey('wm-font-import'),
                              avatar: _importingFont
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.add, size: 16),
                              label: Text(tr('导入字体')),
                              visualDensity: VisualDensity.compact,
                              onPressed: _importingFont ? null : _importFont,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        tr('颜色'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      MiniSegmented<bool>(
                        options: [
                          MiniSegmentedOption(
                            value: false,
                            label: tr('白字'),
                            key: const ValueKey('wm-color-white'),
                          ),
                          MiniSegmentedOption(
                            value: true,
                            label: tr('黑字'),
                            key: const ValueKey('wm-color-black'),
                          ),
                        ],
                        selected: _settings.darkText,
                        onChanged: (value) =>
                            _update(_settings.copyWith(darkText: value)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        tr('文字描边'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      Switch(
                        key: const ValueKey('wm-outline'),
                        value: _settings.outline,
                        onChanged: (value) =>
                            _update(_settings.copyWith(outline: value)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SmallHint(
            text: tr('提示：平铺水印适合防盗声明，角落适合签名；斜率 -30° 左右最自然。'),
          ),
        ],
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: theme.textTheme.labelMedium,
          ),
        ),
      ],
    );
  }
}

/// 预览画笔：按显示尺寸等比缩放绘制原图与水印，
/// 与导出（原分辨率 renderWatermarked）使用同一套绘制逻辑。
class _WatermarkPreviewPainter extends CustomPainter {
  _WatermarkPreviewPainter({
    required this.image,
    required this.settings,
    required this.snapshot,
  });

  final ui.Image image;
  final WatermarkSettings settings;
  final WatermarkSnapshot snapshot;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / image.width;
    canvas.save();
    canvas.scale(scale);
    canvas.drawImage(image, Offset.zero, Paint());
    paintWatermark(
      canvas,
      Size(image.width.toDouble(), image.height.toDouble()),
      settings,
      snapshot: snapshot,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WatermarkPreviewPainter old) =>
      old.image != image ||
      old.settings != settings ||
      old.snapshot != snapshot;
}
