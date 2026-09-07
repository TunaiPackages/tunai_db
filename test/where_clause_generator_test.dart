import 'package:flutter_test/flutter_test.dart';
import 'package:tunai_db/src/model/db_filter.dart';
import 'package:tunai_db/src/model/db_filter_join_type.dart';
import 'package:tunai_db/src/model/grouped_db_filter.dart';
import 'package:tunai_db/src/utils/where_clause_generator.dart';

void main() {
  group('WhereClauseGenerator Tests', () {
    test('should return empty string when no filters provided', () {
      final generator = WhereClauseGenerator();
      final result = generator.generate();
      expect(result, equals(''));
    });

    test('should return empty string when empty filters and grouped filters',
        () {
      final generator = WhereClauseGenerator(
        filters: [],
        groupedFilters: [],
      );
      final result = generator.generate();
      expect(result, equals(''));
    });

    test('should handle single DBFilter with default AND join type', () {
      final filters = [
        const DBFilter(
          fieldName: 'name',
          matched: 'John',
          filterType: DBFilterType.equal,
        ),
      ];

      final generator = WhereClauseGenerator(filters: filters);
      final result = generator.generate();
      expect(result, equals("name = 'John'"));
    });

    test('should handle single DBFilterIn with default AND join type', () {
      final filters = [
        const DBFilterIn(
          fieldName: 'status',
          matched: ['active', 'pending'],
        ),
      ];

      final generator = WhereClauseGenerator(filters: filters);
      final result = generator.generate();
      expect(result, equals("status IN ('active', 'pending')"));
    });

    test('should handle multiple DBFilters with AND join type', () {
      final filters = [
        const DBFilter(
          fieldName: 'age',
          matched: 25,
          filterType: DBFilterType.greaterThan,
        ),
        const DBFilter(
          fieldName: 'status',
          matched: 'active',
          filterType: DBFilterType.equal,
        ),
      ];

      final generator = WhereClauseGenerator(
        filters: filters,
        filterJoinType: DBFilterJoinType.and,
      );
      final result = generator.generate();
      expect(result, equals("age > 25 AND status = 'active'"));
    });

    test('should handle multiple DBFilters with OR join type', () {
      final filters = [
        const DBFilter(
          fieldName: 'category',
          matched: 'electronics',
          filterType: DBFilterType.equal,
        ),
        const DBFilter(
          fieldName: 'category',
          matched: 'books',
          filterType: DBFilterType.equal,
        ),
      ];

      final generator = WhereClauseGenerator(
        filters: filters,
        filterJoinType: DBFilterJoinType.or,
      );
      final result = generator.generate();
      expect(result, equals("category = 'electronics' OR category = 'books'"));
    });

    test('should handle single GroupedDBFilter with AND join type', () {
      final groupedFilters = [
        const GroupedDBFilter(
          filterJoinType: DBFilterJoinType.or,
          filters: [
            DBFilter(
              fieldName: 'status',
              matched: 'active',
              filterType: DBFilterType.equal,
            ),
            DBFilter(
              fieldName: 'status',
              matched: 'pending',
              filterType: DBFilterType.equal,
            ),
          ],
        ),
      ];

      final generator = WhereClauseGenerator(
        groupedFilters: groupedFilters,
        filterJoinType: DBFilterJoinType.and,
      );
      final result = generator.generate();
      expect(result, equals("(status = 'active' OR status = 'pending')"));
    });

    test(
        'should handle filters and grouped filters together with AND join type',
        () {
      final filters = [
        const DBFilter(
          fieldName: 'active',
          matched: true,
          filterType: DBFilterType.equal,
        ),
      ];

      final groupedFilters = [
        const GroupedDBFilter(
          filterJoinType: DBFilterJoinType.or,
          filters: [
            DBFilter(
              fieldName: 'status',
              matched: 'active',
              filterType: DBFilterType.equal,
            ),
            DBFilter(
              fieldName: 'status',
              matched: 'pending',
              filterType: DBFilterType.equal,
            ),
          ],
        ),
      ];

      final generator = WhereClauseGenerator(
        filters: filters,
        groupedFilters: groupedFilters,
        filterJoinType: DBFilterJoinType.and,
      );
      final result = generator.generate();
      expect(
          result,
          equals(
              "active = true AND (status = 'active' OR status = 'pending')"));
    });

    test('should generate with WHERE keyword when filters are provided', () {
      final filters = [
        const DBFilter(
          fieldName: 'status',
          matched: 'active',
          filterType: DBFilterType.equal,
        ),
      ];

      final generator = WhereClauseGenerator(filters: filters);
      final result = generator.generateWithWhereKeyword();
      expect(result, equals(" WHERE status = 'active'"));
    });

    test('should return empty string with WHERE keyword when no filters', () {
      final generator = WhereClauseGenerator();
      final result = generator.generateWithWhereKeyword();
      expect(result, equals(''));
    });
  });
}
