import 'package:sqflite/sqflite.dart';
import 'package:tunai_db/src/model/db_filter.dart';
import 'package:tunai_db/src/model/db_filter_join_type.dart';
import 'package:tunai_db/src/model/db_sorter.dart';
import 'package:tunai_db/src/model/db_table.dart';
import 'package:tunai_db/src/tunai_db_initializer.dart';
import 'utils/limit_offset_generator.dart';

class TunaiJoinedDB {
  Database get _db => TunaiDBInitializer().database;

  Future<List<Map<String, dynamic>>> fetch({
    required JoinedDB mainTable,
    required List<LeftJoinedDB> joinedTables,
    int? offset,
    int? limit,
    DBSorter? sorter,
  }) {
    final arguments = <Object?>[];
    String query = 'SELECT ${mainTable.selectedFieldsQuery}';

    for (var joinedTable in joinedTables) {
      query += ', ${joinedTable.selectedFieldsQuery}';
    }

    query += ' FROM ${mainTable.table.tableName} ${mainTable.applyTag} ';

    for (var joinedTable in joinedTables) {
      query += '${joinedTable.leftJoinQuery} ';
    }

    List<String> whereQueries = [
      mainTable.buildWhereQuery(arguments: arguments),
      ...joinedTables.map((e) => e.buildWhereQuery(arguments: arguments)),
    ].where((e) => e.isNotEmpty).toList();

    if (whereQueries.isNotEmpty) {
      query += ' WHERE ${whereQueries.map((q) => '($q)').join(' AND ')}';
    }

    if (sorter != null) {
      query += ' ORDER BY ${sorter.getSortQuery()}';
    }

    query += LimitOffsetGenerator(limit: limit, offset: offset).generate();
    query += ';';

    TunaiDBInitializer.logger
        .logFetch('Fetching joined rows from ${mainTable.table.tableName}');

    return _db.rawQuery(query, arguments);
  }
}

class JoinedDB {
  final DBTable table;
  final String? tag;
  final List<String>? fields;
  final List<BaseDBFilter>? filters;
  final DBFilterJoinType filterJoinType;

  const JoinedDB({
    required this.table,
    this.tag,
    this.fields,
    this.filters,
    this.filterJoinType = DBFilterJoinType.and,
  });

  String get applyTag => tag ?? table.tableName;
  List<String> get selectedFields =>
      fields ?? table.fields.map((e) => e.fieldName).toList();

  String get selectedFieldsQuery {
    String query =
        selectedFields.map((e) => '$applyTag.$e AS ${applyTag}_$e').join(', ');

    return query;
  }

  String get whereQuery => buildWhereQuery();

  String buildWhereQuery({List<Object?>? arguments}) {
    if (filters == null || filters!.isEmpty) {
      return '';
    }

    return filters!
        .map((e) => arguments == null
            ? e.getQuery(nameTag: '$applyTag.')
            : e.parameterized(arguments, nameTag: '$applyTag.'))
        .join(' ${filterJoinType.queryOperator} ');
  }
}

class LeftJoinedDB extends JoinedDB {
  final LeftJoinOnClause onClause;

  const LeftJoinedDB({
    required super.table,
    required this.onClause,
    super.tag,
    super.fields,
    super.filters,
  });

  String get leftJoinQuery =>
      'LEFT JOIN ${table.tableName} $applyTag ${onClause.getQuery()}';
}

class LeftJoinOnClause {
  final DBFilterType filterType;
  final String field1;
  final String field2;

  const LeftJoinOnClause({
    this.filterType = DBFilterType.equal,
    required this.field1,
    required this.field2,
  });

  String getQuery() => 'ON $field1 ${filterType.comparisonOperator} $field2';
}
