import '../model/db_filter.dart';
import '../model/db_filter_join_type.dart';
import '../model/grouped_db_filter.dart';
import 'query_generator.dart';

class WhereClauseGenerator extends QueryGenerator {
  final List<BaseDBFilter> filters;
  final List<GroupedDBFilter> groupedFilters;
  final DBFilterJoinType filterJoinType;

  const WhereClauseGenerator({
    this.filters = const [],
    this.groupedFilters = const [],
    this.filterJoinType = DBFilterJoinType.and,
  });

  @override
  String generate({List<Object?>? arguments}) {
    if (filters.isEmpty && groupedFilters.isEmpty) {
      return '';
    }

    String filtersWhere = filters
        .map((e) =>
            arguments == null ? e.getQuery() : e.parameterized(arguments))
        .join(' ${filterJoinType.queryOperator} ');

    String groupedFiltersWhere = groupedFilters.map((e) {
      if (e.filters.isEmpty) {
        throw ArgumentError('A grouped filter cannot be empty');
      }
      return '(${e.filters.map((f) => arguments == null ? f.getQuery() : f.parameterized(arguments)).join(' ${e.filterJoinType.queryOperator} ')})';
    }).join(' ${filterJoinType.queryOperator} ');

    // Combine filters and grouped filters with proper join operator
    if (filters.isNotEmpty && groupedFilters.isNotEmpty) {
      return '$filtersWhere ${filterJoinType.queryOperator} $groupedFiltersWhere';
    } else if (filters.isNotEmpty) {
      return filtersWhere;
    } else {
      return groupedFiltersWhere;
    }
  }

  String generateWithWhereKeyword({List<Object?>? arguments}) {
    final whereClause = generate(arguments: arguments);
    if (whereClause.isEmpty) {
      return '';
    }
    return ' WHERE $whereClause';
  }
}
