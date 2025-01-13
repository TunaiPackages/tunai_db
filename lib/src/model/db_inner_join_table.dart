import 'package:tunai_db/tunai_db.dart';

class DBInnerJoinTable {
  final String key;
  final DBTable table;
  final DBTable matchedTable;
  final String? matchedKey;
  final String? outputKey;

  String get outputName => outputKey ?? table.tableName;

  DBInnerJoinTable({
    required this.key,
    required this.table,
    required this.matchedTable,
    this.matchedKey,
    this.outputKey,
  });
}
