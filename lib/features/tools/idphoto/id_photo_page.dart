import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/platform/id_photo.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/storage/app_files.dart';
import '../../../core/widgets/app_widgets.dart';
import 'id_photo_crop_page.dart';
import 'id_photo_spec.dart';

/// 原生异常转成一句人话：PlatformException 带上原生抛出的中文原因，
/// 不再把整段 Java 堆栈糊到提示里。
String idPhotoErrorText(Object error) {
  if (error is PlatformException) {
    final message = error.message?.trim();
    if (message != null && message.isNotEmpty) return message;
    return error.code;
  }
  return '$error';
}

/// 证件照工具的两种用法：把生活照转成证件照、给已有证件照换底改尺寸。
enum IdPhotoMode {
  /// 相册选图 → 人脸校验 → 裁切 → 抠图换底。
  photoToId,

  /// 已有证件照 → 只换底色 / 改尺寸体积，不做人脸校验。
  idToSize,
}

typedef IdPhotoStorageSaver = Future<String> Function(
  List<int> bytes,
  String name,
);

/// 默认保存：写进应用存储空间，文字阅读器 / 分享都能直接用。
Future<String> defaultIdPhotoStorageSaver(
  List<int> bytes,
  String name,
) async {
  final stored = await AppStore.saveBytes(
    category: AppStoreCategory.other,
    name: name,
    bytes: bytes,
  );
  return stored.name;
}

/// 读成品文件字节：默认真实读盘，测试可注入。
typedef IdPhotoBytesLoader = Future<List<int>> Function(String path);

Future<List<int>> defaultIdPhotoBytesLoader(String path) =>
    File(path).readAsBytes();

/// 证件照：照片转证件照 / 证件照换底改尺寸。
///
/// 抠图、合成、压缩、导出都在原生侧完成（U²-Net LiteRT + ML Kit），
/// 页面只负责交互；引擎、选图、保存全部可注入，widget 测试不碰真实通道。
class IdPhotoPage extends StatefulWidget {
  const IdPhotoPage({
    super.key,
    this.engine,
    this.picker = defaultIdPhotoPicker,
    this.saver = defaultIdPhotoStorageSaver,
    this.bytesLoader = defaultIdPhotoBytesLoader,
    this.cropBuilder,
  });

  /// 测试注入：默认用真实原生通道。
  final IdPhotoEngine? engine;
  final IdPhotoPicker picker;
  final IdPhotoStorageSaver saver;

  /// 测试注入：默认真实读盘；widget 测试里换成假数据，避免 FakeAsync 卡住。
  final IdPhotoBytesLoader bytesLoader;

  /// 测试注入：替换裁切页。
  final Widget Function(String path, double ratio, Rect? initial)? cropBuilder;

  @override
  State<IdPhotoPage> createState() => _IdPhotoPageState();
}

class _IdPhotoPageState extends State<IdPhotoPage> {
  late final IdPhotoEngine _engine = widget.engine ?? IdPhotoBridge();

  IdPhotoMode _mode = IdPhotoMode.photoToId;
  IdPhotoSpec _spec = kIdPhotoSpecs.first;
  IdPhotoBackground _background = kIdPhotoBackgrounds.first;
  int _maxKb = kIdPhotoSpecs.first.defaultMaxKb;

  /// 边缘蒙版收缩（0~1）：越大越紧贴人像，去掉原底色的残留描边。
  double _edgeShrink = 0;

  /// 已选照片与裁切框：换底色 / 调边缘时直接复用，不用重新选图、重新裁切。
  String? _sourcePath;
  Rect? _crop;

  bool _busy = false;
  String _status = '';
  IdPhotoResult? _result;

  Future<void> _pick() async {
    if (_busy) return;
    final path = await widget.picker(IdPhotoImageSource.gallery);
    if (path == null || !mounted) return;
    Rect? initial;
    if (_mode == IdPhotoMode.photoToId) {
      final ok = await _checkFace(path);
      if (!ok || !mounted) return;
      initial = _suggestedCrop;
    }
    await _cropAndProcess(path, initial);
  }

  Rect? _suggestedCrop;

  /// 人脸校验：无人脸 / 多人脸 / 角度偏大都要求重选，避免抠出歪图。
  Future<bool> _checkFace(String path) async {
    setState(() {
      _busy = true;
      _status = tr('正在检测人脸…');
    });
    try {
      final face = await _engine.detectFace(path);
      final issue = judgeFace(face);
      if (!mounted) return false;
      if (issue != FaceIssue.none) {
        // 先收掉进度条再弹窗：否则对话框背后的不定长进度条一直在动，
        // 测试里的 pumpAndSettle 永远等不到静止。
        setState(() {
          _busy = false;
          _status = '';
        });
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(tr('这张照片不合适')),
            content: issue == FaceIssue.multiple
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(_issueText(issue)),
                      const SizedBox(height: 10),
                      Text(
                        tr('若照片里只有一人，多半是背景人像或花纹被误识别，可继续用最大的一张人脸。'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  )
                : Text(_issueText(issue)),
            actions: <Widget>[
              TextButton(
                key: const ValueKey('idphoto-face-retry'),
                onPressed: () => Navigator.of(context).pop('retry'),
                child: Text(tr('重新选择')),
              ),
              if (issue == FaceIssue.multiple)
                FilledButton(
                  key: const ValueKey('idphoto-face-largest'),
                  onPressed: () => Navigator.of(context).pop('largest'),
                  child: Text(tr('只用最大的人脸')),
                ),
            ],
          ),
        );
        // 多人脸时允许直接用最大的一张脸继续，避免误检把用户卡死。
        if (choice != 'largest') return false;
      }
      _suggestedCrop = suggestCrop(
        face,
        _spec.ratio,
        face.imageWidth,
        face.imageHeight,
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _busy = false;
        _status = '';
      });
      showToast(context, trf('人脸检测失败：{e}', {'e': idPhotoErrorText(e)}));
      return false;
    }
  }

  String _issueText(FaceIssue issue) => switch (issue) {
        FaceIssue.noFace => tr('没有检测到人脸，请换一张清晰的正面照'),
        FaceIssue.multiple => tr('检测到多张人脸，请上传只包含本人的照片'),
        FaceIssue.tilted => tr('人脸角度偏大，请换一张正脸照'),
        FaceIssue.none => '',
      };

  Future<void> _cropAndProcess(String path, Rect? initial) async {
    final ratio = _spec.ratio;
    final rect = await Navigator.of(context).push<Rect>(
      MaterialPageRoute<Rect>(
        builder: (context) => widget.cropBuilder != null
            ? widget.cropBuilder!(path, ratio, initial)
            : IdPhotoCropPage(
                imagePath: path,
                aspectRatio: ratio,
                initialRect: initial,
              ),
      ),
    );
    if (rect == null || !mounted) return;
    await _process(path, rect);
  }

  /// 重新裁切同一张照片（不重新选图），用于改了尺寸规格之后。
  Future<void> _recrop() async {
    final source = _sourcePath;
    final previous = _crop;
    if (source == null || previous == null || _busy) return;
    final rect = await Navigator.of(context).push<Rect>(
      MaterialPageRoute<Rect>(
        builder: (context) => widget.cropBuilder != null
            ? widget.cropBuilder!(source, _spec.ratio, previous)
            : IdPhotoCropPage(
                imagePath: source,
                aspectRatio: _spec.ratio,
                initialRect: previous,
              ),
      ),
    );
    if (rect == null || !mounted) return;
    await _process(source, rect);
  }

  Future<void> _process(String path, Rect crop) async {
    setState(() {
      _busy = true;
      _status = tr('正在抠图…');
      _result = null;
    });
    try {
      final result = await _engine.process(
        IdPhotoRequest(
          sourcePath: path,
          crop: crop,
          background: _background.color,
          width: _spec.widthPx,
          height: _spec.heightPx,
          maxKb: _maxKb,
          edgeShrink: _edgeShrink,
        ),
        onProgress: (stage, value) {
          if (!mounted) return;
          final text = switch (stage) {
            IdPhotoStage.matte => tr('正在抠图…'),
            IdPhotoStage.composite => tr('正在合成背景…'),
            IdPhotoStage.compress => tr('正在压缩体积…'),
            _ => '',
          };
          if (text.isEmpty) return;
          setState(() => _status = text);
        },
      );
      if (!mounted) return;
      setState(() {
        _sourcePath = path;
        _crop = crop;
        _result = result;
        _busy = false;
        _status = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '';
      });
      showToast(context, trf('处理失败：{e}', {'e': idPhotoErrorText(e)}));
    }
  }

  /// 换底色 / 调边缘收缩 / 改体积：复用原生抠图缓存即时重出图。
  /// 缓存不存在（例如进程被回收）时自动回退到完整处理，且不重新选图。
  Future<void> _recolor() async {
    final source = _sourcePath;
    final crop = _crop;
    if (source == null || crop == null || _busy || _result == null) return;
    setState(() {
      _busy = true;
      _status = tr('正在换底色…');
    });
    try {
      final result = await _engine.recolor(
        IdPhotoRecolorRequest(
          background: _background.color,
          edgeShrink: _edgeShrink,
          maxKb: _maxKb,
        ),
      );
      if (result != null) {
        if (!mounted) return;
        setState(() {
          _result = result;
          _busy = false;
          _status = '';
        });
        return;
      }
    } catch (_) {
      // 原生缓存失效：走完整流程，仍然用已缓存的原图与裁切框。
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '';
    });
    await _process(source, crop);
  }

  void _selectBackground(IdPhotoBackground bg) {
    if (_busy || bg.id == _background.id) return;
    setState(() => _background = bg);
    _recolor();
  }

  void _selectMaxKb(int kb) {
    if (_busy || kb == _maxKb) return;
    setState(() => _maxKb = kb);
    _recolor();
  }

  void _changeEdgeShrink(double value, {required bool commit}) {
    if (_busy) return;
    setState(() => _edgeShrink = value);
    if (commit) _recolor();
  }

  Future<void> _saveToGallery() async {
    final result = _result;
    if (result == null) return;
    final ok = await _engine.saveToGallery(
        result.path, idPhotoFileName(DateTime.now()));
    if (!mounted) return;
    showToast(context, ok ? tr('已保存到相册') : tr('写入相册失败，可改用保存到存储空间'));
  }

  Future<void> _saveToStorage() async {
    final result = _result;
    if (result == null) return;
    try {
      final bytes = await widget.bytesLoader(result.path);
      final name = await widget.saver(bytes, idPhotoFileName(DateTime.now()));
      if (!mounted) return;
      showToast(context, trf('已保存到存储空间：{n}', {'n': name}));
    } catch (e) {
      if (mounted) {
        showToast(context, trf('保存失败：{e}', {'e': idPhotoErrorText(e)}));
      }
    }
  }

  void _selectSpec(IdPhotoSpec spec) {
    if (_busy || spec.id == _spec.id) return;
    setState(() {
      _spec = spec;
      // 规格变了，体积档位跟着回到该规格的常见上限。
      _maxKb = spec.defaultMaxKb;
    });
    // 比例变了必须重新取景，否则成片会被拉伸；仍然复用已选的那张照片。
    if (_sourcePath != null && _crop != null) _recrop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('证件照'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: <Widget>[
          // 成片放最上面：出图后不用滚动就能看到，下面是可随时改的参数。
          if (_result != null) ...<Widget>[
            _resultCard(context, _result!),
            const SizedBox(height: 18),
          ],
          _modeSelector(),
          const SizedBox(height: 18),
          // 尺寸 / 底色 / 体积都收成单行下拉：选项多但一次只看当前值，
          // 比三排 ChoiceChip 省两屏高度。
          _optionRow(tr('尺寸'), _specDropdown()),
          const SizedBox(height: 10),
          _optionRow(tr('底色'), _backgroundDropdown(context)),
          const SizedBox(height: 14),
          _section(tr('边缘收缩'), _edgeShrinkControl(context)),
          const SizedBox(height: 14),
          _optionRow(tr('文件大小'), _sizeDropdown()),
          const SizedBox(height: 20),
          if (_busy) ...<Widget>[
            const LinearProgressIndicator(minHeight: 3),
            const SizedBox(height: 8),
            SmallHint(text: _status),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 20),
          SmallHint(
            text: _mode == IdPhotoMode.photoToId
                ? tr('自动抠图并换成所选底色，导出前会按目标尺寸与体积压缩')
                : tr('已有证件照可直接换底色、改尺寸与体积，不做人脸校验'),
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SmallHint(
                text: tr('出图后再点底色或拖动边缘收缩会即时重出，无需重新选图'),
              ),
            ),
        ],
      ),
      // 选图是第一步，也是唯一的主操作；固定到底部，改完参数不必滚回顶部。
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: FilledButton.icon(
          key: const ValueKey('idphoto-pick'),
          onPressed: _busy ? null : _pick,
          icon: const Icon(Icons.photo_library_outlined, size: 20),
          label: Text(
            _mode == IdPhotoMode.photoToId ? tr('选择照片') : tr('选择证件照'),
          ),
        ),
      ),
    );
  }

  Widget _modeSelector() {
    return SegmentedButton<IdPhotoMode>(
      segments: <ButtonSegment<IdPhotoMode>>[
        ButtonSegment<IdPhotoMode>(
          value: IdPhotoMode.photoToId,
          icon: const Icon(Icons.face_retouching_natural_outlined, size: 18),
          label: Text(tr('照片转证件照')),
        ),
        ButtonSegment<IdPhotoMode>(
          value: IdPhotoMode.idToSize,
          icon: const Icon(Icons.crop_outlined, size: 18),
          label: Text(tr('换底改尺寸')),
        ),
      ],
      selected: <IdPhotoMode>{_mode},
      showSelectedIcon: false,
      onSelectionChanged: _busy
          ? null
          : (selection) => setState(() {
                _mode = selection.first;
                _result = null;
                // 换模式等于换一套流程，清掉上一张照片的复用缓存。
                _sourcePath = null;
                _crop = null;
              }),
    );
  }

  Widget _section(String title, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  /// 一行一个下拉：标题在左、当前值在右，点击展开全部选项。
  Widget _optionRow(String title, Widget control) {
    return Row(
      children: <Widget>[
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const Spacer(),
        control,
      ],
    );
  }

  Widget _specDropdown() {
    return DropdownButton<String>(
      key: const ValueKey('idphoto-spec-dropdown'),
      value: _spec.id,
      isDense: true,
      alignment: AlignmentDirectional.centerEnd,
      underline: const SizedBox.shrink(),
      borderRadius: BorderRadius.circular(12),
      items: <DropdownMenuItem<String>>[
        for (final spec in kIdPhotoSpecs)
          DropdownMenuItem<String>(
            key: ValueKey('idphoto-spec-${spec.id}'),
            value: spec.id,
            child: Text('${spec.name} · ${spec.millimeters}'),
          ),
      ],
      onChanged: _busy
          ? null
          : (id) {
              if (id == null) return;
              _selectSpec(kIdPhotoSpecs.firstWhere((e) => e.id == id));
            },
    );
  }

  Widget _backgroundDropdown(BuildContext context) {
    return DropdownButton<String>(
      key: const ValueKey('idphoto-bg-dropdown'),
      value: _background.id,
      isDense: true,
      alignment: AlignmentDirectional.centerEnd,
      underline: const SizedBox.shrink(),
      borderRadius: BorderRadius.circular(12),
      items: <DropdownMenuItem<String>>[
        for (final bg in kIdPhotoBackgrounds)
          DropdownMenuItem<String>(
            key: ValueKey('idphoto-bg-${bg.id}'),
            value: bg.id,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _colorDot(context, bg.color),
                const SizedBox(width: 8),
                Text(tr(bg.name)),
              ],
            ),
          ),
      ],
      onChanged: _busy
          ? null
          : (id) {
              if (id == null) return;
              _selectBackground(
                kIdPhotoBackgrounds.firstWhere((e) => e.id == id),
              );
            },
    );
  }

  Widget _colorDot(BuildContext context, int color) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: Color(color),
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    );
  }

  /// 边缘蒙版收缩：滑动时预览数值，松手才重新出图，避免拖动过程中反复推理。
  Widget _edgeShrinkControl(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (_edgeShrink * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Slider(
                key: const ValueKey('idphoto-edge-slider'),
                value: _edgeShrink,
                divisions: 20,
                label: '$percent%',
                onChanged:
                    _busy ? null : (v) => _changeEdgeShrink(v, commit: false),
                onChangeEnd:
                    _busy ? null : (v) => _changeEdgeShrink(v, commit: true),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '$percent%',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        SmallHint(
          text: tr('越大收得越紧，可去掉原底色残留的描边；过大可能损失发丝细节'),
        ),
      ],
    );
  }

  /// 体积档位的展示文字（≤20 KB / 不限大小）。
  String _sizeLabel(int kb) => kb <= 0 ? tr('不限大小') : trf('≤{n} KB', {'n': kb});

  Widget _sizeDropdown() {
    return DropdownButton<int>(
      key: const ValueKey('idphoto-size-dropdown'),
      value: _maxKb,
      isDense: true,
      alignment: AlignmentDirectional.centerEnd,
      underline: const SizedBox.shrink(),
      borderRadius: BorderRadius.circular(12),
      items: <DropdownMenuItem<int>>[
        for (final kb in kIdPhotoSizeLimits)
          DropdownMenuItem<int>(
            key: ValueKey('idphoto-size-$kb'),
            value: kb,
            child: Text(_sizeLabel(kb)),
          ),
      ],
      onChanged: _busy ? null : (kb) => _selectMaxKb(kb ?? _maxKb),
    );
  }

  Widget _resultCard(BuildContext context, IdPhotoResult result) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.file(
                    File(result.path),
                    key: const ValueKey('idphoto-preview'),
                    width: 96,
                    height: 96 *
                        result.height /
                        (result.width == 0 ? 1 : result.width),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 96,
                      height: 132,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.image_outlined, size: 28),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '${_spec.name} · ${result.width}×${result.height}',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        trf('实际体积 {n} KB', {
                          'n': result.kilobytes.toStringAsFixed(1),
                        }),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (_maxKb > 0)
                        Text(
                          _sizeLabel(_maxKb),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('idphoto-save-gallery'),
                    onPressed: _saveToGallery,
                    icon:
                        const Icon(Icons.photo_camera_back_outlined, size: 18),
                    label: Text(tr('保存到相册')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('idphoto-save-storage'),
                    onPressed: _saveToStorage,
                    icon: const Icon(Icons.folder_outlined, size: 18),
                    label: Text(tr('保存到存储空间')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextButton(
                    key: const ValueKey('idphoto-recrop'),
                    onPressed: _busy ? null : _recrop,
                    child: Text(tr('重新裁切')),
                  ),
                  TextButton(
                    key: const ValueKey('idphoto-again'),
                    onPressed: _busy ? null : _pick,
                    child: Text(tr('重新处理')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
