import 'package:sqflite/sqflite.dart';

import 'model/db_table.dart';
import 'model/db_data_converter.dart';
import 'model/db_filter.dart';
import 'model/db_sorter.dart';
import 'tunai_db_initializer.dart';
import 'tunai_db_logger.dart';

abstract class TunaiDB<T> {
  DBTable get table;
  Database get _db => TunaiDBInitializer().database;
  DBDataConverter<T> get dbTableDataConverter;

  bool get debugPrint => false;

  Future<void> insertList(
    List<T> list, {
    Map<String, Object?> Function(T data)? toMap,
    List<DBFilter> filters = const [],
    bool debugPrint = false,
  }) async {
    final currentTime = DateTime.now();
    final primaryKeyField = table.primaryKeyField;

    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (var item in list) {
        // batch.insert(
        //   table.tableName,
        //   toMap?.call(item) ?? dbTableDataConverter.toMap(item),
        //   conflictAlgorithm: conflictAlgorithm,
        // );

        String query = _getUpsertRawQuery(
          dataMap: toMap?.call(item) ?? dbTableDataConverter.toMap(item),
          primaryFieldName: primaryKeyField.fieldName,
        );
        if (debugPrint) {
          TunaiDBLogger.logAction(query);
        }

        batch.execute(query);
      }

      await batch.commit();
    });

    if (debugPrint) {
      TunaiDBLogger.logAction(
          'Inserted ${list.length} items to Table(${table.tableName}) took : ${DateTime.now().difference(currentTime).inMilliseconds} ms');
    }
  }

  Future<void> insertJsons(List<Map<String, dynamic>> list) async {
    final currentTime = DateTime.now();
    final primaryKeyField = table.primaryKeyField;

    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (var item in list) {
        // batch.insert(
        //   table.tableName,
        //   toMap?.call(item) ?? dbTableDataConverter.toMap(item),
        //   conflictAlgorithm: conflictAlgorithm,
        // );

        String query = _getUpsertRawQuery(
          dataMap: item,
          primaryFieldName: primaryKeyField.fieldName,
        );
        if (debugPrint) {
          TunaiDBLogger.logAction('Upsert json query : \n$query');
        }

        batch.execute(query);
      }

      await batch.commit();
    });

    if (debugPrint) {
      TunaiDBLogger.logAction(
          'Inserted ${list.length} items to Table(${table.tableName}) took : ${DateTime.now().difference(currentTime).inMilliseconds} ms');
    }
  }

  Future<void> insert(
    T data, {
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
    Map<String, Object?> Function(T data)? toMap,
  }) async {
    if (debugPrint) {
      TunaiDBLogger.logAction('Inserting : $data to Table(${table.tableName})');
    }
    final primaryKeyField = table.primaryKeyField;
    await _db.rawQuery(_getUpsertRawQuery(
      dataMap: toMap?.call(data) ?? dbTableDataConverter.toMap(data),
      primaryFieldName: primaryKeyField.fieldName,
    ));
    // await _db.insert(
    //   table.tableName,
    //   toMap?.call(data) ?? dbTableDataConverter.toMap(data),
    //   conflictAlgorithm: conflictAlgorithm,
    // );
  }

  Future<int> getCount() async {
    final List<Map<String, Object?>> data =
        await _db.rawQuery('SELECT COUNT(*) FROM ${table.tableName};');
    return data.first['COUNT(*)'] as int;
  }

  Future<void> delete(List<DBFilter> filters) async {
    if (debugPrint) {
      TunaiDBLogger.logAction(
          'Deleting db data match($filters) in Table(${table.tableName})');
    }
    await _db.delete(
      table.tableName,
      where: filters.map((e) => e.getQuery()).join(' AND '),
    );
  }

  Future<void> update({
    required T newData,
    required List<DBFilter> filters,
  }) async {
    if (debugPrint) {
      TunaiDBLogger.logAction(
          'Update db data match($filters) in Table(${table.tableName})');
    }
    await _db.update(
      table.tableName,
      dbTableDataConverter.toMap(newData),
      where: filters.map((e) => e.getQuery()).join(' AND '),
    );
  }

  Future<List<Map<String, dynamic>>> fetchWithInnerJoin({
    List<DBFilter> filters = const [],
    bool debugPrint = false,
  }) async {
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
              .map((filter) => filter.getQuery(nameTag: 'ori.'))
              .join(' AND ');
      // TunaiDBLogger.logAction('where clause : $whereClause');
      query += whereClause;
    }

    if (debugPrint) {
      TunaiDBLogger.logAction('innerJoin fetch ${table.tableName} -> $query');
    }

    List<Map<String, dynamic>> results = await _db.rawQuery(query);

    return results;
  }

  Future<List<T>> fetch({
    List<DBFilter> filters = const [],
    T Function(Map<String, Object?> map)? fromMap,
    DBSorter? sorter,
    int? offset,
    int? limit,
  }) async {
    final currentTime = DateTime.now();
    List<Map<String, dynamic>> list = [];

    if (filters.isEmpty) {
      list = await _db.query(
        table.tableName,
        orderBy: sorter?.getSortQuery(),
        limit: limit,
        offset: offset,
      );
    } else {
      list = await _db.query(
        table.tableName,
        where: filters.map((e) => e.getQuery()).join(' AND '),
        // whereArgs: filter.matchings,
        orderBy: sorter?.getSortQuery(),
        limit: limit,
        offset: offset,
      );
    }

    final List<T> parsedList = list
        .map((e) => fromMap?.call(e) ?? dbTableDataConverter.fromMap(e))
        .toList();

    if (debugPrint) {
      TunaiDBLogger.logAction(
        'Fetched from db (${table.tableName}) ${parsedList.length} items took : ${DateTime.now().difference(currentTime).inMilliseconds} ms',
      );
    }

    return parsedList;
  }

  String _getUpsertRawQuery({
    required Map<String, Object?> dataMap,
    required String primaryFieldName,
  }) {
    final columns = dataMap.keys.join(', ');
    final values = dataMap.values.map((value) {
      if (value is String) {
        return "'${_escapeSingleQuotes(value)}'";
      }
      return "'$value'";
    }).join(', ');

    // Exclude the primary key from the update clause
    final updateClause = dataMap.keys
        .where((column) => column != primaryFieldName)
        .map((column) => "$column = excluded.$column")
        .join(', ');

    final rawQuery = '''
    INSERT INTO ${table.tableName} ($columns)
    VALUES ($values)
    ON CONFLICT(${primaryFieldName}) DO UPDATE SET
    $updateClause;
  ''';

    return rawQuery;
  }
}

String _escapeSingleQuotes(String input) {
  return input.replaceAll("'", "''");
}
