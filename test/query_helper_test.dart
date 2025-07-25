import 'package:flutter_test/flutter_test.dart';
import 'package:tunai_db/src/model/db_filter.dart';
import 'package:tunai_db/src/model/db_filter_join_type.dart';
import 'package:tunai_db/src/model/grouped_db_filter.dart';
import 'package:tunai_db/src/utils/query_helper.dart';

void main() {
  group('QueryHelper', () {
    late QueryHelper queryHelper;

    setUp(() {
      queryHelper = QueryHelper();
    });

    group('getWhereQuery', () {
      test('should return empty string when no filters provided', () {
        final result = queryHelper.getWhereQuery();
        expect(result, equals(''));
      });

      test('should return empty string when empty filters and grouped filters',
          () {
        final result = queryHelper.getWhereQuery(
          filters: [],
          groupedFilters: [],
        );
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

        final result = queryHelper.getWhereQuery(filters: filters);
        expect(result, equals("name = 'John'"));
      });

      test('should handle single DBFilterIn with default AND join type', () {
        final filters = [
          const DBFilterIn(
            fieldName: 'status',
            matched: ['active', 'pending'],
          ),
        ];

        final result = queryHelper.getWhereQuery(filters: filters);
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

        final result = queryHelper.getWhereQuery(
          filters: filters,
          filterJoinType: DBFilterJoinType.and,
        );
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

        final result = queryHelper.getWhereQuery(
          filters: filters,
          filterJoinType: DBFilterJoinType.or,
        );
        expect(
            result, equals("category = 'electronics' OR category = 'books'"));
      });

      test('should handle mixed DBFilter and DBFilterIn with AND join type',
          () {
        final filters = [
          const DBFilter(
            fieldName: 'price',
            matched: 100,
            filterType: DBFilterType.lessThan,
          ),
          const DBFilterIn(
            fieldName: 'category',
            matched: ['electronics', 'clothing'],
          ),
        ];

        final result = queryHelper.getWhereQuery(
          filters: filters,
          filterJoinType: DBFilterJoinType.and,
        );
        expect(result,
            equals("price < 100 AND category IN ('electronics', 'clothing')"));
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

        final result = queryHelper.getWhereQuery(
          groupedFilters: groupedFilters,
          filterJoinType: DBFilterJoinType.and,
        );
        expect(result, equals("(status = 'active' OR status = 'pending')"));
      });

      test('should handle multiple GroupedDBFilters with AND join type', () {
        final groupedFilters = [
          const GroupedDBFilter(
            filterJoinType: DBFilterJoinType.or,
            filters: [
              DBFilter(
                fieldName: 'category',
                matched: 'electronics',
                filterType: DBFilterType.equal,
              ),
              DBFilter(
                fieldName: 'category',
                matched: 'books',
                filterType: DBFilterType.equal,
              ),
            ],
          ),
          const GroupedDBFilter(
            filterJoinType: DBFilterJoinType.and,
            filters: [
              DBFilter(
                fieldName: 'price',
                matched: 50,
                filterType: DBFilterType.greaterThan,
              ),
              DBFilter(
                fieldName: 'price',
                matched: 200,
                filterType: DBFilterType.lessThan,
              ),
            ],
          ),
        ];

        final result = queryHelper.getWhereQuery(
          groupedFilters: groupedFilters,
          filterJoinType: DBFilterJoinType.and,
        );
        expect(
            result,
            equals(
                "(category = 'electronics' OR category = 'books') AND (price > 50 AND price < 200)"));
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

        final result = queryHelper.getWhereQuery(
          filters: filters,
          groupedFilters: groupedFilters,
          filterJoinType: DBFilterJoinType.and,
        );
        expect(
            result,
            equals(
                "active = true AND (status = 'active' OR status = 'pending')"));
      });

      test(
          'should handle filters and grouped filters together with OR join type',
          () {
        final filters = [
          const DBFilter(
            fieldName: 'featured',
            matched: true,
            filterType: DBFilterType.equal,
          ),
        ];

        final groupedFilters = [
          const GroupedDBFilter(
            filterJoinType: DBFilterJoinType.and,
            filters: [
              DBFilter(
                fieldName: 'price',
                matched: 100,
                filterType: DBFilterType.greaterThan,
              ),
              DBFilter(
                fieldName: 'rating',
                matched: 4,
                filterType: DBFilterType.greaterThanOrEqual,
              ),
            ],
          ),
        ];

        final result = queryHelper.getWhereQuery(
          filters: filters,
          groupedFilters: groupedFilters,
          filterJoinType: DBFilterJoinType.or,
        );
        expect(
            result, equals("featured = true OR (price > 100 AND rating >= 4)"));
      });

      test(
          'should handle complex scenario with multiple filters and grouped filters',
          () {
        final filters = [
          const DBFilter(
            fieldName: 'store_id',
            matched: 123,
            filterType: DBFilterType.equal,
          ),
          const DBFilterIn(
            fieldName: 'category',
            matched: ['electronics', 'clothing', 'books'],
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
          const GroupedDBFilter(
            filterJoinType: DBFilterJoinType.and,
            filters: [
              DBFilter(
                fieldName: 'price',
                matched: 10,
                filterType: DBFilterType.greaterThan,
              ),
              DBFilter(
                fieldName: 'price',
                matched: 500,
                filterType: DBFilterType.lessThan,
              ),
            ],
          ),
        ];

        final result = queryHelper.getWhereQuery(
          filters: filters,
          groupedFilters: groupedFilters,
          filterJoinType: DBFilterJoinType.and,
        );
        expect(
            result,
            equals(
                "store_id = 123 AND category IN ('electronics', 'clothing', 'books') AND (status = 'active' OR status = 'pending') AND (price > 10 AND price < 500)"));
      });

      test('should handle numeric values correctly', () {
        final filters = [
          const DBFilter(
            fieldName: 'quantity',
            matched: 0,
            filterType: DBFilterType.greaterThan,
          ),
          const DBFilter(
            fieldName: 'price',
            matched: 99.99,
            filterType: DBFilterType.lessThanOrEqual,
          ),
        ];

        final result = queryHelper.getWhereQuery(filters: filters);
        expect(result, equals("quantity > 0 AND price <= 99.99"));
      });

      test('should handle boolean values correctly', () {
        final filters = [
          const DBFilter(
            fieldName: 'is_active',
            matched: true,
            filterType: DBFilterType.equal,
          ),
          const DBFilter(
            fieldName: 'is_deleted',
            matched: false,
            filterType: DBFilterType.equal,
          ),
        ];

        final result = queryHelper.getWhereQuery(filters: filters);
        expect(result, equals("is_active = true AND is_deleted = false"));
      });

      test('should handle LIKE operator correctly', () {
        final filters = [
          const DBFilter(
            fieldName: 'name',
            matched: '%john%',
            filterType: DBFilterType.like,
          ),
        ];

        final result = queryHelper.getWhereQuery(filters: filters);
        expect(result, equals("name LIKE '%john%'"));
      });

      test('should handle not equal operator correctly', () {
        final filters = [
          const DBFilter(
            fieldName: 'status',
            matched: 'deleted',
            filterType: DBFilterType.notEqual,
          ),
        ];

        final result = queryHelper.getWhereQuery(filters: filters);
        expect(result, equals("status <> 'deleted'"));
      });
    });
  });
}
