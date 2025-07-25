import 'package:flutter_test/flutter_test.dart';
import 'package:tunai_db/src/model/db_field.dart';
import 'package:tunai_db/src/model/db_field_type.dart';
import 'package:tunai_db/src/model/db_left_join.dart';
import 'package:tunai_db/src/model/db_table.dart';
import 'package:tunai_db/src/utils/select_clause_generator.dart';

void main() {
  group('SelectClauseGenerator Tests', () {
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

    test('should generate SELECT clause with main table fields only', () {
      final generator = SelectClauseGenerator(
        mainTable: ordersTable,
        leftJoins: [],
      );

      final result = generator.generate();

      expect(result, contains('SELECT '));
      expect(result, contains('orders.id AS id'));
      expect(result, contains('orders.user_id AS user_id'));
      expect(result, contains('orders.product_id AS product_id'));
      expect(result, contains('orders.quantity AS quantity'));
      expect(result, contains('orders.status AS status'));
    });

    test('should generate SELECT clause with one left join', () {
      final leftJoin = DBLeftJoin(
        joinedTable: usersTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'user_id',
        mainTablePrimaryKey: 'id',
      );

      final generator = SelectClauseGenerator(
        mainTable: ordersTable,
        leftJoins: [leftJoin],
      );

      final result = generator.generate();

      expect(result, contains('orders.id AS id'));
      expect(result, contains('orders.user_id AS user_id'));
      expect(result, contains('users.id AS users_id'));
      expect(result, contains('users.name AS users_name'));
      expect(result, contains('users.email AS users_email'));
    });

    test('should generate SELECT clause with multiple left joins', () {
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

      final generator = SelectClauseGenerator(
        mainTable: ordersTable,
        leftJoins: [userJoin, productJoin],
      );

      final result = generator.generate();

      expect(result, contains('orders.id AS id'));
      expect(result, contains('users.id AS users_id'));
      expect(result, contains('users.name AS users_name'));
      expect(result, contains('products.id AS products_id'));
      expect(result, contains('products.name AS products_name'));
      expect(result, contains('products.price AS products_price'));
    });

    test('should handle left join with outputKey alias', () {
      final leftJoin = DBLeftJoin(
        joinedTable: usersTable,
        mainTableName: 'orders',
        joinedTableForeignKey: 'user_id',
        mainTablePrimaryKey: 'id',
        joinedTableAlias: 'u',
      );

      final generator = SelectClauseGenerator(
        mainTable: ordersTable,
        leftJoins: [leftJoin],
      );

      final result = generator.generate();

      expect(result, contains('u.id AS u_id'));
      expect(result, contains('u.name AS u_name'));
      expect(result, contains('u.email AS u_email'));
    });
  });
}
