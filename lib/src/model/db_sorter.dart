enum DBSortType {
  asc,
  desc,
}

class DBSorter {
  final String fieldName;
  final DBSortType sortType;

  const DBSorter({
    required this.fieldName,
    required this.sortType,
  });

  String getSortQuery() {
    return '$fieldName ${sortType == DBSortType.asc ? 'ASC' : 'DESC'}';
  }

  @override
  String toString() {
    return 'TableDataSorter{fieldName: $fieldName, sortType: $sortType}';
  }
}
