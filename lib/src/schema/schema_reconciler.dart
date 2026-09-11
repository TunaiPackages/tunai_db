import 'dart:convert';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:synchronized/synchronized.dart';

import '../model/db_table.dart';
import '../model/db_trigger.dart';
import 'schema_sql.dart';
import 'stored_value_migration.dart';
import '../model/db_initialization_result.dart';

/// A physical legacy schema cannot be reconciled without losing data.
class SchemaIncompatibility extends StateError {
  SchemaIncompatibility(super.message, {required this.reason});
  final String reason;
}

class _TableFailure {
  _TableFailure(this.failure, this.tables);
  final Object failure;
  final Set<String> tables;
}

/// Automatic, data-preserving reconciliation of the registered schema.
/// Call outside transactions, before exposing this connection to app workers.
abstract final class SchemaReconciler {
  static final _lock = Lock();

  static Future<DBInitializationResult> update(
    Database db,
    List<DBTable> tables, {
    List<DBTrigger> triggers = const [],
    bool recoverIncompatibleSchema = false,
    bool completeRegistry = false,
    void Function(String)? logRecovery,
    void Function(Set<String>)? onTablesRebuilt,
  }) {
    recoverIncompatibleSchema = recoverIncompatibleSchema && completeRegistry;
    final selectedTables = List<DBTable>.of(tables);
    final selectedTriggers = List<DBTrigger>.of(triggers);
    return _lock.synchronized(() async {
      final foreignKeys =
          Sqflite.firstIntValue(await db.rawQuery('PRAGMA foreign_keys')) == 1;
      final legacyAlter = Sqflite.firstIntValue(
            await db.rawQuery('PRAGMA legacy_alter_table'),
          ) ==
          1;
      // SQLite requires this outside the transaction. The SQL transaction then
      // serializes schema writers across handles/processes; this lock also
      // protects connection-level PRAGMAs within this isolate.
      if (foreignKeys) await db.execute('PRAGMA foreign_keys = OFF');
      var result = DBInitializationResult.ready;
      final migrations = <StoredValueMigration>[];
      final resetTables = <String>{};
      try {
        await db.execute('PRAGMA legacy_alter_table = ON');
        Future<void> reconcile(Transaction tx) async {
          if (selectedTables
                  .map((t) => t.tableName.toLowerCase())
                  .toSet()
                  .length !=
              selectedTables.length) {
            throw StateError('Duplicate registered table names');
          }
          final protectedColumns = <String, Set<String>>{};
          void protect(String table, String column) => protectedColumns
              .putIfAbsent(table.toLowerCase(), () => <String>{})
              .add(column.toLowerCase());
          if (completeRegistry) {
            final existingTables =
                await tx.query('sqlite_master', where: "type='table'");
            for (final table in existingTables) {
              for (final fk in await tx.rawQuery(
                  'PRAGMA foreign_key_list(${quoteIdentifier(table['name']! as String)})')) {
                protect(table['name']! as String, fk['from']! as String);
                if (fk['to'] != null) {
                  protect(fk['table']! as String, fk['to']! as String);
                }
              }
            }
            for (final table in selectedTables) {
              if (table.fields.isEmpty ||
                  table.fields
                          .map((f) => f.fieldName.toLowerCase())
                          .toSet()
                          .length !=
                      table.fields.length) {
                throw ArgumentError('Invalid registered fields');
              }
              for (final field in table.foreignFields) {
                final reference = field.reference!;
                protect(table.tableName, field.fieldName);
                protect(reference.table.tableName, reference.fieldName);
                final parents = selectedTables
                    .where((t) => t.tableName == reference.table.tableName);
                if (parents.isEmpty ||
                    !parents.single.fields.any((f) =>
                        f.fieldName == reference.fieldName && f.isPrimaryKey)) {
                  throw ArgumentError(
                      'Foreign key must reference a registered primary key');
                }
              }
            }
            if (selectedTriggers.any((t) =>
                !selectedTables.any((table) => table.tableName == t.table))) {
              throw ArgumentError('Trigger must target a registered table');
            }
            await _removeUndeclaredObjects(
                tx, selectedTables, selectedTriggers);
          }
          for (final table in selectedTables) {
            try {
              await _updateTable(tx, table,
                  classifyCopyFailure: recoverIncompatibleSchema,
                  matchModel: completeRegistry,
                  protectedColumns:
                      protectedColumns[table.tableName.toLowerCase()] ??
                          const {},
                  migrations: migrations);
            } catch (failure) {
              if (!recoverIncompatibleSchema ||
                  !_canAttemptReplacement(failure)) {
                rethrow;
              }
              throw _TableFailure(failure, {table.tableName.toLowerCase()});
            }
          }
          for (final trigger in selectedTriggers) {
            final existing = await tx.query(
              'sqlite_master',
              columns: ['sql'],
              where: 'type = ? AND name = ?',
              whereArgs: ['trigger', trigger.name],
            );
            // Preserve case inside string literals when comparing trigger bodies.
            if (existing.isNotEmpty &&
                normalizeTriggerSql(existing.first['sql']! as String) ==
                    normalizeTriggerSql(trigger.toSQL())) {
              continue;
            }
            await tx.execute(
              'DROP TRIGGER IF EXISTS ${quoteIdentifier(trigger.name)}',
            );
            await tx.execute(trigger.toSQL());
          }
          if (foreignKeys || completeRegistry) {
            final violations = await tx.rawQuery('PRAGMA foreign_key_check');
            if (violations.isNotEmpty) {
              final failure = SchemaIncompatibility(
                'Automatic schema update would leave foreign-key violations',
                reason: 'foreign_key_violation',
              );
              if (recoverIncompatibleSchema) {
                throw _TableFailure(failure, {
                  for (final row in violations)
                    (row['table']! as String).toLowerCase(),
                });
              }
              throw failure;
            }
          }
        }

        await db.transaction((tx) async {
          if (!recoverIncompatibleSchema) {
            await reconcile(tx);
            return;
          }
          // Reject invalid declarations before considering legacy recovery.
          if (selectedTables
                      .map((t) => t.tableName.toLowerCase())
                      .toSet()
                      .length !=
                  selectedTables.length ||
              selectedTables.any((t) =>
                  t.fields.isEmpty ||
                  t.fields
                          .map((f) => f.fieldName.toLowerCase())
                          .toSet()
                          .length !=
                      t.fields.length) ||
              selectedTriggers
                      .map((t) => t.name.toLowerCase())
                      .toSet()
                      .length !=
                  selectedTriggers.length) {
            throw ArgumentError(
                'Invalid or duplicate registered schema declarations');
          }
          // Keep the writer lock across rollback and replacement. No other
          // handle can insert data between deciding recovery and rebuilding.
          await tx.execute('SAVEPOINT tunai_schema_update');
          while (true) {
            try {
              // Every retry starts from the original schema and data. Drop the
              // full dependent closure before migrating any retained table.
              for (final name in resetTables) {
                await tx
                    .execute('DROP TABLE IF EXISTS ${quoteIdentifier(name)}');
              }
              await reconcile(tx);
              if (resetTables.isNotEmpty) {
                await _verifyReplacement(tx);
                result = DBInitializationResult.tablesRebuilt;
              }
              break;
            } catch (caught) {
              final failure = caught is _TableFailure ? caught.failure : caught;
              if (!_canAttemptReplacement(failure)) rethrow;
              await tx.execute('ROLLBACK TO tunai_schema_update');
              migrations.clear();
              final reason = failure is SchemaIncompatibility
                  ? failure.reason
                  : 'legacy_schema_failure';
              if (caught is _TableFailure && completeRegistry) {
                final closure = await _dependentTables(
                    tx, selectedTables, {...resetTables, ...caught.tables});
                if (closure.length > resetTables.length) {
                  resetTables.addAll(closure);
                  logRecovery?.call(
                      'schema_recovery: $reason; rebuilding_tables=${(resetTables.toList()..sort()).join(',')}');
                  continue;
                }
              }
              // No bounded table repair can recover this failure. The full
              // replacement still shares the transaction and rolls back on error.
              logRecovery?.call('schema_recovery: $reason; rebuilding');
              final objects = await tx.query('sqlite_master',
                  columns: ['type', 'name'],
                  where: "type IN ('trigger', 'view', 'table')");
              for (final type in ['trigger', 'view', 'table']) {
                for (final object in objects.where((o) => o['type'] == type)) {
                  final name = object['name']! as String;
                  if (name.startsWith('sqlite_')) continue;
                  await tx.execute(
                      'DROP ${type.toUpperCase()} IF EXISTS ${quoteIdentifier(name)}');
                }
              }
              await reconcile(tx);
              await _verifyReplacement(tx);
              resetTables.clear();
              result = DBInitializationResult.rebuilt;
              break;
            }
          }
          await tx.execute('RELEASE tunai_schema_update');
        }, exclusive: true);
        for (final migration in migrations) {
          if (migration.converted + migration.defaulted + migration.nulled >
              0) {
            logRecovery?.call(
                'schema_migration: committed; converted=${migration.converted}; defaulted=${migration.defaulted}; nulled=${migration.nulled}');
          }
        }
        if (result == DBInitializationResult.tablesRebuilt) {
          logRecovery?.call('schema_recovery: tables_replacement_committed');
        }
        if (result == DBInitializationResult.rebuilt) {
          logRecovery?.call('schema_recovery: replacement_committed');
        }
      } on _TableFailure catch (failure, stack) {
        Error.throwWithStackTrace(failure.failure, stack);
      } finally {
        try {
          await db.execute(
            'PRAGMA legacy_alter_table = ${legacyAlter ? 'ON' : 'OFF'}',
          );
        } finally {
          if (foreignKeys) await db.execute('PRAGMA foreign_keys = ON');
        }
      }
      if (result == DBInitializationResult.rebuilt) {
        logRecovery?.call('schema_recovery: rebuilt_empty_database');
      }
      if (result == DBInitializationResult.tablesRebuilt) {
        final names = selectedTables
            .where((t) => resetTables.contains(t.tableName.toLowerCase()))
            .map((t) => t.tableName)
            .toSet();
        onTablesRebuilt?.call(Set.unmodifiable(names));
        logRecovery?.call(
            'schema_recovery: rebuilt_empty_tables=${(names.toList()..sort()).join(',')}');
      }
      return result;
    });
  }

  static Future<void> _verifyReplacement(Transaction tx) async {
    if ((await tx.rawQuery('PRAGMA quick_check'))
            .any((r) => r.values.single != 'ok') ||
        (await tx.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
      throw StateError('Replacement schema verification failed');
    }
  }

  // Union of old and target FK edges, including transitive/cyclic dependents.
  // Parents and unrelated tables retain their data. Undeclared children are
  // already scheduled for removal by full reconciliation.
  static Future<Set<String>> _dependentTables(
      Transaction tx, List<DBTable> tables, Set<String> roots) async {
    final registered = {for (final t in tables) t.tableName.toLowerCase()};
    final children = <String, Set<String>>{};
    void edge(String parent, String child) => children
        .putIfAbsent(parent.toLowerCase(), () => <String>{})
        .add(child.toLowerCase());
    for (final row in await tx.query('sqlite_master', where: "type='table'")) {
      final name = row['name']! as String;
      for (final fk in await tx
          .rawQuery('PRAGMA foreign_key_list(${quoteIdentifier(name)})')) {
        edge(fk['table']! as String, name);
      }
    }
    for (final table in tables) {
      for (final field in table.foreignFields) {
        edge(field.reference!.table.tableName, table.tableName);
      }
    }
    final result = roots.where(registered.contains).toSet();
    final pending = result.toList();
    while (pending.isNotEmpty) {
      for (final child in children[pending.removeLast()] ?? const <String>{}) {
        if (registered.contains(child) && result.add(child)) pending.add(child);
      }
    }
    return result;
  }

  // Classify the failure of reconciliation, not opening/commit/PRAGMA cleanup.
  // SQLite ERROR covers legacy SQL shapes (e.g. a view occupying a table name).
  // The replacement must still validate and commit, otherwise all data remains.
  static bool _canAttemptReplacement(Object failure) {
    if (failure is DatabaseException) {
      final code = failure.getResultCode();
      return code != null && const {1, 17, 19, 20}.contains(code & 0xff);
    }
    return failure is StateError ||
        failure is FormatException ||
        failure is RangeError ||
        failure is UnsupportedError;
  }

  // Only full initialization owns the database-wide registry. Partial repairs
  // cannot infer that objects outside their selection have been removed.
  static Future<void> _removeUndeclaredObjects(
      Transaction tx, List<DBTable> tables, List<DBTrigger> triggers) async {
    final names = tables.map((t) => t.tableName.toLowerCase()).toSet();
    final objects = await tx.query('sqlite_master',
        where: "type IN ('trigger', 'view', 'index', 'table')");
    for (final type in ['trigger', 'view', 'index', 'table']) {
      for (final object in objects.where((o) => o['type'] == type)) {
        final name = object['name']! as String;
        if (name.toLowerCase().startsWith('sqlite_')) continue;
        if (type == 'table' && names.contains(name.toLowerCase())) continue;
        if (type == 'trigger' &&
            triggers.any((t) =>
                t.name == name &&
                normalizeTriggerSql(t.toSQL()) ==
                    normalizeTriggerSql(object['sql']! as String))) {
          continue;
        }
        if (type == 'index') {
          final owners = tables.where((t) => t.tableName == object['tbl_name']);
          if (owners.isNotEmpty) {
            final fields = owners.single.indexingFields.where((f) =>
                '${owners.single.tableName}_${f.fieldName}_index' == name);
            if (fields.isNotEmpty) {
              final details = await tx.rawQuery(
                  'PRAGMA index_list(${quoteIdentifier(owners.single.tableName)})');
              final info = await tx
                  .rawQuery('PRAGMA index_xinfo(${quoteIdentifier(name)})');
              final keys = info.where((c) => c['key'] == 1).toList();
              final index = details.singleWhere((i) => i['name'] == name);
              if (index['unique'] == 0 &&
                  index['partial'] == 0 &&
                  keys.length == 1 &&
                  keys.single['name'] == fields.single.fieldName &&
                  keys.single['desc'] == 0 &&
                  keys.single['coll'] == 'BINARY') {
                continue;
              }
            }
          }
        }
        await tx.execute(
            'DROP ${type.toUpperCase()} IF EXISTS ${quoteIdentifier(name)}');
      }
    }
  }

  // Unknown PRAGMAs return no rows on older SQLite (including Android).
  // table_xinfo arrived in 3.26.0; table_info covers ordinary columns there.
  // Keep xinfo on newer engines so generated/hidden columns remain visible.
  static Future<List<Map<String, Object?>>> _tableColumns(
      Transaction tx, String name) async {
    final columns =
        await tx.rawQuery('PRAGMA table_xinfo(${quoteIdentifier(name)})');
    if (columns.isNotEmpty) return columns;
    return [
      for (final column
          in await tx.rawQuery('PRAGMA table_info(${quoteIdentifier(name)})'))
        {...column, 'hidden': 0},
    ];
  }

  static Future<void> _matchTable(Transaction tx, DBTable table, String sql,
      {required bool classifyCopyFailure,
      required Set<String> protectedColumns,
      required List<StoredValueMigration> migrations}) async {
    final current = TableDefinition(sql);
    final target = TableDefinition(table.createTableQuery);
    String signature(TableDefinition d) =>
        normalizeTriggerSql('${d.parts.join(',')} ${d.suffix}');
    if (signature(current) == signature(target)) return;
    final columns = await _tableColumns(tx, table.tableName);
    final retained = table.fields.map((f) => f.fieldName.toLowerCase()).toSet();
    final hasRows = (await tx.rawQuery(
            'SELECT 1 FROM ${quoteIdentifier(table.tableName)} LIMIT 1'))
        .isNotEmpty;
    for (final field in table.fields.where((f) => f.isPrimaryKey)) {
      final old = columns.where((c) =>
          (c['name']! as String).toLowerCase() ==
          field.fieldName.toLowerCase());
      if (hasRows && (old.isEmpty || old.single['pk'] != 1)) {
        throw SchemaIncompatibility('Cannot infer a new primary key',
            reason: 'key_change');
      }
    }
    for (final column in columns.where((c) => (c['pk']! as int) > 0)) {
      if (hasRows &&
          !table.fields.any((f) =>
              f.fieldName.toLowerCase() ==
                  (column['name']! as String).toLowerCase() &&
              f.isPrimaryKey)) {
        throw SchemaIncompatibility('Cannot infer a changed primary key',
            reason: 'key_change');
      }
    }
    final migration = StoredValueMigration({
      for (final field in table.fields)
        for (final column in columns)
          if ((column['name']! as String).toLowerCase() ==
                  field.fieldName.toLowerCase() &&
              (column['type']! as String).toUpperCase() !=
                  field.fieldType.query &&
              column['pk'] == 0 &&
              !field.isPrimaryKey &&
              field.reference == null &&
              !protectedColumns.contains(field.fieldName.toLowerCase()))
            column['name']! as String: field,
    });
    migrations.add(migration);
    await _rebuild(tx, table.tableName, target, columns,
        migration: migration,
        classifyCopyFailure: classifyCopyFailure,
        retainedColumns: retained,
        sourceWithoutRowid:
            current.suffix.toUpperCase().contains('WITHOUT ROWID'));
  }

  static Future<void> _updateTable(Transaction tx, DBTable table,
      {bool classifyCopyFailure = false,
      bool matchModel = false,
      Set<String> protectedColumns = const {},
      List<StoredValueMigration>? migrations}) async {
    if (table.fields.isEmpty ||
        table.fields.map((f) => f.fieldName.toLowerCase()).toSet().length !=
            table.fields.length) {
      throw StateError(
        'Table ${table.tableName} has empty or duplicate fields',
      );
    }
    final existing = await tx.query(
      'sqlite_master',
      columns: ['sql'],
      where: 'type = ? AND name = ? COLLATE NOCASE',
      whereArgs: ['table', table.tableName],
    );
    if (existing.isEmpty) {
      await tx.execute(table.createTableQuery);
    } else if (matchModel) {
      await _matchTable(tx, table, existing.single['sql']! as String,
          classifyCopyFailure: classifyCopyFailure,
          protectedColumns: protectedColumns,
          migrations: migrations!);
    } else {
      final sql = existing.single['sql']! as String;
      final definition = TableDefinition(sql);
      final columns = await _tableColumns(tx, table.tableName);
      final byName = {for (final c in columns) c['name'] as String: c};
      final foreignKeys = await tx.rawQuery(
        'PRAGMA foreign_key_list(${quoteIdentifier(table.tableName)})',
      );
      var rebuild = false;
      final missing = <String>[];
      for (final field in table.fields) {
        final column = byName[field.fieldName];
        if (column == null) {
          if (field.isPrimaryKey || field.reference != null) {
            throw SchemaIncompatibility(
              'Cannot infer identity or relationship for new key ${table.tableName}.${field.fieldName}',
              reason: 'new_key',
            );
          }
          missing.add(field.fieldQuery);
          // ADD COLUMN forbids NOT NULL without DEFAULT even on an empty table.
          // A rebuild supports that case; populated tables fail without data loss.
          if (field.isNotNull && field.defaultValue == null) rebuild = true;
          continue;
        }
        final partIndex = definition.parts.indexWhere(
          (p) => columnName(p) == field.fieldName,
        );
        if (partIndex < 0) {
          throw StateError(
            'Cannot locate ${table.tableName}.${field.fieldName} in CREATE SQL',
          );
        }
        final part = definition.parts[partIndex];
        final reference = field.reference;
        final actualReferences =
            foreignKeys.where((fk) => fk['from'] == field.fieldName).toList();
        final referenceMatches = reference == null
            ? actualReferences.isEmpty
            : actualReferences.length == 1 &&
                actualReferences.single['table'] == reference.table.tableName &&
                actualReferences.single['to'] == reference.fieldName &&
                foreignKeys
                        .where(
                          (fk) => fk['id'] == actualReferences.single['id'],
                        )
                        .length ==
                    1;
        final autoIncrement = topLevelTokens(
          part,
        ).any((t) => t.keyword == 'AUTOINCREMENT');
        if (column['pk'] != (field.isPrimaryKey ? 1 : 0) ||
            !referenceMatches ||
            autoIncrement != field.isAutoIncrement) {
          throw SchemaIncompatibility(
            'Cannot infer a key change for ${table.tableName}.${field.fieldName}; existing data was preserved',
            reason: 'key_change',
          );
        }
        final typeChanged =
            (column['type']! as String).toUpperCase() != field.fieldType.query;
        final nullChanged = column['notnull'] != (field.isNotNull ? 1 : 0);
        final defaultChanged = normalizeDefault(column['dflt_value']) !=
            normalizeDefault(field.defaultSql);
        if (!typeChanged && !nullChanged && !defaultChanged) continue;
        if (column['hidden'] != 0) {
          throw SchemaIncompatibility(
            'Cannot rewrite generated column ${table.tableName}.${field.fieldName}',
            reason: 'generated_column',
          );
        }
        definition.parts[partIndex] = rewriteColumn(
          part,
          type: field.fieldType.query,
          notNull: field.isNotNull,
          defaultSql: field.defaultSql,
          changeType: typeChanged,
          changeNull: nullChanged,
          changeDefault: defaultChanged,
        );
        rebuild = true;
      }
      if (rebuild) {
        // New columns precede table constraints (SQLite grammar requirement).
        final constraint = definition.parts.indexWhere(
          (p) => columnName(p) == null,
        );
        definition.parts.insertAll(
          constraint < 0 ? definition.parts.length : constraint,
          missing,
        );
        await _rebuild(tx, table.tableName, definition, columns,
            classifyCopyFailure: classifyCopyFailure);
      } else {
        for (final fieldSql in missing) {
          await tx.execute(
            'ALTER TABLE ${quoteIdentifier(table.tableName)} ADD COLUMN $fieldSql',
          );
        }
      }
    }
    final actualColumns = await _tableColumns(tx, table.tableName);
    for (final field in table.fields) {
      final column = actualColumns.singleWhere(
        (c) => c['name'] == field.fieldName,
      );
      if ((column['type']! as String).toUpperCase() != field.fieldType.query ||
          column['notnull'] != (field.isNotNull ? 1 : 0) ||
          column['pk'] != (field.isPrimaryKey ? 1 : 0) ||
          normalizeDefault(column['dflt_value']) !=
              normalizeDefault(field.defaultSql)) {
        throw StateError(
          'Automatic schema update could not reconcile ${table.tableName}.${field.fieldName}',
        );
      }
    }
    for (final field in table.indexingFields) {
      final name = '${table.tableName}_${field.fieldName}_index';
      final existing = await tx.query(
        'sqlite_master',
        where: 'type = ? AND name = ?',
        whereArgs: ['index', name],
      );
      if (existing.isNotEmpty) {
        final columns = await tx.rawQuery(
          'PRAGMA index_info(${quoteIdentifier(name)})',
        );
        if (existing.single['tbl_name'] != table.tableName ||
            columns.length != 1 ||
            columns.single['name'] != field.fieldName) {
          throw SchemaIncompatibility(
            'Index $name conflicts with the registered schema',
            reason: 'index_conflict',
          );
        }
        continue;
      }
      await tx.execute(
        'CREATE INDEX ${quoteIdentifier(name)} ON ${quoteIdentifier(table.tableName)} (${quoteIdentifier(field.fieldName)})',
      );
    }
  }

  static Future<void> _rebuild(
    Transaction tx,
    String name,
    TableDefinition definition,
    List<Map<String, Object?>> columns, {
    bool classifyCopyFailure = false,
    Set<String>? retainedColumns,
    bool sourceWithoutRowid = false,
    StoredValueMigration? migration,
  }) async {
    var temp = '${name}__tunai_update';
    while ((await tx.query(
      'sqlite_master',
      columns: ['name'],
      where: 'name = ?',
      whereArgs: [temp],
    ))
        .isNotEmpty) {
      temp = '${temp}_';
    }
    final dependents = await tx.query(
      'sqlite_master',
      columns: ['sql'],
      where: 'tbl_name = ? AND type IN (?, ?) AND sql IS NOT NULL',
      whereArgs: [name, 'index', 'trigger'],
    );
    final withoutRowid = definition.suffix.toUpperCase().contains(
          'WITHOUT ROWID',
        );
    final allNames = columns.map((c) => c['name']! as String).toList();
    final physicalNames = allNames
        .where((n) =>
            retainedColumns == null ||
            retainedColumns.contains(n.toLowerCase()))
        .toList();
    final writable = columns
        .where((c) =>
            (c['hidden'] == 0 || retainedColumns != null) &&
            physicalNames.contains(c['name']))
        .map((c) => c['name']! as String)
        .toList();
    String? rowid;
    if (!withoutRowid && !sourceWithoutRowid) {
      for (final alias in ['rowid', '_rowid_', 'oid']) {
        if (![...allNames, ...?retainedColumns]
            .any((n) => n.toLowerCase() == alias)) {
          rowid = alias;
          break;
        }
      }
      if (rowid == null) {
        throw SchemaIncompatibility(
          'Cannot preserve hidden row identity for $name',
          reason: 'row_identity',
        );
      }
      writable.insert(0, rowid);
    }
    final source = quoteIdentifier(name);
    final target = quoteIdentifier(temp);
    final fields = writable.map(quoteIdentifier).join(', ');
    int? sequence;
    if ((await tx.query(
      'sqlite_master',
      where: 'name = ?',
      whereArgs: ['sqlite_sequence'],
    ))
        .isNotEmpty) {
      final rows = await tx.query(
        'sqlite_sequence',
        where: 'name = ?',
        whereArgs: [name],
      );
      if (rows.isNotEmpty) sequence = rows.single['seq'] as int?;
    }
    await tx.execute(definition.create(temp));
    try {
      if (migration == null || migration.fields.isEmpty) {
        await tx.execute(
            'INSERT INTO $target ($fields) SELECT $fields FROM $source');
      } else {
        final key = rowid ??
            columns.firstWhere((c) => (c['pk']! as int) > 0)['name']! as String;
        final changed = writable.where(migration.fields.containsKey).toList();
        final encoding = (await tx.rawQuery('PRAGMA encoding'))
            .single
            .values
            .single as String;
        final projections = <String>[
          "CASE WHEN typeof(${quoteIdentifier(key)})='text' THEN CAST(${quoteIdentifier(key)} AS BLOB) ELSE ${quoteIdentifier(key)} END AS _tunai_key",
          'typeof(${quoteIdentifier(key)}) AS _tunai_key_kind'
        ];
        for (var i = 0; i < changed.length; i++) {
          final column = quoteIdentifier(changed[i]);
          projections.add(
              "CASE WHEN typeof($column)='text' THEN CAST($column AS BLOB) ELSE $column END AS _tunai_value$i");
          projections.add('typeof($column) AS _tunai_kind$i');
        }
        final expressions = writable.map((c) {
          final index = changed.indexOf(c);
          return index < 0
              ? 's.${quoteIdentifier(c)}'
              : 'v.${quoteIdentifier('_c$index')}';
        }).join(', ');
        final convertedParameters = changed
            .map((c) => migration.fields[c]!.fieldType.query == 'TEXT'
                ? 'CAST(? AS TEXT)'
                : '?')
            .join(', ');
        // Older Android engines allow 999 parameters per statement. One
        // statement per group reduces repeated statement-journal cleanup on
        // large savepoints while retaining the single atomic transaction.
        final capacity = 999 ~/ (changed.length + 1);
        final groupSize = capacity < 1
            ? 1
            : capacity > 256
                ? 256
                : capacity;
        final valuesName = quoteIdentifier('${temp}_values');
        final valueColumns = [
          quoteIdentifier('_key'),
          for (var i = 0; i < changed.length; i++) quoteIdentifier('_c$i')
        ].join(', ');
        Object? cursor;
        var cursorIsText = false;
        while (true) {
          final rows = await tx.query(name,
              columns: projections,
              orderBy: quoteIdentifier(key),
              where: cursor == null
                  ? null
                  : '${quoteIdentifier(key)} > ${cursorIsText ? 'CAST(? AS TEXT)' : '?'}',
              whereArgs: cursor == null ? null : [cursor],
              limit: groupSize);
          if (rows.isEmpty) break;
          final bindings = <Object?>[];
          final valueRows = <String>[];
          for (final original in rows) {
            final values = <String, Object?>{};
            for (var i = 0; i < changed.length; i++) {
              var value = original['_tunai_value$i'];
              if (original['_tunai_kind$i'] == 'text' && value is List<int>) {
                try {
                  if (encoding == 'UTF-8') {
                    value = utf8.decode(value);
                  } else {
                    final bytes =
                        ByteData.sublistView(Uint8List.fromList(value));
                    value = String.fromCharCodes([
                      for (var j = 0; j < bytes.lengthInBytes; j += 2)
                        bytes.getUint16(
                            j,
                            encoding == 'UTF-16le'
                                ? Endian.little
                                : Endian.big),
                    ]);
                  }
                } on FormatException {
                  // Malformed TEXT cannot be converted; use the normal fallback.
                }
              }
              values[changed[i]] = value;
            }
            migration.apply(values);
            valueRows.add(
                "(${original['_tunai_key_kind'] == 'text' ? 'CAST(? AS TEXT)' : '?'}, $convertedParameters)");
            bindings.add(original['_tunai_key']);
            bindings.addAll(changed.map((c) {
              final value = values[c];
              if (value is! String) return value;
              if (encoding == 'UTF-8') {
                return Uint8List.fromList(utf8.encode(value));
              }
              final bytes = ByteData(value.length * 2);
              for (var i = 0; i < value.length; i++) {
                bytes.setUint16(i * 2, value.codeUnitAt(i),
                    encoding == 'UTF-16le' ? Endian.little : Endian.big);
              }
              return bytes.buffer.asUint8List();
            }));
          }
          // Unchanged values never cross the platform adapter or Dart codec.
          await tx.rawInsert(
              'WITH $valuesName ($valueColumns) AS (VALUES ${valueRows.join(', ')}) '
              'INSERT INTO $target ($fields) SELECT $expressions '
              'FROM $valuesName v JOIN $source s ON s.${quoteIdentifier(key)} = v.${quoteIdentifier('_key')}',
              bindings);
          cursor = rows.last['_tunai_key'];
          cursorIsText = rows.last['_tunai_key_kind'] == 'text';
        }
      }
    } on DatabaseException catch (error) {
      // SQLITE_CONSTRAINT only, and only while copying legacy rows. Syntax,
      // locking, storage and arbitrary driver failures must never erase data.
      if (!classifyCopyFailure) rethrow;
      final code = error.getResultCode();
      if ((code != null && (code & 0xff) == 19) ||
          error.isNotNullConstraintError() ||
          error.isUniqueConstraintError()) {
        throw SchemaIncompatibility(
          'Existing rows violate the target constraints',
          reason: 'stored_constraint_violation',
        );
      }
      rethrow;
    }
    final oldCount = Sqflite.firstIntValue(
      await tx.rawQuery('SELECT count(*) FROM $source'),
    );
    final newCount = Sqflite.firstIntValue(
      await tx.rawQuery('SELECT count(*) FROM $target'),
    );
    final keys = rowid == null
        ? columns
            .where((c) => (c['pk']! as int) > 0)
            .map((c) => c['name']! as String)
            .toList()
        : [rowid];
    final join = keys
        .map((k) => 'a.${quoteIdentifier(k)} IS b.${quoteIdentifier(k)}')
        .join(' AND ');
    final unchanged = physicalNames
        .where((c) => !(migration?.fields.containsKey(c) ?? false))
        .toList();
    final different = unchanged.isEmpty
        ? '0'
        : unchanged
            .map(
              (c) =>
                  '+a.${quoteIdentifier(c)} IS NOT +b.${quoteIdentifier(c)} COLLATE BINARY',
            )
            .join(' OR ');
    if (oldCount != newCount ||
        (await tx.rawQuery(
          'SELECT 1 FROM $source a LEFT JOIN $target b ON $join WHERE b.${quoteIdentifier(keys.first)} IS NULL OR ($different) LIMIT 1',
        ))
            .isNotEmpty) {
      throw SchemaIncompatibility(
        'Automatic schema update would change stored values in $name',
        reason: 'value_conversion',
      );
    }
    await tx.execute('DROP TABLE $source');
    await tx.execute('ALTER TABLE $target RENAME TO $source');
    if (sequence != null) {
      await tx.update(
        'sqlite_sequence',
        {'seq': sequence},
        where: 'name = ? AND seq < ?',
        whereArgs: [name, sequence],
      );
    }
    for (final dependent in dependents) {
      await tx.execute(dependent['sql']! as String);
    }
    if ((await tx.rawQuery(
      'PRAGMA quick_check($source)',
    ))
        .any((row) => row.values.single != 'ok')) {
      throw StateError('Integrity check failed after updating $name');
    }
  }
}
