import 'package:flutter_test/flutter_test.dart';
import 'package:tunai_db/src/utils/order_by_generator.dart';

void main() {
  group('OrderByGenerator Tests', () {
    test('should return empty string when orderBy is null', () {
      final generator = OrderByGenerator();
      final result = generator.generate();
      expect(result, equals(''));
    });

    test('should return empty string when orderBy is empty', () {
      final generator = OrderByGenerator(orderBy: '');
      final result = generator.generate();
      expect(result, equals(''));
    });

    test('should generate ORDER BY clause with simple field', () {
      final generator = OrderByGenerator(orderBy: 'name');
      final result = generator.generate();
      expect(result, equals(' ORDER BY name'));
    });

    test('should generate ORDER BY clause with field and direction', () {
      final generator = OrderByGenerator(orderBy: 'created_at DESC');
      final result = generator.generate();
      expect(result, equals(' ORDER BY created_at DESC'));
    });

    test('should generate ORDER BY clause with multiple fields', () {
      final generator = OrderByGenerator(orderBy: 'category ASC, price DESC');
      final result = generator.generate();
      expect(result, equals(' ORDER BY category ASC, price DESC'));
    });

    test('should generate ORDER BY clause with table prefix', () {
      final generator = OrderByGenerator(orderBy: 'users.name ASC');
      final result = generator.generate();
      expect(result, equals(' ORDER BY users.name ASC'));
    });
  });
}
