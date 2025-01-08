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

///DBFilter or DBFilterIn
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
