enum DBFilterJoinType {
  and,
  or,
  ;

  String get queryOperator => this == DBFilterJoinType.and ? 'AND' : 'OR';
}
