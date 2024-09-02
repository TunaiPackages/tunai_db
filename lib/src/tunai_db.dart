import 'package:sqflite/sqflite.dart';

import 'model/db_field.dart';
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

  void log(String message) {
    if (debugPrint) {
      TunaiDBInitializer.logger.logAction('${table.tableName} -> $message');
    }
  }

  void logError(String message) {
    TunaiDBInitializer.logger.logAction('${table.tableName} ! $message');
  }

  Future<void> insertList(
    List<T> list, {
    Map<String, Object?> Function(T data)? toMap,
    List<DBFilter> filters = const [],
    bool debugPrint = false,
  }) async {
    final currentTime = DateTime.now();
    final primaryKeyField = table.primaryKeyField;
    bool isSupportUpsert = await _isSqliteVersionSupportUpsert();
    log('Inserting list ${list.length}, isSupportUpsert : ${isSupportUpsert}, primaryKeyField : ${primaryKeyField.fieldName}');
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (var item in list) {
        late final dataMap;
        try {
          dataMap = toMap?.call(item) ?? dbTableDataConverter.toMap(item);
        } catch (e) {
          logError('Failed to convert data to map : $e\n$item');
        }

        if (isSupportUpsert) {
          String query = _getUpsertRawQuery(
            dataMap: dataMap,
            primaryFieldName: primaryKeyField.fieldName,
          );
          log(query);

          batch.execute(query);
        } else {
          await manualUpsert(
            txn: txn,
            primaryKeyField: primaryKeyField,
            dataMap: dataMap,
            batch: batch,
          );
        }
      }

      await batch.commit();
    });

    log('Inserted ${list.length} items to Table(${table.tableName}) took : ${DateTime.now().difference(currentTime).inMilliseconds} ms');
  }

  Future<void> insertJsons(List<Map<String, dynamic>> list) async {
    final currentTime = DateTime.now();
    final primaryKeyField = table.primaryKeyField;

    bool isSupportUpsert = await _isSqliteVersionSupportUpsert();
    log('Inserting jsons ${list.length}, isSupportUpsert : ${isSupportUpsert}, primaryKeyField : ${primaryKeyField.fieldName}');

    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (var item in list) {
        if (isSupportUpsert) {
          String query = _getUpsertRawQuery(
            dataMap: item,
            primaryFieldName: primaryKeyField.fieldName,
          );
          log('Upsert json query : \n$query');

          batch.execute(query);
        } else {
          await manualUpsert(
            txn: txn,
            primaryKeyField: primaryKeyField,
            dataMap: item,
            batch: batch,
          );
        }
      }

      await batch.commit();
    });

    log('Inserted ${list.length} items to Table(${table.tableName}) took : ${DateTime.now().difference(currentTime).inMilliseconds} ms');
  }

  Future<void> insert(
    T data, {
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
    Map<String, Object?> Function(T data)? toMap,
  }) async {
    if (debugPrint) {
      TunaiDBInitializer.logger
          .logAction('Inserting : $data to Table(${table.tableName})');
    }
    final primaryKeyField = table.primaryKeyField;
    bool isSupportUpsert = await _isSqliteVersionSupportUpsert();
    final dataMap = toMap?.call(data) ?? dbTableDataConverter.toMap(data);
    if (isSupportUpsert) {
      await _db.rawQuery(_getUpsertRawQuery(
        dataMap: dataMap,
        primaryFieldName: primaryKeyField.fieldName,
      ));
    } else {
      // Step 1: Fetch the existing row if it exists
      final existingRows = await _db.query(
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
        await _db.update(
          table.tableName,
          updatedData,
          where: '${primaryKeyField.fieldName} = ?',
          whereArgs: [primaryKeyField.fieldName],
        );
      } else {
        // Step 3: Insert the item if it doesn't exist
        await _db.insert(
          table.tableName,
          dataMap,
          conflictAlgorithm:
              ConflictAlgorithm.ignore, // Avoids duplicate insertion errors
        );
      }
    }
  }

  Future<int> getCount() async {
    final List<Map<String, Object?>> data =
        await _db.rawQuery('SELECT COUNT(*) FROM ${table.tableName};');
    return data.first['COUNT(*)'] as int;
  }

  Future<void> delete(List<DBFilter> filters) async {
    if (debugPrint) {
      TunaiDBInitializer.logger.logAction(
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
      TunaiDBInitializer.logger.logAction(
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
      TunaiDBInitializer.logger
          .logAction('innerJoin fetch ${table.tableName} -> $query');
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
    try {
      final List<T> parsedList = list.map((item) {
        try {
          return fromMap?.call(item) ?? dbTableDataConverter.fromMap(item);
        } catch (e) {
          logError('Failed to parse data from map : $e\n$item');
          rethrow;
        }
      }).toList();

      if (debugPrint) {
        TunaiDBInitializer.logger.logAction(
          'Fetched from db (${table.tableName}) ${parsedList.length} items took : ${DateTime.now().difference(currentTime).inMilliseconds} ms',
        );
      }

      return parsedList;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> manualUpsert({
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
        whereArgs: [primaryKeyField.fieldName],
      );
      log('Merged Rows : $updatedData');
    } else {
      // Step 3: Insert the item if it doesn't exist
      batch.insert(
        table.tableName,
        dataMap,
        conflictAlgorithm:
            ConflictAlgorithm.ignore, // Avoids duplicate insertion errors
      );

      log('Insert Rows : $dataMap');
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
