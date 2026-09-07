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
    final fields = [
      for (final field in mainTable.fields)
        '${mainTable.tableName}.${field.fieldName} AS ${field.fieldName}',
      for (final join in leftJoins)
        for (final field in join.joinedTable.fields)
          '${join.outputName}.${field.fieldName} AS ${join.outputName}_${field.fieldName}',
    ];
    return 'SELECT ${fields.join(', ')}';
  }
}
