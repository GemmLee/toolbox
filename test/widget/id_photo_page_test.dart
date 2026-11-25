import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/platform/id_photo.dart';
import 'package:toolbox/features/tools/idphoto/id_photo_page.dart';

import '../support/test_env.dart';

class _FakeEngine implements IdPhotoEngine {
  _FakeEngine({this.face, this.resultPath});

  FaceInfo? face;
  String? resultPath;
  int detectCalls = 0;
  IdPhotoRequest? lastRequest;
  IdPhotoRecolorRequest? lastRecolor;
  int recolorCalls = 0;
  bool recolorAvailable = true;
  bool galleryOk = true;

  @override
  Future<FaceInfo> detectFace(String path) async {
    detectCalls++;
    return face ??
        const FaceInfo(
          count: 1,
          eulerX: 0,
          eulerY: 0,
          eulerZ: 0,
          left: 800,
          top: 400,
          right: 1200,
          bottom: 900,
          imageWidth: 3000,
          imageHeight: 4000,
        );
  }

  @override
  Future<IdPhotoResult> process(
    IdPhotoRequest request, {
    IdPhotoProgress? onProgress,
  }) async {
    lastRequest = request;
    onProgress?.call(IdPhotoStage.matte, 0.4);
    return IdPhotoResult(
      path: resultPath ?? request.sourcePath,
      width: request.width,
      height: request.height,
      bytes: 38000,
    );
  }

  @override
  Future<IdPhotoResult?> recolor(IdPhotoRecolorRequest request) async {
    recolorCalls++;
    lastRecolor = request;
    final last = lastRequest;
    if (!recolorAvailable || last == null) return null;
    return IdPhotoResult(
      path: resultPath ?? last.sourcePath,
      width: last.width,
      height: last.height,
      bytes: 36000,
    );
  }

  @override
  Future<bool> saveToGallery(String path, String name) async => galleryOk;
}

/// 裁切页替身：点一下就带着固定裁切框返回。
Widget _cropStub(Rect rect) => Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => FilledButton(
            key: const ValueKey('fake-crop-confirm'),
            onPressed: () => Navigator.of(context).pop(rect),
            child: const Text('crop'),
          ),
        ),
      ),
    );

Widget _page(
  IdPhotoEngine engine, {
  IdPhotoStorageSaver? saver,
  IdPhotoBytesLoader? loader,
  String source = '/tmp/fake_photo.jpg',
  Rect crop = const Rect.fromLTWH(100, 100, 1000, 1400),
  Future<String?> Function(IdPhotoImageSource source)? picker,
}) {
  return MaterialApp(
    home: IdPhotoPage(
      engine: engine,
      picker: picker ?? (_) async => source,
      saver: saver ?? (bytes, name) async => name,
      // 默认读盘是真实异步 I/O，在 FakeAsync 下永远不返回，测试里一律注入。
      bytesLoader: loader ?? (_) async => const <int>[],
      cropBuilder: (path, ratio, initial) => _cropStub(crop),
    ),
  );
}

/// 懒加载列表里目标可能还没构建：先滚到能拿到，再确保可见。
/// [delta] 为负表示往上滚（找已经在上面、但已被回收的控件）。
Future<void> _reveal(WidgetTester tester, Finder finder,
    {double delta = 120}) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, delta,
        scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

/// 下拉选项：先滚到按钮、展开菜单，再点对应条目。
Future<void> _choose(
  WidgetTester tester,
  String buttonKey,
  String itemKey,
) async {
  final button = find.byKey(ValueKey(buttonKey));
  await _reveal(tester, button);
  await tester.tap(button);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(itemKey)).last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    mockPrefs();
    await useChineseUi();
  });

  tearDown(restoreSystemLanguage);

  testWidgets('照片转证件照：校验人脸 → 裁切 → 出图', (tester) async {
    final engine = _FakeEngine();
    await tester.pumpWidget(_page(engine));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('idphoto-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fake-crop-confirm')));
    await tester.pumpAndSettle();

    expect(engine.detectCalls, 1);
    // 默认一寸 295×413、白底、≤40KB。
    expect(engine.lastRequest!.width, 295);
    expect(engine.lastRequest!.height, 413);
    expect(engine.lastRequest!.background, 0xFFFFFFFF);
    expect(engine.lastRequest!.maxKb, 40);
    expect(find.textContaining('一寸'), findsWidgets);
    expect(find.textContaining('实际体积'), findsOneWidget);
  });

  testWidgets('多人脸时提示重选且不进入裁切', (tester) async {
    final engine = _FakeEngine(
      face: const FaceInfo(
        count: 2,
        eulerX: 0,
        eulerY: 0,
        eulerZ: 0,
        left: 0,
        top: 0,
        right: 100,
        bottom: 100,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
    );
    await tester.pumpWidget(_page(engine));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('idphoto-pick')));
    await tester.pumpAndSettle();

    expect(find.text('检测到多张人脸，请上传只包含本人的照片'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-crop-confirm')), findsNothing);
    expect(engine.lastRequest, isNull);
  });

  testWidgets('一大一小的误检人脸不再报「多张人脸」', (tester) async {
    final engine = _FakeEngine(
      face: const FaceInfo(
        count: 2,
        eulerX: 0,
        eulerY: 0,
        eulerZ: 0,
        left: 800,
        top: 400,
        right: 1200,
        bottom: 900,
        imageWidth: 3000,
        imageHeight: 4000,
        boxes: <FaceBox>[
          FaceBox(800, 400, 1200, 900),
          FaceBox(40, 40, 90, 95), // 背景花纹被误识别的小框
        ],
      ),
    );
    await tester.pumpWidget(_page(engine));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('idphoto-pick')));
    await tester.pumpAndSettle();
    expect(find.text('这张照片不合适'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('fake-crop-confirm')));
    await tester.pumpAndSettle();
    expect(engine.lastRequest, isNotNull);
  });

  testWidgets('确实两张人脸时可用「只用最大的人脸」继续', (tester) async {
    final engine = _FakeEngine(
      face: const FaceInfo(
        count: 2,
        eulerX: 0,
        eulerY: 0,
        eulerZ: 0,
        left: 800,
        top: 400,
        right: 1200,
        bottom: 900,
        imageWidth: 3000,
        imageHeight: 4000,
        boxes: <FaceBox>[
          FaceBox(800, 400, 1200, 900),
          FaceBox(1800, 400, 2200, 900),
        ],
      ),
    );
    await tester.pumpWidget(_page(engine));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('idphoto-pick')));
    await tester.pumpAndSettle();
    expect(find.text('只用最大的人脸'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('idphoto-face-largest')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-crop-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fake-crop-confirm')));
    await tester.pumpAndSettle();
    expect(engine.lastRequest, isNotNull);
  });

  testWidgets('出图后点底色即时重出，不重新选图也不重新裁切', (tester) async {
    final engine = _FakeEngine();
    var picks = 0;
    await tester.pumpWidget(_page(
      engine,
      picker: (_) async {
        picks++;
        return '/tmp/fake_photo.jpg';
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('idphoto-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fake-crop-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('idphoto-preview')), findsOneWidget);

    await _choose(tester, 'idphoto-bg-dropdown', 'idphoto-bg-blue');

    expect(engine.recolorCalls, 1);
    expect(engine.lastRecolor!.background, 0xFF438EDB);
    // 没有重新跑完整流程：原始请求仍是第一次的白底。
    expect(engine.lastRequest!.background, 0xFFFFFFFF);
    expect(picks, 1);
    expect(find.byKey(const ValueKey('fake-crop-confirm')), findsNothing);
  });

  testWidgets('边缘收缩滑块松手后把数值带进重出图请求', (tester) async {
    final engine = _FakeEngine();
    await tester.pumpWidget(_page(engine));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('idphoto-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fake-crop-confirm')));
    await tester.pumpAndSettle();

    final slider = find.byKey(const ValueKey('idphoto-edge-slider'));
    await _reveal(tester, slider);
    await tester.drag(slider, const Offset(160, 0));
    await tester.pumpAndSettle();

    expect(engine.lastRecolor, isNotNull);
    expect(engine.lastRecolor!.edgeShrink, greaterThan(0));
  });

  testWidgets('原生抠图缓存失效时回退完整处理，仍用原图与裁切框', (tester) async {
    final engine = _FakeEngine()..recolorAvailable = false;
    await tester.pumpWidget(_page(engine));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('idphoto-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fake-crop-confirm')));
    await tester.pumpAndSettle();

    await _choose(tester, 'idphoto-bg-dropdown', 'idphoto-bg-red');

    expect(engine.recolorCalls, 1);
    expect(engine.lastRequest!.background, 0xFFD9001B);
    expect(engine.lastRequest!.sourcePath, '/tmp/fake_photo.jpg');
    // 回退完整处理后照样有成品预览（成品在本页最上方，滚回去确认）。
    await _reveal(tester, find.byKey(const ValueKey('idphoto-preview')),
        delta: -200);
    expect(find.byKey(const ValueKey('idphoto-preview')), findsOneWidget);
  });

  testWidgets('换底改尺寸模式跳过人脸校验', (tester) async {
    final engine = _FakeEngine();
    await tester.pumpWidget(_page(engine));
    await tester.pumpAndSettle();

    await tester.tap(find.text('换底改尺寸'));
    await tester.pumpAndSettle();
    expect(find.text('选择证件照'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('idphoto-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fake-crop-confirm')));
    await tester.pumpAndSettle();

    expect(engine.detectCalls, 0);
    expect(engine.lastRequest, isNotNull);
  });

  testWidgets('切换规格会把体积档位带到该规格默认值', (tester) async {
    final engine = _FakeEngine();
    await tester.pumpWidget(_page(engine));
    await tester.pumpAndSettle();

    // 一寸默认 ≤40 KB。
    expect(find.text('≤40 KB'), findsWidgets);
    await _choose(tester, 'idphoto-spec-dropdown', 'idphoto-spec-big-one');
    expect(find.text('≤100 KB'), findsWidgets);
  });

  testWidgets('选中蓝底与小二寸后参数正确传递', (tester) async {
    final engine = _FakeEngine();
    await tester.pumpWidget(_page(engine));
    await tester.pumpAndSettle();

    await _choose(tester, 'idphoto-spec-dropdown', 'idphoto-spec-small-two');
    await _choose(tester, 'idphoto-bg-dropdown', 'idphoto-bg-blue');

    await tester.tap(find.byKey(const ValueKey('idphoto-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fake-crop-confirm')));
    await tester.pumpAndSettle();

    expect(engine.lastRequest!.width, 413);
    expect(engine.lastRequest!.height, 531);
    expect(engine.lastRequest!.background, 0xFF438EDB);
  });

  testWidgets('保存到存储空间会把成品字节交给存储层', (tester) async {
    // 临时目录必须用同步 API：testWidgets 的 FakeAsync 里真实异步永不返回。
    final dir = Directory.systemTemp.createTempSync('idphoto_widget');
    final photo = File('${dir.path}/out.jpg')..writeAsBytesSync(<int>[1, 2, 3]);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final saved = <List<int>>[];
    await tester.pumpWidget(_page(
      _FakeEngine(resultPath: photo.path),
      source: photo.path,
      loader: (_) async => <int>[1, 2, 3],
      saver: (bytes, name) async {
        saved.add(bytes);
        return name;
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('idphoto-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fake-crop-confirm')));
    await tester.pumpAndSettle();

    final saveButton = find.byKey(const ValueKey('idphoto-save-storage'));
    await _reveal(tester, saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(saved.single, <int>[1, 2, 3]);
    expect(find.textContaining('已保存到存储空间'), findsOneWidget);
  });
}
