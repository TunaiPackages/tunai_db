import 'db_field.dart';

class DBTable {
  final String tableName;
  final List<DBField> fields;

  DBField get primaryKeyField =>
      fields.firstWhere((field) => field.isPrimaryKey);
  List<DBField> get foreignFields =>
      fields.where((field) => field.reference != null).toList();

  const DBTable({required this.tableName, required this.fields});

  List<DBField> get indexingFields =>
      fields.where((field) => field.indexing && !field.isPrimaryKey).toList();

  String get createTableQuery {
    String query = 'CREATE TABLE $tableName (';
    query += fields.map((field) => field.fieldQuery).join(', ');
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

  String get createIndexQuery {
    String query = '';

    for (var field in indexingFields) {
      query +=
          'CREATE INDEX ${tableName}_${field.fieldName}_index ON $tableName (${field.fieldName});';
    }

    return query;
  }
}
