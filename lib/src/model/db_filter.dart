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
      default:
        return '=';
    }
  }
}

class DBFilter {
  final String fieldName;
  final Object matched;
  final DBFilterType filterType;

  const DBFilter({
    required this.fieldName,
    required this.matched,
    this.filterType = DBFilterType.equal,
  });

  String getQuery({String nameTag = ''}) {
    return '$nameTag$fieldName ${filterType.comparisonOperator} $matched';
  }
}
