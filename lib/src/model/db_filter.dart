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
  final bool ignoreSpaces;

  const DBSearchFilter({
    required this.fieldName,
    required this.searchValue,
    this.caseSensitive = false,
    this.ignoreSpaces = false,
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

  /// Escapes special SQL characters to prevent SQL injection
  String _escapeSqlValue(String value) {
    return value
        .replaceAll("'", "''") // Escape single quotes
        .replaceAll('\\', '\\\\') // Escape backslashes
        .replaceAll('%', '\\%') // Escape LIKE wildcards
        .replaceAll('_', '\\_'); // Escape LIKE wildcards
  }

  @override
  String getQuery({String nameTag = ''}) {
    // Validate inputs
    if (fieldName.isEmpty) {
      throw ArgumentError('fieldName cannot be empty');
    }
    if (searchValue.isEmpty) {
      throw ArgumentError('searchValue cannot be empty');
    }

    // Clean and escape the search value
    final cleanedValue = _cleanedSearchValue(searchValue);
    final escapedSearchValue = _escapeSqlValue(cleanedValue);

    // Build the field reference with proper escaping
    final fieldRef = '$nameTag$fieldName';

    if (caseSensitive) {
      if (ignoreSpaces) {
        // For case-sensitive search with spaces ignored, we need to clean both field and search value
        return 'REPLACE($fieldRef, \' \', \'\') LIKE \'%$escapedSearchValue%\'';
      } else {
        return '$fieldRef LIKE \'%$escapedSearchValue%\'';
      }
    } else {
      if (ignoreSpaces) {
        // For case-insensitive search with spaces ignored, clean both field and search value
        return 'LOWER(REPLACE($fieldRef, \' \', \'\')) LIKE LOWER(\'%$escapedSearchValue%\')';
      } else {
        // Use LOWER() function for case-insensitive search
        return 'LOWER($fieldRef) LIKE LOWER(\'%$escapedSearchValue%\')';
      }
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
  String getQuery({String nameTag = ''}) {
    return filters
        .map((e) => e.getQuery(nameTag: nameTag))
        .join(' ${filterJoinType.queryOperator} ');
  }
}
