import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/platform/id_photo.dart';
import 'package:toolbox/features/tools/idphoto/id_photo_spec.dart';

FaceInfo face({
  int count = 1,
  double eulerX = 0,
  double eulerY = 0,
  double eulerZ = 0,
  double left = 900,
  double top = 500,
  double right = 1300,
  double bottom = 1000,
  int width = 3000,
  int height = 4000,
}) =>
    FaceInfo(
      count: count,
      eulerX: eulerX,
      eulerY: eulerY,
      eulerZ: eulerZ,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      imageWidth: width,
      imageHeight: height,
    );

void main() {
  group('证件照规格', () {
    test('角标与体积标签', () {
      expect(sizeLimitLabel(0), '不限大小');
      expect(sizeLimitLabel(40), '≤40 KB');
      expect(kIdPhotoSpecs.map((e) => e.id).toSet(),
          hasLength(kIdPhotoSpecs.length));
      for (final spec in kIdPhotoSpecs) {
        expect(spec.ratio, closeTo(spec.widthPx / spec.heightPx, 1e-9));
        // 证件照是竖版。
        expect(spec.heightPx, greaterThan(spec.widthPx));
      }
    });

    test('默认文件名带时间戳', () {
      final name = idPhotoFileName(DateTime(2026, 11, 14, 9, 5, 3));
      expect(name, '证件照_20261114_090503.jpg');
    });
  });

  group('人脸校验', () {
    test('无人脸', () {
      expect(judgeFace(face(count: 0)), FaceIssue.noFace);
    });

    test('多人脸', () {
      expect(judgeFace(face(count: 2)), FaceIssue.multiple);
    });

    test('一大一小的误检不算多人脸', () {
      const info = FaceInfo(
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
          FaceBox(10, 10, 60, 60),
        ],
      );
      expect(info.dominantFaceCount, 1);
      expect(judgeFace(info), FaceIssue.none);
    });

    test('同一张脸被重复检出（高 IoU）不算多人脸', () {
      const info = FaceInfo(
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
          FaceBox(810, 410, 1210, 910),
        ],
      );
      expect(info.dominantFaceCount, 1);
      expect(judgeFace(info), FaceIssue.none);
    });

    test('两张大小相当且分开的脸才是多人脸', () {
      const info = FaceInfo(
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
      );
      expect(info.dominantFaceCount, 2);
      expect(judgeFace(info), FaceIssue.multiple);
    });

    test('角度超阈值', () {
      expect(judgeFace(face(eulerY: 20)), FaceIssue.tilted);
      expect(judgeFace(face(eulerZ: -15)), FaceIssue.tilted);
      expect(judgeFace(face(eulerX: 18)), FaceIssue.tilted);
    });

    test('阈值内视为合格', () {
      expect(
          judgeFace(face(eulerY: 8, eulerZ: -6, eulerX: 10)), FaceIssue.none);
    });
  });

  group('裁切框推算', () {
    test('按脸宽居中、比例与目标一致', () {
      final crop = suggestCrop(face(), 295 / 413, 3000, 4000);
      expect(crop.width / crop.height, closeTo(295 / 413, 1e-6));
      // 人脸中心 x = 1100，裁切框水平居中于人脸。
      expect(crop.center.dx, closeTo(1100, 1));
      // 头顶留白：画框顶边在人脸上方。
      expect(crop.top, lessThan(500));
      expect(crop.height, closeTo(500 * 1.55, 1));
    });

    test('贴边时收进图片内', () {
      final corner = suggestCrop(
        face(left: 0, top: 0, right: 300, bottom: 400),
        295 / 413,
        3000,
        4000,
      );
      expect(corner.left, greaterThanOrEqualTo(0));
      expect(corner.top, greaterThanOrEqualTo(0));
      expect(corner.right, lessThanOrEqualTo(3000));
      expect(corner.bottom, lessThanOrEqualTo(4000));
    });

    test('无人脸或尺寸异常返回 Rect.zero', () {
      expect(suggestCrop(face(count: 0), 0.7, 3000, 4000), Rect.zero);
      expect(suggestCrop(face(), 0, 3000, 4000), Rect.zero);
      expect(suggestCrop(face(), 0.7, 0, 4000), Rect.zero);
    });

    test('clampCrop 只挪位置不改尺寸', () {
      const crop = Rect.fromLTWH(-50, -20, 200, 280);
      final clamped = clampCrop(crop, 1000, 1200);
      expect(clamped.size, crop.size);
      expect(clamped.left, 0);
      expect(clamped.top, 0);
    });
  });
}
