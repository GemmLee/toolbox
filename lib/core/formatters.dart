/// 金额/比例格式化工具，全局统一展示口径。
String _withThousands(String intPart) {
  final negative = intPart.startsWith('-');
  final digits = negative ? intPart.substring(1) : intPart;
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return negative ? '-$buffer' : buffer.toString();
}

/// 金额：默认保留两位小数并加千分位，例如 `12,345.67`。
String formatMoney(double value, {int digits = 2, bool symbol = false}) {
  final fixed = value.abs().toStringAsFixed(digits);
  final parts = fixed.split('.');
  final body = digits > 0
      ? '${_withThousands(parts[0])}.${parts[1]}'
      : _withThousands(parts[0]);
  final sign = value < -0.0000001 ? '-' : '';
  return symbol ? '$sign¥$body' : '$sign$body';
}

/// 比例：去掉无意义的尾随 0，例如 `8`、`0.5`、`9.5`。
String formatRate(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// 通用数字转文本：整数不带小数点，其余按 [digits] 去尾零。
///
/// 输入框回填、结果展示共用这一份，避免各页面各写一遍。
String formatNumber(num value, {int digits = 2}) =>
    value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : formatRate(value.toDouble());

/// 输入框回填：null → 空串，其余同 [formatNumber]。
String textOf(num? value) => value == null ? '' : formatNumber(value);

/// 字节数格式化：≥1GB 显示 GB（默认两位），否则显示 MB。
String formatBytes(int bytes, {int digits = 2}) {
  final gb = bytes / 1073741824;
  if (gb >= 1 || bytes == 0) return '${formatMoney(gb, digits: digits)} GB';
  return '${formatMoney(bytes / 1048576, digits: 0)} MB';
}

/// 占用空间展示：从 KB 起，按 1024 进位（KB → MB → GB → TB）。
///
/// 工具详情里显示用户数据占用时用它；与 [formatBytes]（设备存储/下载速度，
/// 同样 1024 但从 MB 起、且 ≥1GB 才显示 GB）刻意分开，避免改全局口径。
String formatStorageSize(int bytes) {
  const units = <String>['KB', 'MB', 'GB', 'TB'];
  const step = 1024;
  var value = bytes / step;
  var unit = 0;
  while (value >= step && unit < units.length - 1) {
    value /= step;
    unit++;
  }
  final digits = value >= 100
      ? 0
      : value >= 10
          ? 1
          : 2;
  return '${formatMoney(value, digits: digits)} ${units[unit]}';
}

/// 单文件大小的紧凑写法（B / KB / MB），存储空间列表用。
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}
