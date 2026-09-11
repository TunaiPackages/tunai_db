import 'dart:io';
import 'package:synchronized/synchronized.dart';
import 'model/db_initialization_result.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:tunai_db/src/model/db_trigger.dart';
import 'package:tunai_db/src/tunai_db.dart';
import 'package:tunai_db/src/tunai_db_logger.dart';
import 'model/db_table.dart';
import 'schema/schema_reconciler.dart';
import 'schema/schema_sql.dart';

class TunaiDBInitializer {
  static final TunaiDBInitializer _instance = TunaiDBInitializer._internal();

  factory TunaiDBInitializer() {
    return _instance;
  }

  static TunaiDBLogger _logger = TunaiDBLoggerImpl();
  static TunaiDBLogger get logger => _logger;
  static bool _isSupportUpsert = false;
  static bool get isSupportUpsert => _isSupportUpsert;

  static void setLogger(TunaiDBLogger logger) {
    _logger = logger;
  }

  TunaiDBInitializer._internal();

  void setTriggers(List<DBTrigger> triggers) {
    _allTriggers = triggers;
  }

  void setTables(List<DBTable> tables) {
    _allTables = tables;
  }

  void setDBName(String name) {
    _dbName = name;
  }

  String _dbName = 'tunaiDB';
  List<DBTable> _allTables = [];
  List<DBTable> get allTables => _allTables;
  List<DBTrigger> _allTriggers = [];
  List<DBTrigger> get allTriggers => _allTriggers;

  void logging(String message) {
    debugPrint(message);
  }

  Database? _database;

  final _initializationLock = Lock();
  bool _preparing = false;

  bool get hasInit => !_preparing && (_database?.isOpen ?? false);
  Database get database {
    if (!hasInit) {
      throw StateError('Tunai Database is not initialized');
    }
    return _database!;
  }

  void initExistingDatabase(Database database) {
    _database = database;
  }

  /// Reconciles first, then rebuilds empty schema only for known incompatibility.
  /// Call with the complete registry and quiesce all database users first.
  /// Selected-table updateTables calls never rebuild the whole database.
  Future<DBInitializationResult> initDatabase(
    String uniqueKey, {
    bool resetDB = false,
    bool updateDB = true,
    bool? readOnly = false,
    bool? singleInstance = true,
  }) =>
      _initializationLock.synchronized(() async {
        _preparing = true;
        final tables = List<DBTable>.of(_allTables);
        final triggers = List<DBTrigger>.of(_allTriggers);
        try {
          await close();
          await _initDB(
            uniqueKey,
            tables: tables,
            resetDB: resetDB,
            readOnly: readOnly,
            singleInstance: singleInstance,
          );
          var result = DBInitializationResult.ready;
          if (updateDB) {
            result = await SchemaReconciler.update(
              _database!,
              tables,
              triggers: triggers,
              completeRegistry: true,
              recoverIncompatibleSchema: readOnly != true && tables.isNotEmpty,
              logRecovery: _logRecovery,
            );
          }
          _isSupportUpsert = await _isSqliteVersionSupportUpsert(_database!);
          return resetDB ? DBInitializationResult.reset : result;
        } catch (error, stack) {
          _logRecovery(
            'schema_initialization: failed; category=${error.runtimeType}',
          );
          try {
            await close();
          } catch (_) {
            _logRecovery('schema_initialization: close_failed');
          }
          Error.throwWithStackTrace(error, stack);
        } finally {
          _preparing = false;
        }
      });

  void _logRecovery(String event) {
    // A diagnostic sink must not turn committed recovery into another failure.
    try {
      _logger.logInit(event);
    } catch (_) {
      // The initialization result remains authoritative if logging is unavailable.
    }
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    _isSupportUpsert = false;
    await database?.close();
  }

  /// Manually synchronize triggers with the database
  /// This method can be called independently to update triggers
  Future<void> synchronizeTriggers() async {
    if (_database == null) {
      throw Exception('Tunai Database is not initialized');
    }
    await _synchronizeTriggers(_database!);
  }

  /// Get current triggers from the database
  Future<List<Map<String, dynamic>>> getCurrentTriggers() async {
    if (_database == null) {
      throw Exception('Tunai Database is not initialized');
    }

    try {
      List<Map<String, dynamic>> currentTriggers = await _database!.rawQuery(
        "SELECT name, tbl_name as table_name, sql FROM sqlite_master WHERE type='trigger'",
      );
      return currentTriggers;
    } catch (e) {
      _logger.logError('* TunaiDB Failed to get current triggers: $e');
      rethrow;
    }
  }

  /// Get trigger synchronization status
  Future<Map<String, dynamic>> getTriggerSyncStatus() async {
    if (_database == null) {
      throw Exception('Tunai Database is not initialized');
    }

    try {
      List<Map<String, dynamic>> currentTriggers = await getCurrentTriggers();

      // Create maps for comparison
      Map<String, Map<String, dynamic>> currentTriggersMap = {};
      for (var trigger in currentTriggers) {
        currentTriggersMap[trigger['name']] = trigger;
      }

      Map<String, DBTrigger> expectedTriggersMap = {};
      for (var trigger in _allTriggers) {
        expectedTriggersMap[trigger.name] = trigger;
      }

      // Unknown triggers are retained, never scheduled for deletion.
      final triggersToDelete = <String>[];
      final triggersToCreate = <DBTrigger>[];
      final triggersToUpdate = <DBTrigger>[];

      for (var trigger in _allTriggers) {
        if (!currentTriggersMap.containsKey(trigger.name)) {
          triggersToCreate.add(trigger);
        } else {
          var currentTrigger = currentTriggersMap[trigger.name]!;
          var currentSQL = currentTrigger['sql'] ?? '';
          var expectedSQL = trigger.toSQL().trim();

          if (normalizeTriggerSql(currentSQL) !=
              normalizeTriggerSql(expectedSQL)) {
            triggersToUpdate.add(trigger);
          }
        }
      }

      return {
        'currentTriggers': currentTriggers.length,
        'expectedTriggers': _allTriggers.length,
        'triggersToDelete': triggersToDelete,
        'triggersToCreate': triggersToCreate.map((t) => t.name).toList(),
        'triggersToUpdate': triggersToUpdate.map((t) => t.name).toList(),
        'isSynchronized': triggersToDelete.isEmpty &&
            triggersToCreate.isEmpty &&
            triggersToUpdate.isEmpty,
      };
    } catch (e) {
      _logger.logError('* TunaiDB Failed to get trigger sync status: $e');
      rethrow;
    }
  }

  Future<void> _initDB(
    String uniqueKey, {
    required List<DBTable> tables,
    bool resetDB = false,
    bool? readOnly = false,
    bool? singleInstance = true,
  }) async {
    try {
      String dbName = '${_dbName}_$uniqueKey.db';
      bool useFFI = Platform.isWindows || Platform.isAndroid;
      _logger.logInit('* TunaiDB Initializing (useFFI: $useFFI) -> $dbName...');
      String path;

      if (useFFI) {
        _logger.logInit('* TunaiDB Platform is Windows or Android, using FFI');

        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        final databasePath =
            await path_provider.getApplicationSupportDirectory();
        path = p.join(databasePath.path, dbName);
      } else if (Platform.isIOS || Platform.isMacOS) {
        final databasePath = await path_provider.getLibraryDirectory();
        path = p.join(databasePath.path, dbName);
      } else {
        final databasePath = await getDatabasesPath();
        path = p.join(databasePath, dbName);
      }

      _logger.logInit('* Found Database path -> $path');
      bool databaseExist = await databaseExists(path);

      if (!databaseExist) {
        try {
          await Directory(p.dirname(path)).create(recursive: true);
          _logger.logInit('* Created directory at $path');
        } catch (e) {
          _logger.logError('Failed to create directory at path : $path, $e');
          rethrow;
        }
      } else if (resetDB) {
        await deleteDatabase(path);
      }

      if (useFFI) {
        _database = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, version) => _onCreate(db, version, tables),
            onConfigure: _onConfigure,
            readOnly: readOnly,
            singleInstance: singleInstance,
          ),
        );
      } else {
        _database = await openDatabase(
          path,
          version: 1,
          onCreate: (db, version) => _onCreate(db, version, tables),
          onConfigure: _onConfigure,
          readOnly: readOnly,
          singleInstance: singleInstance,
        );
      }

      final result = await _database!.rawQuery('SELECT sqlite_version();');
      final sqliteVersion = result.first.values.first;
      _logger.logInit(
        '* TunaiDB successfully open database ($dbName) version : $sqliteVersion\npath: $_database\n',
      );
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
          'Warning: WAL mode not enabled. Current mode: $journalMode',
        );
      } else {
        _logger.logInit('Successfully enabled WAL mode');
      }
    } catch (e) {
      _logger.logInit('Error configuring database: $e');
      rethrow;
    }
  }

  Future<void> _onCreate(Database db, int version, List<DBTable> tables) async {
    try {
      for (var table in tables) {
        _logger.logInit(
          '* TunaiDB creating table...\n${table.createTableQuery}\n',
        );

        await db.execute(table.createTableQuery);
      }
    } catch (e) {
      _logger.logInit('* TunaiDB failed to create table $e');
      rethrow;
    }
  }

  Future<int> deleteTable(TunaiDB db) async {
    _logger.logInit('* TunaiDB deleting table ${db.table.tableName}...');
    return await _database!.delete(db.table.tableName);
  }

  /// Updates registered triggers atomically, retaining unregistered triggers.
  Future<void> _synchronizeTriggers(Database db) =>
      SchemaReconciler.update(db, const [], triggers: List.of(_allTriggers));

  /// Automatically reconciles tables without deleting unregistered schema.
  /// Existing values are preserved; an unsafe conversion rolls back the update.
  /// Call before starting workers and outside any caller-owned transaction.
  Future<void> updateTables(Database db, List<DBTable> dbTables) async {
    try {
      await SchemaReconciler.update(db, dbTables);
    } catch (error) {
      _logger.logError('TunaiDB automatic schema update failed: $error');
      rethrow;
    }
  }
}

Future<bool> _isSqliteVersionSupportUpsert(Database db) async {
  try {
    // Get SQLite version
    var result = await db.rawQuery('SELECT sqlite_version()');
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
  } catch (e) {
    TunaiDBInitializer.logger.logError(
      '* TunaiDB failed to check if SQLite version supports upsert. $e',
    );
    return false;
  }
}
