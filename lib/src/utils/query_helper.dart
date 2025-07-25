import '../model/db_filter.dart';
import '../model/db_filter_join_type.dart';
import '../model/grouped_db_filter.dart';

class QueryHelper {
  String getWhereQuery({
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
    List<BaseDBFilter> filters = const [],
    List<GroupedDBFilter> groupedFilters = const [],
  }) {
    if (filters.isEmpty && groupedFilters.isEmpty) {
      return '';
    }

    String filtersWhere = filters
        .map((e) => e.getQuery())
        .join(' ${filterJoinType.queryOperator} ');

    String groupedFiltersWhere = groupedFilters
        .map((e) => '(${e.getQuery()})')
        .join(' ${filterJoinType.queryOperator} ');

    // Combine filters and grouped filters with proper join operator
    if (filters.isNotEmpty && groupedFilters.isNotEmpty) {
      return '$filtersWhere ${filterJoinType.queryOperator} $groupedFiltersWhere';
    } else if (filters.isNotEmpty) {
      return filtersWhere;
    } else {
      return groupedFiltersWhere;
    }
  }
}
