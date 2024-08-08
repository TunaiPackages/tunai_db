import 'db_table.dart';

class DBReference {
  final DBTable table;
  final String fieldName;

  const DBReference({required this.table, required this.fieldName});
}
