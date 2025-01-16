import 'package:sqflite/sqflite.dart';
import 'package:tunai_db/src/model/db_filter_join_type.dart';
import 'package:tunai_db/src/model/db_inner_join_table.dart';

import 'model/db_field.dart';
import 'model/db_table.dart';
import 'model/db_data_converter.dart';
import 'model/db_filter.dart';
import 'model/db_sorter.dart';
import 'tunai_db_initializer.dart';
import 'tunai_db_logger.dart';
import 'tunai_db_trxn_queue.dart';

abstract class TunaiDB<T> {
  DBTable get table;
  Database get _db => TunaiDBInitializer().database;
  DBDataConverter<T> get dbTableDataConverter;

  void logAction(String message) {
    TunaiDBInitializer.logger.logAction('${table.tableName} -> $message');
  }

  void logError(String message) {
    TunaiDBInitializer.logger.logError('${table.tableName} ! $message');
  }

  Future<void> insertList(
    List<T> list, {
    Map<String, Object?> Function(T data)? toMap,
    List<DBFilter> filters = const [],
    int batchSize = 1000,
  }) async {
    return TunaiDBTrxnQueue().add(() async {
      final currentTime = DateTime.now();
      final primaryKeyField = table.primaryKeyField;
      bool isSupportUpsert = await _isSqliteVersionSupportUpsert();
      logAction(
          'Inserting list ${list.length}, isSupportUpsert: $isSupportUpsert, primaryKeyField: ${primaryKeyField.fieldName}');

      try {
        await _db.transaction((txn) async {
          for (var i = 0; i < list.length; i += batchSize) {
            final end =
                (i + batchSize < list.length) ? i + batchSize : list.length;
            final chunk = list.sublist(i, end);

            final batch = txn.batch();
            for (var item in chunk) {
              late final Map<String, Object?> dataMap;
              try {
                dataMap = toMap?.call(item) ?? dbTableDataConverter.toMap(item);
              } catch (e) {
                logError('Failed to convert data to map: $e\n$item');
                continue;
              }

              if (isSupportUpsert) {
                String query = _getUpsertRawQuery(
                  dataMap: dataMap,
                  primaryFieldName: primaryKeyField.fieldName,
                );

                batch.execute(query);
              } else {
                await _manualUpsert(
                  txn: txn,
                  primaryKeyField: primaryKeyField,
                  dataMap: dataMap,
                  batch: batch,
                );
              }
            }

            await batch.commit();
          }
        });
      } catch (e) {
        logError('Failed to insert list: $e');
        rethrow;
      }

      logAction(
          'Inserted ${list.length} items to Table(${table.tableName}) took: ${DateTime.now().difference(currentTime).inMilliseconds} ms');
    });
  }

  Future<void> insertJsons(List<Map<String, dynamic>> list) async {
    final currentTime = DateTime.now();
    final primaryKeyField = table.primaryKeyField;

    bool isSupportUpsert = await _isSqliteVersionSupportUpsert();
    logAction(
        'Inserting jsons ${list.length}, isSupportUpsert : ${isSupportUpsert}, primaryKeyField : ${primaryKeyField.fieldName}');

    await TunaiDBTrxnQueue().add(() async {
      await _db.transaction((txn) async {
        final batch = txn.batch();
        for (var item in list) {
          if (isSupportUpsert) {
            String query = _getUpsertRawQuery(
              dataMap: item,
              primaryFieldName: primaryKeyField.fieldName,
            );

            batch.execute(query);
          } else {
            await _manualUpsert(
              txn: txn,
              primaryKeyField: primaryKeyField,
              dataMap: item,
              batch: batch,
            );
          }
        }

        await batch.commit();
      });
    });

    logAction(
        'Inserted ${list.length} items to Table(${table.tableName}) took : ${DateTime.now().difference(currentTime).inMilliseconds} ms');
  }

  Future<void> insert(
    T data, {
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
    Map<String, Object?> Function(T data)? toMap,
  }) async {
    logAction('Inserting : $data to Table(${table.tableName})');
    final primaryKeyField = table.primaryKeyField;
    bool isSupportUpsert = await _isSqliteVersionSupportUpsert();
    final dataMap = toMap?.call(data) ?? dbTableDataConverter.toMap(data);

    await TunaiDBTrxnQueue().add(() async {
      await _db.transaction((txn) async {
        if (isSupportUpsert) {
          await txn.rawQuery(_getUpsertRawQuery(
            dataMap: dataMap,
            primaryFieldName: primaryKeyField.fieldName,
          ));
        } else {
          // Step 1: Fetch the existing row if it exists
          final existingRows = await txn.query(
            table.tableName,
            where: '${primaryKeyField.fieldName} = ?',
            whereArgs: [primaryKeyField.fieldName],
          );

          if (existingRows.isNotEmpty) {
            // Merge the existing row with the new data
            final existingData = existingRows.first;
            final updatedData = Map<String, Object?>.from(existingData)
              ..addAll(dataMap);

            // Step 2: Update the row with the merged data
            await txn.update(
              table.tableName,
              updatedData,
              where: '${primaryKeyField.fieldName} = ?',
              whereArgs: [primaryKeyField.fieldName],
            );
          } else {
            // Step 3: Insert the item if it doesn't exist
            await txn.insert(
              table.tableName,
              dataMap,
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
          }
        }
      });
    });

    logAction('Inserted : $data to Table(${table.tableName})');
  }

  Future<int> getCount({
    List<DBFilter> filters = const [],
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
  }) async {
    String whereClause = '';

    if (filters.isNotEmpty) {
      whereClause = 'WHERE ' +
          filters
              .map((e) => e.getQuery())
              .join(' ${filterJoinType.queryOperator} ');
    }

    final List<Map<String, Object?>> data = await _db
        .rawQuery('SELECT COUNT(*) FROM ${table.tableName} $whereClause;');

    return data.first['COUNT(*)'] as int;
  }

  Future<void> delete(List<BaseDBFilter> filters) async {
    logAction('Deleting db data match($filters) in Table(${table.tableName})');
    await TunaiDBTrxnQueue().add(() async {
      await _db.transaction((txn) async {
        await txn.delete(
          table.tableName,
          where: filters.map((e) => e.getQuery()).join(' AND '),
        );
      });
    });
  }

  Future<void> deleteAll() async {
    logAction('Deleting all data in Table(${table.tableName})');
    await TunaiDBTrxnQueue().add(() async {
      await _db.transaction((txn) async {
        await txn.delete(table.tableName);
      });
    });
  }

  Future<void> update({
    required T newData,
    required List<DBFilter> filters,
  }) async {
    logAction('Update db data match($filters) in Table(${table.tableName})');
    await TunaiDBTrxnQueue().add(() async {
      await _db.transaction((txn) async {
        await txn.update(
          table.tableName,
          dbTableDataConverter.toMap(newData),
          where: filters.map((e) => e.getQuery()).join(' AND '),
        );
      });
    });
  }

  Future<List<Map<String, dynamic>>> fetchWithTables({
    List<({BaseDBFilter filter, DBTable matchedTable})> filters = const [],
    required List<DBInnerJoinTable> tableRecords,
    bool printQuery = false,
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
  }) async {
    // Validate that at least one table is provided
    if (tableRecords.isEmpty) {
      throw ArgumentError('At least one table must be provided.');
    }

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

    // Add filters if provided
    if (filters.isNotEmpty) {
      String whereClause = ' WHERE ' +
          filters.map((filterR) {
            final filter = filterR.filter;
            final matchedTable = filterR.matchedTable;
            return '${matchedTable.tableName}.${filter.getQuery()}';
          }).join(' ${filterJoinType.queryOperator} ');
      query += whereClause;
    }
    // Debug print the query if needed
    if (printQuery) {
      print('TunaiDB FetchWithTables Query :\n$query\n');
    }

    // Execute the query and return results
    List<Map<String, dynamic>> results = await _db.rawQuery(query);

    return results;
  }

  @Deprecated('Use fetchWithTables instead')
  Future<List<Map<String, dynamic>>> fetchWithInnerJoin({
    List<DBFilter> filters = const [],
    bool debugPrint = false,
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
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
              .join(' ${filterJoinType.queryOperator} ');
      // TunaiDBLogger.logAction('where clause : $whereClause');
      query += whereClause;
    }

    List<Map<String, dynamic>> results = await _db.rawQuery(query);

    return results;
  }

  Future<List<T>> fetch({
    List<BaseDBFilter> filters = const [],
    T Function(Map<String, Object?> map)? fromMap,
    DBSorter? sorter,
    int? offset,
    int? limit,
    DBFilterJoinType filterJoinType = DBFilterJoinType.and,
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
        where: filters
            .map((e) => e.getQuery())
            .join(' ${filterJoinType.queryOperator} '),
        // whereArgs: filter.matchings,
        orderBy: sorter?.getSortQuery(),
        limit: limit,
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

      logAction(
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
    try {
      final currentTime = DateTime.now();
      String query =
          'SELECT * FROM ${table.tableName} WHERE $fieldName IN (${values.map((e) => '$e').join(',')})';
      if (filters != null && filters.isNotEmpty) {
        query += ' AND ';
        query += filters
            .map((f) => '${f.getQuery()}')
            .join(' ${filterJoinType.queryOperator} ');
      }
      if (sorter != null) {
        query += ' ORDER BY ${sorter.getSortQuery()}';
      }
      List<Map<String, dynamic>> list = await _db.rawQuery(query);
      final List<T> parsedList = list.map((item) {
        try {
          return fromMap?.call(item) ?? dbTableDataConverter.fromMap(item);
        } catch (e) {
          logError('Failed to parse data from map : $e\n$item');
          rethrow;
        }
      }).toList();

      return parsedList;
    } catch (e) {
      rethrow;
    }
  }

  Future<double> getSum(String fieldName) async {
    try {
      List<Map<String, dynamic>> content =
          await _db.rawQuery('SELECT SUM($fieldName) FROM ${table.tableName}');
      double sum = content.first.values.first as double;
      return sum;
    } catch (e) {
      rethrow;
    }
  }

  Future<List<Map<String, Object?>>> rawQuery(String query) async {
    return await _db.rawQuery(query);
  }

  Future<void> _manualUpsert({
    required Transaction txn,
    required DBField primaryKeyField,
    required Map<String, Object?> dataMap,
    required Batch batch,
  }) async {
    // Step 1: Fetch the existing row if it exists
    final existingRows = await txn.query(
      table.tableName,
      where: '${primaryKeyField.fieldName} = ?',
      whereArgs: [dataMap[primaryKeyField.fieldName]],
    );

    if (existingRows.isNotEmpty) {
      // Merge the existing row with the new data
      final existingData = existingRows.first;
      final updatedData = Map<String, Object?>.from(existingData)
        ..addAll(dataMap);

      // Step 2: Update the row with the merged data
      batch.update(
        table.tableName,
        updatedData,
        where: '${primaryKeyField.fieldName} = ?',
        whereArgs: [
          updatedData[primaryKeyField.fieldName],
        ],
      );
    } else {
      // Step 3: Insert the item if it doesn't exist
      batch.insert(
        table.tableName,
        dataMap,
        conflictAlgorithm:
            ConflictAlgorithm.ignore, // Avoids duplicate insertion errors
      );
    }
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

  Future<bool> _isSqliteVersionSupportUpsert() async {
    // Get SQLite version
    var result = await _db.rawQuery('SELECT sqlite_version()');
    var sqliteVersion = result.first.values.first as String;

    // Split the version number into major, minor, patch
    var versionParts = sqliteVersion.split('.');
    var major = int.parse(versionParts[0]);
    var minor = int.parse(versionParts[1]);

    // If the SQLite version is 3.24.0 or higher, use ON CONFLICT DO UPDATE
    if (major > 3 || (major == 3 && minor >= 24)) {
      return true;
    } else {
      return false;
    }
  }
}

String _escapeSingleQuotes(String input) {
  return input.replaceAll("'", "''");
}
