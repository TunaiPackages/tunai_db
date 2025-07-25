import '../model/db_left_join.dart';
import 'query_generator.dart';

class LeftJoinClauseGenerator extends QueryGenerator {
  final String mainTableName;
  final List<DBLeftJoin> leftJoins;

  const LeftJoinClauseGenerator({
    required this.mainTableName,
    required this.leftJoins,
  });

  @override
  String generate() {
    String query = '';

    for (int i = 0; i < leftJoins.length; i++) {
      final leftJoin = leftJoins[i];
      final joinedTable = leftJoin.joinedTable;

      query += ' LEFT JOIN ${joinedTable.tableName}';

      if (leftJoin.joinedTableAlias != null) {
        query += ' AS ${leftJoin.joinedTableAlias}';
        query +=
            ' ON ${leftJoin.joinedTableAlias}.${leftJoin.joinedTableForeignKey} = ${leftJoin.mainTableName}.${leftJoin.mainTablePrimaryKey}';
      } else {
        query +=
            ' ON ${joinedTable.tableName}.${leftJoin.joinedTableForeignKey} = ${leftJoin.mainTableName}.${leftJoin.mainTablePrimaryKey}';
      }
    }

    return query;
  }
}
