import '../model/db_filter.dart';
import '../model/db_filter_join_type.dart';
import '../model/db_left_join.dart';
import '../model/db_table.dart';
import '../model/grouped_db_filter.dart';
import 'left_join_clause_generator.dart';
import 'left_join_query_builder.dart';
import 'select_clause_generator.dart';
import 'where_clause_generator.dart';

class QueryHelper {
  String getWhereQuery({
    List<Object?>? arguments,
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
    List<BaseDBFilter> filters = const [],
    List<GroupedDBFilter> groupedFilters = const [],
  }) {
    return WhereClauseGenerator(
      filters: filters,
      groupedFilters: groupedFilters,
      filterJoinType: filterJoinType,
    ).generate(arguments: arguments);
  }

  String getSelectClauseWithLeftJoins({
    required DBTable mainTable,
    required List<DBLeftJoin> leftJoins,
  }) {
    return SelectClauseGenerator(
      mainTable: mainTable,
      leftJoins: leftJoins,
    ).generate();
  }

  String getLeftJoinClauses({
    required String mainTableName,
    required List<DBLeftJoin> leftJoins,
  }) {
    return LeftJoinClauseGenerator(
      mainTableName: mainTableName,
      leftJoins: leftJoins,
    ).generate();
  }

  String buildLeftJoinQuery({
    List<Object?>? arguments,
    required DBTable mainTable,
    required List<DBLeftJoin> leftJoins,
    List<BaseDBFilter> filters = const [],
    List<GroupedDBFilter> groupedFilters = const [],
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    return LeftJoinQueryBuilder().buildLeftJoinQuery(
      arguments: arguments,
      mainTable: mainTable,
      leftJoins: leftJoins,
      filters: filters,
      groupedFilters: groupedFilters,
      filterJoinType: filterJoinType,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }
}
