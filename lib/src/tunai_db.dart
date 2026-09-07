import 'package:sqflite/sqflite.dart';
import 'package:tunai_db/src/model/db_filter_join_type.dart';
import 'package:tunai_db/src/model/db_inner_join_table.dart';
import 'package:tunai_db/src/model/db_left_join.dart';
import 'package:tunai_db/src/model/grouped_db_filter.dart';
import 'package:tunai_db/src/utils/query_helper.dart';

import 'model/db_field.dart';
import 'model/db_table.dart';
import 'model/db_data_converter.dart';
import 'model/db_filter.dart';
import 'model/db_sorter.dart';
import 'tunai_db_initializer.dart';
import 'tunai_db_trxn_queue.dart';
import 'utils/sql_value.dart';
import 'utils/limit_offset_generator.dart';

abstract class TunaiDB<T> {
  DBTable get table;
  Database get _db => TunaiDBInitializer().database;
  DBDataConverter<T> get dbTableDataConverter;

  /// Transaction chunks commit independently. Any failed chunk rolls back and
  /// rejects the returned Future; previously committed chunks remain durable.
  Future<void> insertList(
    List<T> list, {
    Map<String, Object?> Function(T data)? toMap,
    List<DBFilter> filters = const [],
    int batchSize = 200,
    int transactionSize = 1000,
  }) async {
    if (batchSize <= 0 || transactionSize <= 0) {
      throw ArgumentError('batchSize and transactionSize must be positive');
    }
    if (list.isEmpty) return;
    final key = _requirePrimaryKey();
    for (var i = 0; i < list.length; i += transactionSize) {
      final end =
          i + transactionSize < list.length ? i + transactionSize : list.length;
      final chunk = list.sublist(i, end);
      await TunaiDBTrxnQueue().add(
        operationName: '${table.tableName} InsertList $i-$end',
        operation: (transaction) async {
          for (var j = 0; j < chunk.length; j += batchSize) {
            final batchEnd =
                j + batchSize < chunk.length ? j + batchSize : chunk.length;
            // Conversion stays inside the transaction: a bad later batch also
            // rolls back earlier batches in this transaction chunk.
            final maps = chunk
                .sublist(j, batchEnd)
                .map((item) =>
                    toMap?.call(item) ?? dbTableDataConverter.toMap(item))
                .toList();
            await _upsertMaps(transaction, key, maps);
          }
        },
      );
    }
  }

  Future<void> insertJsons(List<Map<String, dynamic>> list) async {
    if (list.isEmpty) return;
    final key = _requirePrimaryKey();
    await TunaiDBTrxnQueue().add(
      operationName: '${table.tableName} InsertJsons',
      operation: (transaction) => _upsertMaps(transaction, key, list),
    );
  }

  /// Default replace means a non-destructive primary-key upsert. Explicit
  /// alternative conflict policies use SQLite INSERT semantics.
  Future<void> insert(
    T data, {
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
    Map<String, Object?> Function(T data)? toMap,
  }) async {
    final key = _requirePrimaryKey();
    final map =
        _sqliteMap(toMap?.call(data) ?? dbTableDataConverter.toMap(data));
    await TunaiDBTrxnQueue().add(
      operationName: '${table.tableName} Insert',
      operation: (transaction) async {
        if (conflictAlgorithm != ConflictAlgorithm.replace) {
          await transaction.insert(table.tableName, map,
              conflictAlgorithm: conflictAlgorithm);
        } else {
          await _upsertMaps(transaction, key, [map]);
        }
      },
    );
  }

  Future<int> getCount({
    List<DBFilter> filters = const [],
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
  }) async {
    final arguments = <Object?>[];
    String whereClause = '';

    if (filters.isNotEmpty) {
      whereClause = 'WHERE ' +
          filters
              .map((e) => e.parameterized(arguments))
              .join(' ${filterJoinType.queryOperator} ');
    }

    final List<Map<String, Object?>> data = await _db.rawQuery(
        'SELECT COUNT(*) FROM ${table.tableName} $whereClause;', arguments);

    return data.first['COUNT(*)'] as int;
  }

  Future<void> delete(List<BaseDBFilter> filters) async {
    logAction('Deleting db data match($filters) in Table(${table.tableName})');
    await TunaiDBTrxnQueue().add(
      operationName: '${table.tableName} Delete',
      operation: (trxn) async {
        final arguments = <Object?>[];
        final where =
            filters.map((e) => e.parameterized(arguments)).join(' AND ');
        await trxn.delete(
          table.tableName,
          where: where.isEmpty ? null : where,
          whereArgs: arguments,
        );
      },
    );
  }

  Future<void> deleteAll() async {
    logAction('Deleting all data in Table(${table.tableName})');
    await TunaiDBTrxnQueue().add(
      operation: (trxn) async {
        await trxn.delete(table.tableName);
      },
    );
  }

  Future<void> update({
    required T newData,
    required List<DBFilter> filters,
  }) async {
    logAction('Update db data match($filters) in Table(${table.tableName})');
    await TunaiDBTrxnQueue().add(
      operationName: '${table.tableName} Update',
      operation: (trxn) async {
        final arguments = <Object?>[];
        final where =
            filters.map((e) => e.parameterized(arguments)).join(' AND ');
        await trxn.update(
          table.tableName,
          _sqliteMap(dbTableDataConverter.toMap(newData)),
          where: where.isEmpty ? null : where,
          whereArgs: arguments,
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchWithTables({
    List<({BaseDBFilter filter, DBTable matchedTable})> filters = const [],
    required List<DBInnerJoinTable> tableRecords,
    bool printQuery = false,
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
    int? offset,
    int? limit,
  }) async {
    // Validate that at least one table is provided
    if (tableRecords.isEmpty) {
      throw ArgumentError('At least one table must be provided.');
    }

    logFetch(
        'Fetching with tables : ${tableRecords.map((e) => e.table.tableName).join(', ')}');

    final arguments = <Object?>[];
    String query = 'SELECT ';

    for (var field in table.fields) {
      query +=
          '${table.tableName}.${field.fieldName} AS ${table.tableName}_${field.fieldName}' +
              ', ';
    }

    for (int i = 0; i < tableRecords.length; i++) {
      final joinedTableR = tableRecords[i];
      final joinedTable = joinedTableR.table;

      bool isLastTable = i == tableRecords.length - 1;

      for (var field in joinedTable.fields) {
        bool isLast = field == joinedTable.fields.last;
        query +=
            '${joinedTableR.outputName}.${field.fieldName} AS ${joinedTableR.outputName}_${field.fieldName}';

        if (isLast && isLastTable) continue;
        query += ', ';
      }
    }

    // Add FROM clause
    query += ' FROM ${table.tableName}';

    // Add LEFT JOIN clauses for remaining tables
    for (int i = 0; i < tableRecords.length; i++) {
      final joinedTableR = tableRecords[i];
      final joinedTable = joinedTableR.table;
      final joinedKey = joinedTableR.key;
      String matchedKey = joinedTableR.matchedKey ??
          '${joinedTableR.matchedTable.tableName}.${joinedKey}';

      query += ' LEFT JOIN ${joinedTable.tableName}';

      if (joinedTableR.outputKey != null) {
        query += ' AS ${joinedTableR.outputKey}';
        query += ' ON ${joinedTableR.outputKey}.${joinedKey} = $matchedKey';
      } else {
        query += ' ON ${joinedTable.tableName}.${joinedKey} = $matchedKey';
      }
    }

    if (filters.isNotEmpty) {
      String whereClause = ' WHERE ${filters.map(
        (filterR) {
          final filter = filterR.filter;
          final matchedTable = filterR.matchedTable;
          return filter.parameterized(arguments,
              nameTag: '${matchedTable.tableName}.');
        },
      ).join(' ${filterJoinType.queryOperator} ')}';
      query += whereClause;
    }

    query += LimitOffsetGenerator(limit: limit, offset: offset).generate();
    // Debug print the query if needed
    if (printQuery) {
      logRaw('FetchWithTables: $query');
    }

    // Execute the query and return results
    List<Map<String, dynamic>> results = await _db.rawQuery(query, arguments);

    logFetch('Fetched ${results.length} items from Table(${table.tableName})');
    return results;
  }

  @Deprecated('Use fetchWithTables instead')
  Future<List<Map<String, dynamic>>> fetchWithInnerJoin({
    List<DBFilter> filters = const [],
    bool debugPrint = false,
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
  }) async {
    logFetch('Fetching with inner join');
    final arguments = <Object?>[];
    String query = 'SELECT ';

    for (var field in table.fields) {
      query += 'ori.${field.fieldName}' + ', ';
    }

    for (int i = 0; i < table.foreignFields.length; i++) {
      final field = table.foreignFields[i];
      final refTable = field.reference!.table;
      bool isLast = i == table.foreignFields.length - 1;

      for (var refField in refTable.fields) {
        bool isLastField = refField == refTable.fields.last;
        query +=
            'ref$i.${refField.fieldName} AS ${refTable.tableName}_${refField.fieldName}';
        if (!isLast || !isLastField) {
          query += ', ';
        } else {
          query += ' ';
        }
      }
    }

    query += 'FROM ${table.tableName} as ori ';

    for (int i = 0; i < table.foreignFields.length; i++) {
      final field = table.foreignFields[i];
      final refTable = field.reference!.table;

      query += 'LEFT JOIN ${refTable.tableName} as ref$i ';
      query +=
          'ON ori.${field.fieldName} = ref$i.${field.reference!.fieldName} ';
    }

    if (filters.isNotEmpty) {
      String whereClause = 'WHERE ' +
          filters
              .map((filter) => filter.parameterized(arguments, nameTag: 'ori.'))
              .join(' ${filterJoinType.queryOperator} ');
      // TunaiDBLogger.logAction('where clause : $whereClause');
      query += whereClause;
    }

    List<Map<String, dynamic>> results = await _db.rawQuery(query, arguments);

    logFetch('Fetched ${results.length} items from Table(${table.tableName})');

    return results;
  }

  Future<List<Map<String, dynamic>>> fetchWithLeftJoins({
    List<BaseDBFilter> filters = const [],
    List<GroupedDBFilter> groupedFilters = const [],
    List<DBLeftJoin> leftJoins = const [],
    T Function(Map<String, Object?> map)? fromMap,
    DBSorter? sorter,
    int? offset,
    int? limit,
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
    bool printQuery = false,
  }) async {
    logFetch('Fetching with left joins from Table(${table.tableName})');
    final currentTime = DateTime.now();

    final arguments = <Object?>[];
    // Build query using QueryHelper
    String query = QueryHelper().buildLeftJoinQuery(
      arguments: arguments,
      mainTable: table,
      leftJoins: leftJoins,
      filters: filters,
      groupedFilters: groupedFilters,
      filterJoinType: filterJoinType,
      orderBy: sorter?.getSortQuery(),
      limit: limit,
      offset: offset,
    );

    // Debug print the query if needed
    if (printQuery) {
      logRaw('FetchWithLeftJoins: $query');
    }

    // Execute the query
    List<Map<String, dynamic>> list = await _db.rawQuery(query, arguments);

    try {
      final List<T> parsedList = list.map((item) {
        try {
          return fromMap?.call(item) ?? dbTableDataConverter.fromMap(item);
        } catch (e) {
          logError('Failed to parse data from map: $e\n$item');
          rethrow;
        }
      }).toList();

      logFetch(
        'Fetched with left joins from db (${table.tableName}) ${parsedList.length} items took: ${DateTime.now().difference(currentTime).inMilliseconds} ms',
      );

      return list;
    } catch (e) {
      rethrow;
    }
  }

  Future<List<T>> fetch({
    List<BaseDBFilter> filters = const [],
    List<GroupedDBFilter> groupedFilters = const [],
    T Function(Map<String, Object?> map)? fromMap,
    DBSorter? sorter,
    int? offset,
    int? limit,
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
  }) async {
    logFetch('Fetching from Table(${table.tableName})');
    final currentTime = DateTime.now();
    final arguments = <Object?>[];
    List<Map<String, dynamic>> list = [];

    if (filters.isEmpty && groupedFilters.isEmpty) {
      list = await _db.query(
        table.tableName,
        orderBy: sorter?.getSortQuery(),
        limit: limit ?? (offset == null ? null : -1),
        offset: offset,
      );
    } else {
      list = await _db.query(
        table.tableName,
        where: QueryHelper().getWhereQuery(
          arguments: arguments,
          filters: filters,
          groupedFilters: groupedFilters,
          filterJoinType: filterJoinType,
        ),
        whereArgs: arguments,
        orderBy: sorter?.getSortQuery(),
        limit: limit ?? (offset == null ? null : -1),
        offset: offset,
      );
    }
    try {
      final List<T> parsedList = list.map((item) {
        try {
          return fromMap?.call(item) ?? dbTableDataConverter.fromMap(item);
        } catch (e) {
          logError('Failed to parse data from map : $e\n$item');
          rethrow;
        }
      }).toList();

      logFetch(
        'Fetched from db (${table.tableName}) ${parsedList.length} items took : ${DateTime.now().difference(currentTime).inMilliseconds} ms',
      );

      return parsedList;
    } catch (e) {
      rethrow;
    }
  }

  @Deprecated('Use fetch with DBFilterIn instead')
  Future<List<T>> fetchByFieldValues({
    T Function(Map<String, Object?> map)? fromMap,
    DBSorter? sorter,
    required String fieldName,
    required List<dynamic> values,
    List<DBFilter>? filters,
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
  }) async {
    logFetch('Fetching by field values');
    try {
      final currentTime = DateTime.now();
      final arguments = values.map(sqliteValue).toList();
      String query =
          'SELECT * FROM ${table.tableName} WHERE $fieldName IN (${List.filled(values.length, '?').join(',')})';
      if (filters != null && filters.isNotEmpty) {
        query += ' AND ';
        query += filters
            .map((f) => f.parameterized(arguments))
            .join(' ${filterJoinType.queryOperator} ');
      }
      if (sorter != null) {
        query += ' ORDER BY ${sorter.getSortQuery()}';
      }
      List<Map<String, dynamic>> list = await _db.rawQuery(query, arguments);
      final List<T> parsedList = list.map((item) {
        try {
          return fromMap?.call(item) ?? dbTableDataConverter.fromMap(item);
        } catch (e) {
          logError('Failed to parse data from map : $e\n$item ');
          rethrow;
        }
      }).toList();

      logFetch(
          'Fetched ${parsedList.length} items from Table(${table.tableName}) took : ${DateTime.now().difference(currentTime).inMilliseconds} ms');

      return parsedList;
    } catch (e) {
      rethrow;
    }
  }

  Future<double> getSum(String fieldName) async {
    logFetch('Getting sum of field $fieldName from Table(${table.tableName})');
    try {
      List<Map<String, dynamic>> content =
          await _db.rawQuery('SELECT SUM($fieldName) FROM ${table.tableName}');
      final sum = (content.first.values.first as num?)?.toDouble() ?? 0.0;

      logFetch(
          'Sum of field $fieldName from Table(${table.tableName}) is $sum');

      return sum;
    } catch (e) {
      rethrow;
    }
  }

  Future<List<Map<String, Object?>>> rawQuery(String query) async {
    logAction('Raw query: $query');
    final currentTime = DateTime.now();
    final result = await _db.rawQuery(query);
    logAction(
        'Raw query: $query took : ${DateTime.now().difference(currentTime).inMilliseconds} ms, result: ${result.length} items');
    return result;
  }

  DBField _requirePrimaryKey() {
    final keys = table.fields.where((field) => field.isPrimaryKey).toList();
    if (keys.length != 1) {
      throw StateError(
          'Table ${table.tableName} must declare exactly one primary key');
    }
    return keys.single;
  }

  Map<String, Object?> _sqliteMap(Map<String, Object?> map) {
    if (map.isEmpty) throw ArgumentError('An upsert map cannot be empty');
    return map.map((key, value) => MapEntry(key, sqliteValue(value)));
  }

  Future<void> _upsertMaps(DatabaseExecutor executor, DBField key,
      List<Map<String, Object?>> maps) async {
    if (TunaiDBInitializer.isSupportUpsert) {
      final batch = executor.batch();
      for (final input in maps) {
        final map = _sqliteMap(input);
        final columns = map.keys.map(quoteSqlIdentifier).join(', ');
        final assignments = map.keys
            .where((column) => column != key.fieldName)
            .map((column) =>
                '${quoteSqlIdentifier(column)} = excluded.${quoteSqlIdentifier(column)}')
            .join(', ');
        final action =
            assignments.isEmpty ? 'DO NOTHING' : 'DO UPDATE SET $assignments';
        batch.execute(
          'INSERT INTO ${quoteSqlIdentifier(table.tableName)} ($columns) '
          'VALUES (${List.filled(map.length, '?').join(', ')}) '
          'ON CONFLICT(${quoteSqlIdentifier(key.fieldName)}) $action',
          map.values.toList(),
        );
      }
      await batch.commit(noResult: true);
    } else {
      // Execute in order so repeated keys in one chunk see earlier writes.
      // Do not IGNORE unrelated constraint failures on legacy SQLite.
      for (final input in maps) {
        final map = _sqliteMap(input);
        final where = '${quoteSqlIdentifier(key.fieldName)} = ?';
        final arguments = [map[key.fieldName]];
        final existing = await executor.query(table.tableName,
            columns: [key.fieldName],
            where: where,
            whereArgs: arguments,
            limit: 1);
        if (existing.isEmpty) {
          await executor.insert(table.tableName, map);
        } else if (map.keys.any((column) => column != key.fieldName)) {
          await executor.update(table.tableName, map,
              where: where, whereArgs: arguments);
        }
      }
    }
    logAction('Upserted ${maps.length} rows in ${table.tableName}');
  }

  void logFetch(String message) {
    TunaiDBInitializer.logger.logFetch('${table.tableName} -> $message');
  }

  void logRaw(String message) {
    TunaiDBInitializer.logger.logRaw('${table.tableName} -> $message');
  }

  void logAction(String message) {
    TunaiDBInitializer.logger.logAction('${table.tableName} -> $message');
  }

  void logError(String message) {
    TunaiDBInitializer.logger.logError('${table.tableName} ! $message');
  }
}
