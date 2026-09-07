import 'package:tunai_db/tunai_db.dart';

/// Represents a LEFT JOIN configuration for database queries.
///
/// This class defines how to join a secondary table with the main table
/// using a LEFT JOIN operation. It specifies the relationship between
/// tables and how to match records.
///
/// Example usage:
/// ```dart
/// final leftJoin = DBLeftJoin(
///   joinedTable: userTable,
///   mainTableName: 'orders',
///   joinedTableForeignKey: 'user_id',
///   mainTablePrimaryKey: 'id',
///   joinedTableAlias: 'u', // optional alias
/// );
/// ```
class DBLeftJoin {
  /// The table to join with the main table.
  ///
  /// This is the secondary table that will be LEFT JOINed with the main table.
  /// The table contains the foreign key that references the main table.
  ///
  /// Example: If joining users table with orders table, this would be the users table.
  final DBTable joinedTable;

  /// The name of the main table that contains the primary key.
  ///
  /// This is the table name (not the DBTable object) that contains the primary key
  /// that the foreign key references. Used in the ON clause of the LEFT JOIN.
  ///
  /// Example: If joining users with orders, and orders is the main table,
  /// this would be 'orders'.
  final String mainTableName;

  /// The foreign key field name in the joined table.
  ///
  /// This is the field name in the joined table (specified by [joinedTable]) that
  /// contains the foreign key value that references the main table's primary key.
  ///
  /// Example: If users table has a field 'user_id' that references orders.id,
  /// this would be 'user_id'.
  final String joinedTableForeignKey;

  /// The primary key field name in the main table.
  ///
  /// This is the field name in the main table (specified by [mainTableName])
  /// that is referenced by the foreign key in the joined table.
  ///
  /// Example: If orders table has a primary key field 'id' that is referenced
  /// by users.user_id, this would be 'id'.
  final String mainTablePrimaryKey;

  /// Optional alias for the joined table in the query.
  ///
  /// If provided, this alias will be used instead of the table name in the
  /// generated SQL query. This is useful for avoiding naming conflicts or
  /// making queries more readable.
  ///
  /// Example: If set to 'u', the query will use 'users AS u' instead of just 'users'.
  ///
  /// If null, the table name will be used directly.
  final String? joinedTableAlias;

  /// Returns the output name for the joined table.
  ///
  /// If [joinedTableAlias] is provided, returns that alias. Otherwise, returns
  /// the table name from [joinedTable.tableName].
  ///
  /// This is used internally by query generators to determine how to
  /// reference the joined table in the generated SQL.
  String get outputName => joinedTableAlias ?? joinedTable.tableName;

  /// Creates a new DBLeftJoin configuration.
  ///
  /// [joinedTable] - The table to join with the main table
  /// [mainTableName] - The name of the main table containing the primary key
  /// [joinedTableForeignKey] - The foreign key field name in the joined table
  /// [mainTablePrimaryKey] - The primary key field name in the main table
  /// [joinedTableAlias] - Optional alias for the joined table
  ///
  /// Example:
  /// ```dart
  /// // Join users table with orders table
  /// // users.user_id references orders.id
  /// final leftJoin = DBLeftJoin(
  ///   joinedTable: usersTable,
  ///   mainTableName: 'orders',
  ///   joinedTableForeignKey: 'user_id',    // field in users table
  ///   mainTablePrimaryKey: 'id',           // field in orders table
  ///   joinedTableAlias: 'u',               // optional alias
  /// );
  ///
  /// // This generates: LEFT JOIN users AS u ON u.user_id = orders.id
  /// ```
  DBLeftJoin({
    required this.joinedTable,
    required this.mainTableName,
    required this.joinedTableForeignKey,
    required this.mainTablePrimaryKey,
    this.joinedTableAlias,
  });
}
