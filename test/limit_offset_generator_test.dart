import 'package:flutter_test/flutter_test.dart';
import 'package:tunai_db/src/utils/limit_offset_generator.dart';

void main() {
  group('LimitOffsetGenerator Tests', () {
    test('should return empty string when limit and offset are null', () {
      final generator = LimitOffsetGenerator();
      final result = generator.generate();
      expect(result, equals(''));
    });

    test('should generate LIMIT clause only', () {
      final generator = LimitOffsetGenerator(limit: 10);
      final result = generator.generate();
      expect(result, equals(' LIMIT 10'));
    });

    test('should generate OFFSET clause only', () {
      final generator = LimitOffsetGenerator(offset: 20);
      final result = generator.generate();
      expect(result, equals(' OFFSET 20'));
    });

    test('should generate both LIMIT and OFFSET clauses', () {
      final generator = LimitOffsetGenerator(limit: 10, offset: 20);
      final result = generator.generate();
      expect(result, equals(' LIMIT 10 OFFSET 20'));
    });

    test('should generate LIMIT and OFFSET with zero values', () {
      final generator = LimitOffsetGenerator(limit: 0, offset: 0);
      final result = generator.generate();
      expect(result, equals(' LIMIT 0 OFFSET 0'));
    });

    test('should generate LIMIT and OFFSET with large values', () {
      final generator = LimitOffsetGenerator(limit: 1000, offset: 5000);
      final result = generator.generate();
      expect(result, equals(' LIMIT 1000 OFFSET 5000'));
    });
  });
}
