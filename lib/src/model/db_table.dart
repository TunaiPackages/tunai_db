import 'db_field.dart';

class DBTable {
  final String tableName;
  final List<DBField> fields;

  DBField get primaryKeyField =>
      fields.firstWhere((field) => field.isPrimaryKey);
  List<DBField> get foreignFields =>
      fields.where((field) => field.reference != null).toList();

  const DBTable({required this.tableName, required this.fields});

  String get createTableQuery {
    String query = 'CREATE TABLE $tableName (';
    query += fields.map((field) => field.fieldDefinition).join(', ');
    bool hasForeignReference = fields.any((field) => field.reference != null);
    if (hasForeignReference) {
      for (var field in fields) {
        if (field.reference != null) {
          query +=
              ', FOREIGN KEY (${field.fieldName}) REFERENCES ${field.reference!.table.tableName}(${field.reference!.fieldName})';
        }
      }
    }
    query += ')';

    return query;
  }
}
