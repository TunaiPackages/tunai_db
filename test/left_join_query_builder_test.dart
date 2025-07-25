import 'package:flutter_test/flutter_test.dart';
import 'package:tunai_db/src/model/db_field.dart';
import 'package:tunai_db/src/model/db_field_type.dart';
import 'package:tunai_db/src/model/db_filter.dart';
import 'package:tunai_db/src/model/db_left_join.dart';
import 'package:tunai_db/src/model/db_table.dart';
import 'package:tunai_db/src/utils/left_join_query_builder.dart';

void main() {
  group('LeftJoinQueryBuilder Tests', () {
    late DBTable usersTable;
    late DBTable ordersTable;
    late DBTable productsTable;

    setUp(() {
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
          DBField(fieldName: 'product_id', fieldType: DBFieldType.integer),
          DBField(fieldName: 'quantity', fieldType: DBFieldType.integer),
          DBField(fieldName: 'status', fieldType: DBFieldType.text),
        ],
      );

      productsTable = DBTable(
        tableName: 'products',
        fields: [
          DBField(
              fieldName: 'id',
              fieldType: DBFieldType.integer,
              isPrimaryKey: true),
          DBField(fieldName: 'name', fieldType: DBFieldType.text),
          DBField(fieldName: 'price', fieldType: DBFieldType.real),
        ],
      );
    });

    test('should build complete query with no filters', () {
      final leftJoin = DBLeftJoin(
        joinedTable: usersTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'user_id',
        mainTablePrimaryKey: 'id',
      );

      final builder = LeftJoinQueryBuilder();
      final result = builder.buildLeftJoinQuery(
        mainTable: ordersTable,
        leftJoins: [leftJoin],
      );

      expect(result, contains('SELECT '));
      expect(result, contains('FROM orders'));
      expect(result, contains('LEFT JOIN users'));
      expect(result, contains('ON users.user_id = orders.id'));
      expect(result, isNot(contains('WHERE')));
    });

    test('should build query with filters', () {
      final leftJoin = DBLeftJoin(
        joinedTable: usersTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'user_id',
        mainTablePrimaryKey: 'id',
      );

      final builder = LeftJoinQueryBuilder();
      final result = builder.buildLeftJoinQuery(
        mainTable: ordersTable,
        leftJoins: [leftJoin],
        filters: [
          DBFilter(fieldName: 'status', matched: 'active'),
          DBFilter(
              fieldName: 'quantity',
              matched: 5,
              filterType: DBFilterType.greaterThan),
        ],
      );

      expect(result, contains('WHERE'));
      expect(result, contains("status = 'active'"));
      expect(result, contains('quantity > 5'));
    });

    test('should build query with order by', () {
      final leftJoin = DBLeftJoin(
        joinedTable: usersTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'user_id',
        mainTablePrimaryKey: 'id',
      );

      final builder = LeftJoinQueryBuilder();
      final result = builder.buildLeftJoinQuery(
        mainTable: ordersTable,
        leftJoins: [leftJoin],
        orderBy: 'orders.id DESC',
      );

      expect(result, contains('ORDER BY orders.id DESC'));
    });

    test('should build query with limit and offset', () {
      final leftJoin = DBLeftJoin(
        joinedTable: usersTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'user_id',
        mainTablePrimaryKey: 'id',
      );

      final builder = LeftJoinQueryBuilder();
      final result = builder.buildLeftJoinQuery(
        mainTable: ordersTable,
        leftJoins: [leftJoin],
        limit: 10,
        offset: 20,
      );

      expect(result, contains('LIMIT 10'));
      expect(result, contains('OFFSET 20'));
    });

    test('should build complex query with all parameters', () {
      final userJoin = DBLeftJoin(
        joinedTable: usersTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'user_id',
        mainTablePrimaryKey: 'id',
        joinedTableAlias: 'u',
      );

      final productJoin = DBLeftJoin(
        joinedTable: productsTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'product_id',
        mainTablePrimaryKey: 'id',
        joinedTableAlias: 'p',
      );

      final builder = LeftJoinQueryBuilder();
      final result = builder.buildLeftJoinQuery(
        mainTable: ordersTable,
        leftJoins: [userJoin, productJoin],
        filters: [DBFilter(fieldName: 'status', matched: 'active')],
        orderBy: 'orders.id DESC',
        limit: 10,
        offset: 20,
      );

      expect(result, contains('SELECT '));
      expect(result, contains('FROM orders'));
      expect(result, contains('LEFT JOIN users AS u'));
      expect(result, contains('LEFT JOIN products AS p'));
      expect(result, contains('ON u.user_id = orders.id'));
      expect(result, contains('ON p.product_id = orders.id'));
      expect(result, contains("WHERE status = 'active'"));
      expect(result, contains('ORDER BY orders.id DESC'));
      expect(result, contains('LIMIT 10'));
      expect(result, contains('OFFSET 20'));
    });
  });
}
