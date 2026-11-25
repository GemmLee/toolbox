import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox/core/formatters.dart';

void main() {
  group('formatStorageSize 占用空间口径', () {
    test('从 KB 起，不满 1024KB 不进位', () {
      expect(formatStorageSize(0), '0.00 KB');
      expect(formatStorageSize(512), '0.50 KB');
      expect(formatStorageSize(1024), '1.00 KB');
      expect(formatStorageSize(1024 * 1024 - 1), '1,024 KB');
    });

    test('满 1024KB 才到 MB，逐级进位', () {
      expect(formatStorageSize(1024 * 1024), '1.00 MB');
      expect(formatStorageSize(12345678), '11.8 MB');
      expect(formatStorageSize(1024 * 1024 * 1024), '1.00 GB');
      expect(formatStorageSize(1024 * 1024 * 1024 * 1024), '1.00 TB');
    });

    test('小数位随量级收敛，避免长尾', () {
      expect(formatStorageSize(12 * 1024 * 1024 + 300 * 1024), '12.3 MB');
      expect(formatStorageSize(123 * 1024 * 1024), '123 MB');
    });
  });
}
