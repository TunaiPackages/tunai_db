import 'package:tunai_db/src/model/db_filter_join_type.dart';

enum DBFilterType {
  equal,
  notEqual,
  greaterThan,
  greaterThanOrEqual,
  lessThan,
  lessThanOrEqual,
  like,
  ;

  String get comparisonOperator {
    switch (this) {
      case DBFilterType.equal:
        return '=';
      case DBFilterType.notEqual:
        return '<>';
      case DBFilterType.greaterThan:
        return '>';
      case DBFilterType.greaterThanOrEqual:
        return '>=';
      case DBFilterType.lessThan:
        return '<';
      case DBFilterType.lessThanOrEqual:
        return '<=';
      case DBFilterType.like:
        return 'LIKE';
    }
  }
}

/// Base class for all DB filters
///
/// This class serves as the base for implementing database filters in the TunaiDB system.
/// There are several concrete implementations available:
///
/// - [DBFilter]: Basic filter for comparing field values using operators like =, <>, >, etc
/// ```dart
/// DBFilter(fieldName: 'age', matched: 21) // age = 21
/// DBFilter(fieldName: 'price', matched: 100, filterType: DBFilterType.greaterThan) // price > 100
/// ```
///
/// - [DBFilterIn]: Filter for checking if a field value matches any in a list
/// ```dart
/// DBFilterIn(fieldName: 'status', matched: ['active', 'pending']) // status IN ('active', 'pending')
/// ```
///
/// - [DBSearchFilter]: Filter for performing text search with LIKE operator
/// ```dart
/// DBSearchFilter(fieldName: 'name', searchValue: 'john') // name LIKE '%john%'
/// ```
///
/// - [CompositeDBFilter]: Filter for combining multiple filters with AND/OR operators
/// ```dart
/// CompositeDBFilter(
///   filters: [
///     DBFilter(fieldName: 'age', matched: 21),
///     DBFilter(fieldName: 'status', matched: 'active')
///   ],
///   joinType: DBFilterJoinType.and
/// ) // age = 21 AND status = 'active'
/// ```
///
abstract class BaseDBFilter {
  const BaseDBFilter();
  String getQuery();
}

class DBFilterIn extends BaseDBFilter {
  final String fieldName;
  final List<Object> matched;

  const DBFilterIn({
    required this.fieldName,
    required this.matched,
  });

  @override
  String getQuery({String nameTag = ''}) {
    String formattedMatched =
        matched.map((e) => e is String ? "'$e'" : e.toString()).join(', ');
    return '$nameTag$fieldName IN ($formattedMatched)';
  }
}

class DBFilter extends BaseDBFilter {
  final String fieldName;
  final Object matched;
  final DBFilterType filterType;

  const DBFilter({
    required this.fieldName,
    required this.matched,
    this.filterType = DBFilterType.equal,
  });

  @override
  String getQuery({String nameTag = ''}) {
    String formattedMatched =
        matched is String ? "'$matched'" : matched.toString();
    return '$nameTag$fieldName ${filterType.comparisonOperator} $formattedMatched';
  }
}

class DBSearchFilter extends BaseDBFilter {
  final String fieldName;
  final String searchValue;
  final bool caseSensitive;

  const DBSearchFilter({
    required this.fieldName,
    required this.searchValue,
    this.caseSensitive = false,
  });

  @override
  String getQuery({String nameTag = ''}) {
    // Escape single quotes in search value to prevent SQL injection
    final escapedSearchValue = searchValue.replaceAll("'", "''");

    if (caseSensitive) {
      return '$nameTag$fieldName LIKE \'%$escapedSearchValue%\'';
    } else {
      // Use LOWER() function for case-insensitive search
      return 'LOWER($nameTag$fieldName) LIKE LOWER(\'%$escapedSearchValue%\')';
    }
  }
}

class CompositeDBFilter extends BaseDBFilter {
  final DBFilterJoinType filterJoinType;
  final List<BaseDBFilter> filters;

  const CompositeDBFilter({
    required this.filterJoinType,
    required this.filters,
  });

  @override
  String getQuery() {
    return filters
        .map((e) => e.getQuery())
        .join(' ${filterJoinType.queryOperator} ');
  }
}
