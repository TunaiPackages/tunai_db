import 'package:flutter_test/flutter_test.dart';
import 'package:tunai_db/src/model/db_field.dart';
import 'package:tunai_db/src/model/db_field_type.dart';
import 'package:tunai_db/src/model/db_left_join.dart';
import 'package:tunai_db/src/model/db_table.dart';
import 'package:tunai_db/src/utils/left_join_clause_generator.dart';

void main() {
  group('LeftJoinClauseGenerator Tests', () {
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

    test('should generate LEFT JOIN clause for single join', () {
      final leftJoin = DBLeftJoin(
        joinedTable: usersTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'user_id',
        mainTablePrimaryKey: 'id',
      );

      final generator = LeftJoinClauseGenerator(
        mainTableName: 'orders',
        leftJoins: [leftJoin],
      );

      final result = generator.generate();

      expect(result, contains('LEFT JOIN users'));
      expect(result, contains('ON users.user_id = orders.id'));
    });

    test('should generate LEFT JOIN clauses for multiple joins', () {
      final userJoin = DBLeftJoin(
        joinedTable: usersTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'user_id',
        mainTablePrimaryKey: 'id',
      );

      final productJoin = DBLeftJoin(
        joinedTable: productsTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'product_id',
        mainTablePrimaryKey: 'id',
      );

      final generator = LeftJoinClauseGenerator(
        mainTableName: 'orders',
        leftJoins: [userJoin, productJoin],
      );

      final result = generator.generate();

      expect(result, contains('LEFT JOIN users'));
      expect(result, contains('ON users.user_id = orders.id'));
      expect(result, contains('LEFT JOIN products'));
      expect(result, contains('ON products.product_id = orders.id'));
    });

    test('should handle LEFT JOIN with table alias', () {
      final leftJoin = DBLeftJoin(
        joinedTable: usersTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'user_id',
        mainTablePrimaryKey: 'id',
        joinedTableAlias: 'u',
      );

      final generator = LeftJoinClauseGenerator(
        mainTableName: 'orders',
        leftJoins: [leftJoin],
      );

      final result = generator.generate();

      expect(result, contains('LEFT JOIN users AS u'));
      expect(result, contains('ON u.user_id = orders.id'));
    });

    test('should return empty string when no left joins provided', () {
      final generator = LeftJoinClauseGenerator(
        mainTableName: 'orders',
        leftJoins: [],
      );

      final result = generator.generate();

      expect(result, equals(''));
    });
  });
}
