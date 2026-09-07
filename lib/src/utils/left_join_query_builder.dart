import '../model/db_filter.dart';
import '../model/db_filter_join_type.dart';
import '../model/db_left_join.dart';
import '../model/db_table.dart';
import '../model/grouped_db_filter.dart';
import 'limit_offset_generator.dart';
import 'left_join_clause_generator.dart';
import 'order_by_generator.dart';
import 'select_clause_generator.dart';
import 'where_clause_generator.dart';

class LeftJoinQueryBuilder {
  const LeftJoinQueryBuilder();

  String buildLeftJoinQuery({
    required DBTable mainTable,
    required List<DBLeftJoin> leftJoins,
    List<BaseDBFilter> filters = const [],
    List<GroupedDBFilter> groupedFilters = const [],
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    // Build SELECT clause
    final selectClause = SelectClauseGenerator(
      mainTable: mainTable,
      leftJoins: leftJoins,
    ).generate();

    // Add FROM clause
    String query = selectClause + ' FROM ${mainTable.tableName}';

    // Add LEFT JOIN clauses
    final leftJoinClauses = LeftJoinClauseGenerator(
      mainTableName: mainTable.tableName,
      leftJoins: leftJoins,
    ).generate();
    query += leftJoinClauses;

    // Add WHERE clause if filters are provided
    final whereClause = WhereClauseGenerator(
      filters: filters,
      groupedFilters: groupedFilters,
      filterJoinType: filterJoinType,
    ).generateWithWhereKeyword();
    query += whereClause;

    // Add ORDER BY clause
    final orderByClause = OrderByGenerator(orderBy: orderBy).generate();
    query += orderByClause;

    // Add LIMIT and OFFSET clauses
    final limitOffsetClause = LimitOffsetGenerator(
      limit: limit,
      offset: offset,
    ).generate();
    query += limitOffsetClause;

    return query;
  }
}
