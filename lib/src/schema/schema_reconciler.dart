import 'package:sqflite/sqflite.dart';
import 'package:synchronized/synchronized.dart';

import '../model/db_table.dart';
import '../model/db_trigger.dart';
import 'schema_sql.dart';

/// Automatic, data-preserving reconciliation of the registered schema.
/// Call outside transactions, before exposing this connection to app workers.
abstract final class SchemaReconciler {
  static final _lock = Lock();

  static Future<void> update(
    Database db,
    List<DBTable> tables, {
    List<DBTrigger> triggers = const [],
  }) {
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
      try {
        await db.execute('PRAGMA legacy_alter_table = ON');
        await db.transaction((tx) async {
          if (selectedTables
                  .map((t) => t.tableName.toLowerCase())
                  .toSet()
                  .length !=
              selectedTables.length) {
            throw StateError('Duplicate registered table names');
          }
          for (final table in selectedTables) {
            await _updateTable(tx, table);
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
          if (foreignKeys &&
              (await tx.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
            throw StateError(
              'Automatic schema update would leave foreign-key violations',
            );
          }
        }, exclusive: true);
      } finally {
        try {
          await db.execute(
              'PRAGMA legacy_alter_table = ${legacyAlter ? 'ON' : 'OFF'}');
        } finally {
          if (foreignKeys) await db.execute('PRAGMA foreign_keys = ON');
        }
      }
    });
  }

  static Future<void> _updateTable(Transaction tx, DBTable table) async {
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
      where: 'type = ? AND name = ?',
      whereArgs: ['table', table.tableName],
    );
    if (existing.isEmpty) {
      await tx.execute(table.createTableQuery);
    } else {
      final sql = existing.single['sql']! as String;
      final definition = TableDefinition(sql);
      final columns = await tx.rawQuery(
        'PRAGMA table_xinfo(${quoteIdentifier(table.tableName)})',
      );
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
            throw StateError(
              'Cannot infer identity or relationship for new key ${table.tableName}.${field.fieldName}',
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
          throw StateError(
            'Cannot infer a key change for ${table.tableName}.${field.fieldName}; existing data was preserved',
          );
        }
        final typeChanged =
            (column['type']! as String).toUpperCase() != field.fieldType.query;
        final nullChanged = column['notnull'] != (field.isNotNull ? 1 : 0);
        final defaultChanged = normalizeDefault(column['dflt_value']) !=
            normalizeDefault(field.defaultSql);
        if (!typeChanged && !nullChanged && !defaultChanged) continue;
        if (column['hidden'] != 0) {
          throw StateError(
            'Cannot rewrite generated column ${table.tableName}.${field.fieldName}',
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
        await _rebuild(tx, table.tableName, definition, columns);
      } else {
        for (final fieldSql in missing) {
          await tx.execute(
            'ALTER TABLE ${quoteIdentifier(table.tableName)} ADD COLUMN $fieldSql',
          );
        }
      }
    }
    final actualColumns = await tx
        .rawQuery('PRAGMA table_xinfo(${quoteIdentifier(table.tableName)})');
    for (final field in table.fields) {
      final column =
          actualColumns.singleWhere((c) => c['name'] == field.fieldName);
      if ((column['type']! as String).toUpperCase() != field.fieldType.query ||
          column['notnull'] != (field.isNotNull ? 1 : 0) ||
          column['pk'] != (field.isPrimaryKey ? 1 : 0) ||
          normalizeDefault(column['dflt_value']) !=
              normalizeDefault(field.defaultSql)) {
        throw StateError(
            'Automatic schema update could not reconcile ${table.tableName}.${field.fieldName}');
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
          throw StateError('Index $name conflicts with the registered schema');
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
    List<Map<String, Object?>> columns,
  ) async {
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
    final physicalNames = columns.map((c) => c['name']! as String).toList();
    final writable = columns
        .where((c) => c['hidden'] == 0)
        .map((c) => c['name']! as String)
        .toList();
    String? rowid;
    if (!withoutRowid) {
      for (final alias in ['rowid', '_rowid_', 'oid']) {
        if (!physicalNames.any((n) => n.toLowerCase() == alias)) {
          rowid = alias;
          break;
        }
      }
      if (rowid == null) {
        throw StateError('Cannot preserve hidden row identity for $name');
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
    await tx.execute(
      'INSERT INTO $target ($fields) SELECT $fields FROM $source',
    );
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
    final different = physicalNames
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
      throw StateError(
        'Automatic schema update would change stored values in $name',
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
