import 'dart:io';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart' as pathP;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:tunai_db/src/model/db_field.dart';
import 'package:tunai_db/src/tunai_db.dart';
import 'package:tunai_db/src/tunai_db_logger.dart';
import 'model/db_table.dart';

class TunaiDBInitializer {
  static final TunaiDBInitializer _instance = TunaiDBInitializer._internal();

  factory TunaiDBInitializer() {
    return _instance;
  }

  static TunaiDBLogger _logger = TunaiDBLoggerImpl();
  static TunaiDBLogger get logger => _logger;

  static void setLogger(TunaiDBLogger logger) {
    _logger = logger;
  }

  TunaiDBInitializer._internal();

  void setTables(List<DBTable> tables) {
    _allTables = tables;
  }

  void setDBName(String name) {
    _dbName = name;
  }

  String _dbName = 'tunaiDB';
  List<DBTable> _allTables = [];

  List<DBTable> get allTables => _allTables;

  void logging(String message) {
    debugPrint(message);
  }

  Database? _database;

  bool get hasInit => _database != null;
  Database get database {
    if (_database == null) {
      throw Exception('Tunai Database is not initialized');
    }
    return _database!;
  }

  void initExistingDatabase(Database database) {
    _database = database;
  }

  Future<void> initDatabase(
    String uniqueKey, {
    bool resetDB = false,
    bool updateDB = true,
  }) async {
    //updated
    try {
      await _initDB(uniqueKey, resetDB: resetDB);
      if (updateDB) {
        await updateTables(_database!, _allTables);
      }
    } catch (e) {
      _logger.logInit('TunaiDB Failed to initialize. $e');
      rethrow;
    }
  }

  Future<void> _initDB(String uniqueKey, {bool resetDB = false}) async {
    try {
      String dbName = '${_dbName}_$uniqueKey.db';
      _logger.logInit('* TunaiDB Initializing -> $dbName...');
      String path;
      if (Platform.isWindows) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        final databasePath = await pathP.getApplicationSupportDirectory();
        path = p.join(databasePath.path, dbName);
      } else if (Platform.isIOS || Platform.isMacOS) {
        final databasePath = await pathP.getLibraryDirectory();
        path = p.join(databasePath.path, dbName);
      } else {
        final databasePath = await getDatabasesPath();
        path = p.join(databasePath, dbName);
      }

      _logger.logInit('* Found Database path -> $path');
      bool databaseExist = await databaseExists(path);

      if (!databaseExist) {
        // Make sure the directory exists

        try {
          await Directory(path).create(recursive: true);
          print('* Created directory at $path');
          // await File(path).writeAsString('flushing', flush: true);
          // print('* Flushed directory at $path');
        } catch (e) {
          print('Failed to create directory at path : $path, $e');
          rethrow;
        }

        try {
          await deleteDatabase(path);
        } catch (e) {
          print('Failed to delete database at path : $path, $e');
        }
      } else if (resetDB) {
        try {
          await deleteDatabase(path);
        } catch (e) {
          print('Failed to delete database at path : $path, $e');
        }
      }

      if (Platform.isWindows) {
        _database = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: _onCreate,
            onConfigure: _onConfigure,
          ),
        );
      } else {
        _database = await openDatabase(
          path,
          version: 1,
          onCreate: _onCreate,
          onConfigure: _onConfigure,
        );
      }

      final result = await database.rawQuery('SELECT sqlite_version();');
      final sqliteVersion = result.first.values.first;
      _logger.logInit(
          '* TunaiDB successfully open database ($dbName) version : $sqliteVersion\npath: $_database\n');
    } catch (e) {
      _logger.logInit('* TunaiDB failed to open database : $e');
      rethrow;
    }
  }

  Future<void> _onConfigure(Database database) async {
    try {
      if (Platform.isIOS || Platform.isMacOS) {
        // On iOS/macOS, we need to handle the "not an error" message
        try {
          await database.execute('PRAGMA journal_mode=WAL;');
        } catch (e) {
          if (!e.toString().contains('not an error')) {
            rethrow;
          }
        }
      } else {
        // For Android and other platforms, use rawQuery instead of execute
        await database.rawQuery('PRAGMA journal_mode=WAL;');
      }

      // Additional PRAGMA settings - use rawQuery for all platforms
      try {
        await database.rawQuery('PRAGMA synchronous=NORMAL;');
        await database.rawQuery('PRAGMA temp_store=MEMORY;');
        await database.rawQuery('PRAGMA cache_size=2000;');
      } catch (e) {
        _logger.logInit('Warning: Failed to set some PRAGMA values: $e');
      }

      // Verify WAL mode
      final result = await database.rawQuery('PRAGMA journal_mode;');
      final journalMode = result.first.values.first.toString().toUpperCase();
      if (journalMode != 'WAL') {
        _logger.logInit(
            'Warning: WAL mode not enabled. Current mode: $journalMode');
      } else {
        _logger.logInit('Successfully enabled WAL mode');
      }
    } catch (e) {
      _logger.logInit('Error configuring database: $e');
      rethrow;
    }
  }

  // Future<void> _onUpgrade({
  //   required Database db,
  //   required int oldVersion,
  //   required int newVersion,
  //   required String uniqueKey,
  // }) async {
  //   TunaiDBLogger.logInit(
  //       '* Sqlite db upgrading from $oldVersion to $newVersion...');
  //   // await db.close();
  //   // await deleteDatabase(db.path);
  //   // await _initDB(uniqueKey);
  // }

  Future<void> _onCreate(Database db, int version) async {
    try {
      for (var table in _allTables) {
        _logger.logInit(
          '* TunaiDB creating table...\n${table.createTableQuery}\n',
        );

        await db.execute(table.createTableQuery);
        if (table.createIndexQuery.isNotEmpty) {
          _logger.logInit(
            '* TunaiDB creating table index...\n${table.createIndexQuery}\n',
          );
          await db.execute(table.createIndexQuery);
        }
      }
    } catch (e) {
      _logger.logInit('* TunaiDB failed to create table $e');
      rethrow;
    }
  }

  Future<int> deleteTable(TunaiDB db) async {
    _logger.logInit(
      '* TunaiDB deleting table ${db.table.tableName}...',
    );
    return await _database!.delete(db.table.tableName);
  }

  Future<void> updateTables(Database db, List<DBTable> dbTables) async {
    _logger.logInit('* TunaiDB checking for tables\'s updates...');

    try {
      List<Map<String, dynamic>> tables = await db
          .rawQuery("SELECT name FROM sqlite_master WHERE type='table'");

      await addMissingTable(
        db: db,
        dbTables: dbTables,
        currentTables: tables,
      );

      await dropExtraTable(
        db: db,
        dbTables: dbTables,
        currentTables: tables,
      );

      // TunaiDBLogger.logInit(tables);

      for (var table in tables) {
        DBTable? dbTable =
            dbTables.firstWhereOrNull((t) => t.tableName == table['name']);

        if (dbTable == null) {
          continue;
        }

        await updateIndexes(
          db: db,
          table: dbTable,
        );

        // TunaiDBLogger.logInit('* -> Checking columns for table ${table['name']}...');
        List<Map<String, dynamic>> columns =
            await db.rawQuery("PRAGMA table_info('${table['name']}')");

        for (var column in columns) {
          DBField? dbField = dbTable.fields.firstWhereOrNull(
            (field) => field.fieldName == column['name'],
          );

          if (dbField == null) {
            TunaiDBInitializer.logger.logInit(
                '* -> Dropping column ${column['name']} from table ${dbTable.tableName}...');
            db.execute(
                "ALTER TABLE ${dbTable.tableName} DROP COLUMN ${column['name']}");
          } else {
            bool fieldUpdated =
                (dbField.isPrimaryKey ? 1 : 0) != column['pk'] ||
                    dbField.fieldType.query != column['type'];
            if (fieldUpdated) {
              TunaiDBInitializer.logger.logInit(
                  '* -> Updating column ${column['name']} in table ${dbTable.tableName}...');
              db.execute(
                  "ALTER TABLE ${dbTable.tableName} RENAME TO ${dbTable.tableName}_old");
              db.execute(dbTable.createTableQuery);
              db.execute(
                  "INSERT INTO ${dbTable.tableName} SELECT * FROM ${dbTable.tableName}_old");
              db.execute("DROP TABLE ${dbTable.tableName}_old");
            }
          }
        }

        await addMissingColumns(
          db: db,
          table: dbTable,
          columns: columns,
        );

        // dropExtraColumns(
        //   db: db,
        //   table: dbTable,
        //   columns: columns,
        // );
      }
    } catch (e) {
      _logger.logInit('* TunaiDB failed to update tables. $e');
      rethrow;
    }
  }
}

Future<void> updateIndexes({
  required Database db,
  required DBTable table,
}) async {
  final List<Map<String, Object?>> currentIndexes = await db.rawQuery("""
SELECT name
FROM sqlite_master
WHERE type = 'index' AND tbl_name = '${table.tableName}';
""");

  for (var currentIndex in currentIndexes) {
    bool isAutoGenerated =
        (currentIndex['name'] as String).contains('sqlite_autoindex');
    if (isAutoGenerated) continue;

    bool keepIndex = table.indexingFields.any((f) =>
        '${table.tableName}_${f.fieldName}_index' == currentIndex['name']);

    if (!keepIndex) {
      TunaiDBInitializer.logger.logInit(
          '* -> Dropping index ${currentIndex['name']} from table ${table.tableName}...');
      await db.execute('DROP INDEX ${currentIndex['name']}');
    }
  }

  for (var indexing in table.indexingFields) {
    final currentIndex = currentIndexes.firstWhereOrNull((element) =>
        element['name'] == '${table.tableName}_${indexing.fieldName}_index');

    if (currentIndex == null) {
      TunaiDBInitializer.logger.logInit(
          '* -> Creating index for ${indexing.fieldName} in table ${table.tableName}...');
      await db.execute('''
CREATE INDEX ${table.tableName}_${indexing.fieldName}_index
ON ${table.tableName} (${indexing.fieldName});
''');
    } else {
      // TunaiDBInitializer.logger.logInit(
      //     '* -> Index for ${indexing.fieldName} in table ${dbTable.tableName} already exists...');
    }
  }
}

Future<void> addMissingTable({
  required Database db,
  required List<DBTable> dbTables,
  required List<Map<String, dynamic>> currentTables,
}) async {
  List<DBTable> missingTables = dbTables
      .where((table) => !currentTables.any((t) => t['name'] == table.tableName))
      .toList();

  if (missingTables.isNotEmpty) {
    TunaiDBInitializer.logger.logInit(
        '* -> Adding missing tables...\n${missingTables.map((table) => table.tableName).join('\n')}');
    List<Future> listFuture = [];
    for (var table in missingTables) {
      listFuture.add(db.execute(table.createTableQuery));
    }
    await Future.wait(listFuture);
  }
}

Future<void> dropExtraTable({
  required Database db,
  required List<DBTable> dbTables,
  required List<Map<String, dynamic>> currentTables,
}) async {
  List<Map<String, dynamic>> extraTables = currentTables
      .where((t) => !dbTables.any((table) => table.tableName == t['name']))
      .toList();

  if (extraTables.isNotEmpty) {
    TunaiDBInitializer.logger.logInit(
        '* -> Dropping extra tables...\n${extraTables.map((table) => table['name']).join('\n')}');
    List<Future> listFuture = [];
    for (var table in extraTables) {
      listFuture.add(db.execute('DROP TABLE ${table['name']}'));
    }
    await Future.wait(listFuture);
  }
}

Future<void> addMissingColumns({
  required Database db,
  required DBTable table,
  required List<Map<String, dynamic>> columns,
}) async {
  List<DBField> missingColumns = table.fields.where((field) {
    return !columns.any((column) => column['name'] == field.fieldName);
  }).toList();
  if (missingColumns
      .any((element) => element.isPrimaryKey || element.reference != null)) {
    TunaiDBInitializer.logger.logInit(
        '* -> Missing Columns contain primary or foreign key, rebuilding table ${table.tableName}...');
    await rebuildTable(db: db, table: table, columns: columns);
  } else if (missingColumns.isNotEmpty) {
    TunaiDBInitializer.logger.logInit(
        '* -> Adding missing columns to table ${table.tableName}...\n${missingColumns.map((field) => field.fieldQuery).join('\n')}');
    List<Future> listFuture = [];
    for (var field in missingColumns) {
      listFuture.add(db.execute(
          'ALTER TABLE ${table.tableName} ADD COLUMN ${field.fieldQuery}'));
    }

    await Future.wait(listFuture);
  }
}

Future<void> rebuildTable({
  required Database db,
  required DBTable table,
  required List<Map<String, dynamic>> columns,
}) async {
  String oldTableName = "old_${table.tableName}";

  await db.execute('''
ALTER TABLE ${table.tableName} RENAME TO $oldTableName;
''');

  await db.execute(table.createTableQuery);

  // await db.execute('''
  //     INSERT INTO $newTableName (shopID, outletID, hourID, enabled)
  //     SELECT shopID, outletID, hourID, enabled FROM $tableName
  //   ''');

  await db.execute('DROP TABLE $oldTableName');
}

Future<void> dropExtraColumns({
  required Database db,
  required DBTable table,
  required List<Map<String, dynamic>> columns,
}) async {
  List<Map<String, dynamic>> droppingColumns = columns.where((column) {
    return !table.fields.any((field) => field.fieldName == column['name']);
  }).toList();
  if (droppingColumns.any((element) {
    DBField? field = table.fields
        .firstWhereOrNull((field) => field.fieldName == element['name']);
    if (field == null) {
      return false;
    }
    return field.isPrimaryKey || field.reference != null;
  })) {
    TunaiDBInitializer.logger.logInit(
        '* -> Dropping Columns contain primary or foreign key, rebuilding table ${table.tableName}...');
    await rebuildTable(db: db, table: table, columns: columns);
  } else if (droppingColumns.isNotEmpty) {
    List<Future> listFuture = [];
    for (Map<String, dynamic> column in droppingColumns) {
      TunaiDBInitializer.logger.logInit(
          '* -> Dropping column ${column['name']} from table ${table.tableName}...');
      listFuture.add(db.execute(
          "ALTER TABLE ${table.tableName} DROP COLUMN ${column['name']}"));
    }
    await Future.wait(listFuture);
  }
}
