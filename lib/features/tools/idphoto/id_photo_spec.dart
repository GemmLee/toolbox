/// 证件照规格 / 底色 / 体积档位：全部是纯常量与纯函数，便于单测。
library;

/// 一种证件照尺寸。
class IdPhotoSpec {
  const IdPhotoSpec({
    required this.id,
    required this.name,
    required this.widthPx,
    required this.heightPx,
    required this.millimeters,
    this.defaultMaxKb = 0,
  });

  final String id;
  final String name;
  final int widthPx;
  final int heightPx;

  /// 物理尺寸说明，如 `25×35mm`。
  final String millimeters;

  /// 该规格常见的报名系统体积上限，0 表示不限制。
  final int defaultMaxKb;

  double get ratio => widthPx / heightPx;
}

/// 常用证件照规格（300dpi 像素口径）。
const List<IdPhotoSpec> kIdPhotoSpecs = <IdPhotoSpec>[
  IdPhotoSpec(
    id: 'one',
    name: '一寸',
    widthPx: 295,
    heightPx: 413,
    millimeters: '25×35mm',
    defaultMaxKb: 40,
  ),
  IdPhotoSpec(
    id: 'small-one',
    name: '小一寸',
    widthPx: 260,
    heightPx: 378,
    millimeters: '22×32mm',
    defaultMaxKb: 40,
  ),
  IdPhotoSpec(
    id: 'big-one',
    name: '大一寸',
    widthPx: 390,
    heightPx: 567,
    millimeters: '33×48mm',
    defaultMaxKb: 100,
  ),
  IdPhotoSpec(
    id: 'two',
    name: '二寸',
    widthPx: 413,
    heightPx: 579,
    millimeters: '35×49mm',
    defaultMaxKb: 100,
  ),
  IdPhotoSpec(
    id: 'small-two',
    name: '小二寸',
    widthPx: 413,
    heightPx: 531,
    millimeters: '35×45mm',
    defaultMaxKb: 100,
  ),
  IdPhotoSpec(
    id: 'big-two',
    name: '大二寸',
    widthPx: 413,
    heightPx: 626,
    millimeters: '35×53mm',
    defaultMaxKb: 100,
  ),
];

/// 一种背景色。
class IdPhotoBackground {
  const IdPhotoBackground({
    required this.id,
    required this.name,
    required this.color,
  });

  final String id;
  final String name;

  /// 0xAARRGGBB。
  final int color;
}

const List<IdPhotoBackground> kIdPhotoBackgrounds = <IdPhotoBackground>[
  IdPhotoBackground(id: 'white', name: '白底', color: 0xFFFFFFFF),
  IdPhotoBackground(id: 'blue', name: '蓝底', color: 0xFF438EDB),
  IdPhotoBackground(id: 'red', name: '红底', color: 0xFFD9001B),
  IdPhotoBackground(id: 'gray', name: '浅灰', color: 0xFFF0F0F0),
];

/// 体积档位（KB，0 = 不限制）。
const List<int> kIdPhotoSizeLimits = <int>[0, 20, 40, 100];

/// 体积档位的展示文字；`0` 表示不限。
String sizeLimitLabel(int kb) => kb <= 0 ? '不限大小' : '≤$kb KB';

/// 生成默认文件名：`证件照_20261114_143501.jpg`。
String idPhotoFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '证件照_${now.year}${two(now.month)}${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}.jpg';
}
