import '../model/db_field.dart';
import '../model/db_left_join.dart';
import '../model/db_table.dart';
import 'query_generator.dart';

class SelectClauseGenerator extends QueryGenerator {
  final DBTable mainTable;
  final List<DBLeftJoin> leftJoins;

  const SelectClauseGenerator({
    required this.mainTable,
    required this.leftJoins,
  });

  @override
  String generate() {
    String query = 'SELECT ';

    // Add main table fields
    for (var field in mainTable.fields) {
      query +=
          '${mainTable.tableName}.${field.fieldName} AS ${field.fieldName}, ';
    }

    // Add joined table fields
    for (int i = 0; i < leftJoins.length; i++) {
      final leftJoin = leftJoins[i];
      final joinedTable = leftJoin.joinedTable;
      bool isLastTable = i == leftJoins.length - 1;

      for (var field in joinedTable.fields) {
        bool isLast = field == joinedTable.fields.last;
        query +=
            '${leftJoin.outputName}.${field.fieldName} AS ${leftJoin.outputName}_${field.fieldName}';

        if (isLast && isLastTable) continue;
        query += ', ';
      }
    }

    return query;
  }
}
