import 'package:tunai_db/src/model/db_filter_join_type.dart';
import '../utils/sql_value.dart';

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
/// DBSearchFilter(fieldName: 'name', searchValue: 'John Doe', caseSensitive: false) // LOWER(name) LIKE LOWER('%john doe%')
/// DBSearchFilter(fieldName: 'name', searchValue: 'John Doe', ignoreSpaces: true) // LOWER(REPLACE(name, ' ', '')) LIKE LOWER('%johndoe%')
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
  String getQuery({String nameTag = ''});
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
    String formattedMatched = matched.map(sqlLiteral).join(', ');
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
    String formattedMatched = sqlLiteral(matched);
    return '$nameTag$fieldName ${filterType.comparisonOperator} $formattedMatched';
  }
}

class DBSearchFilter extends BaseDBFilter {
  final String fieldName;
  final String searchValue;
  final bool caseSensitive;
  final bool ignoreSpaces;

  const DBSearchFilter({
    required this.fieldName,
    required this.searchValue,
    this.caseSensitive = false,
    this.ignoreSpaces = true,
  });

  /// Cleans the search value by removing extra spaces and normalizing text
  String _cleanedSearchValue(String value) {
    if (ignoreSpaces) {
      // Remove all spaces and normalize whitespace
      return value.replaceAll(RegExp(r'\s+'), '').trim();
    }
    // Just normalize whitespace (replace multiple spaces with single space)
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _query(String nameTag, String Function(Object?) valueSql) {
    if (fieldName.isEmpty) throw ArgumentError('fieldName cannot be empty');
    if (searchValue.isEmpty) throw ArgumentError('searchValue cannot be empty');
    final cleaned = _cleanedSearchValue(searchValue);
    final field = ignoreSpaces
        ? "REPLACE($nameTag$fieldName, ' ', '')"
        : '$nameTag$fieldName';
    if (caseSensitive) {
      // SQLite LIKE is ASCII case-insensitive even with COLLATE BINARY.
      return 'INSTR($field, ${valueSql(cleaned)}) > 0';
    }
    final pattern = cleaned
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    return "LOWER($field) LIKE LOWER(${valueSql('%$pattern%')}) ESCAPE '\\'";
  }

  @override
  String getQuery({String nameTag = ''}) => _query(nameTag, sqlLiteral);
}

class CompositeDBFilter extends BaseDBFilter {
  final DBFilterJoinType filterJoinType;
  final List<BaseDBFilter> filters;

  const CompositeDBFilter({
    required this.filterJoinType,
    required this.filters,
  });

  @override
  String getQuery({String nameTag = ''}) {
    if (filters.isEmpty) {
      throw ArgumentError('A composite filter cannot be empty');
    }
    return '(${filters.map((e) => e.getQuery(nameTag: nameTag)).join(' ${filterJoinType.queryOperator} ')})';
  }
}

/// Adds parameter binding without adding abstract members to custom filters.
/// Custom getQuery implementations remain trusted, application-owned SQL.
extension DBFilterParameters on BaseDBFilter {
  String parameterized(List<Object?> arguments, {String nameTag = ''}) {
    String bind(Object? value) {
      arguments.add(sqliteValue(value));
      return '?';
    }

    final filter = this;
    if (filter is DBFilter && filter.runtimeType == DBFilter) {
      return '$nameTag${filter.fieldName} ${filter.filterType.comparisonOperator} ${bind(filter.matched)}';
    }
    if (filter is DBFilterIn && filter.runtimeType == DBFilterIn) {
      return '$nameTag${filter.fieldName} IN (${filter.matched.map(bind).join(', ')})';
    }
    if (filter is DBSearchFilter && filter.runtimeType == DBSearchFilter) {
      return filter._query(nameTag, bind);
    }
    if (filter is CompositeDBFilter &&
        filter.runtimeType == CompositeDBFilter) {
      if (filter.filters.isEmpty) {
        throw ArgumentError('A composite filter cannot be empty');
      }
      return '(${filter.filters.map((f) => f.parameterized(arguments, nameTag: nameTag)).join(' ${filter.filterJoinType.queryOperator} ')})';
    }
    return getQuery(nameTag: nameTag);
  }
}
