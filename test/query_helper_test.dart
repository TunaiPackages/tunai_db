import 'package:flutter_test/flutter_test.dart';
import 'package:tunai_db/src/model/db_field.dart';
import 'package:tunai_db/src/model/db_field_type.dart';
import 'package:tunai_db/src/model/db_filter.dart';
import 'package:tunai_db/src/model/db_left_join.dart';
import 'package:tunai_db/src/model/db_table.dart';
import 'package:tunai_db/src/utils/query_helper.dart';

void main() {
  group('QueryHelper Integration Tests', () {
    late QueryHelper queryHelper;
    late DBTable usersTable;
    late DBTable ordersTable;

    setUp(() {
      queryHelper = QueryHelper();

      // Create test tables
      usersTable = DBTable(
        tableName: 'users',
        fields: [
          DBField(
              fieldName: 'id',
              fieldType: DBFieldType.integer,
              isPrimaryKey: true),
          DBField(fieldName: 'name', fieldType: DBFieldType.text),
          DBField(fieldName: 'email', fieldType: DBFieldType.text),
        ],
      );

      ordersTable = DBTable(
        tableName: 'orders',
        fields: [
          DBField(
              fieldName: 'id',
              fieldType: DBFieldType.integer,
              isPrimaryKey: true),
          DBField(fieldName: 'user_id', fieldType: DBFieldType.integer),
          DBField(fieldName: 'quantity', fieldType: DBFieldType.integer),
          DBField(fieldName: 'status', fieldType: DBFieldType.text),
        ],
      );
    });

    test('should build complete left join query using QueryHelper', () {
      final leftJoin = DBLeftJoin(
        joinedTable: usersTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'user_id',
        mainTablePrimaryKey: 'id',
      );

      final result = queryHelper.buildLeftJoinQuery(
        mainTable: ordersTable,
        leftJoins: [leftJoin],
        filters: [DBFilter(fieldName: 'status', matched: 'active')],
        orderBy: 'orders.id DESC',
        limit: 10,
        offset: 20,
      );

      expect(result, contains('SELECT '));
      expect(result, contains('FROM orders'));
      expect(result, contains('LEFT JOIN users'));
      expect(result, contains('ON users.user_id = orders.id'));
      expect(result, contains("WHERE status = 'active'"));
      expect(result, contains('ORDER BY orders.id DESC'));
      expect(result, contains('LIMIT 10'));
      expect(result, contains('OFFSET 20'));
    });

    test('should generate where clause using QueryHelper', () {
      final filters = [
        DBFilter(fieldName: 'status', matched: 'active'),
        DBFilter(
            fieldName: 'quantity',
            matched: 5,
            filterType: DBFilterType.greaterThan),
      ];

      final result = queryHelper.getWhereQuery(filters: filters);

      expect(result, contains("status = 'active'"));
      expect(result, contains('quantity > 5'));
    });
  });
}
