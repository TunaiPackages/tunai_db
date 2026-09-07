import 'db_filter.dart';
import 'db_filter_join_type.dart';

class GroupedDBFilter {
  final DBFilterJoinType filterJoinType;
  final List<BaseDBFilter> filters;

  const GroupedDBFilter({
    required this.filterJoinType,
    required this.filters,
  });

  String getQuery() {
    return filters
        .map((e) => e.getQuery())
        .join(' ${filterJoinType.queryOperator} ');
  }
}
