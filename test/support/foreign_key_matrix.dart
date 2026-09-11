import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:tunai_db/src/schema/schema_reconciler.dart';
import 'package:tunai_db/tunai_db.dart';

const _id = DBField(
    fieldName: 'id', fieldType: DBFieldType.integer, isPrimaryKey: true);
const _parent = DBTable(tableName: 'parent', fields: [_id]);
const _other = DBTable(tableName: 'other_parent', fields: [_id]);
const _sentinel = DBTable(tableName: 'sentinel', fields: [_id]);
DBTable _child(
        {DBTable? parent,
        String reference = 'id',
        DBFieldType type = DBFieldType.integer,
        bool column = true,
        bool required = false,
        Object? value,
        String name = 'child'}) =>
    DBTable(tableName: name, fields: [
      _id,
      if (column)
        DBField(
            fieldName: 'parentId',
            fieldType: type,
            isNotNull: required,
            defaultValue: value,
            reference: parent == null
                ? null
                : DBReference(table: parent, fieldName: reference))
    ]);

class _Case {
  _Case(this.name, this.before, this.after, this.rows,
      {this.rebuild = false,
      this.invalid = false,
      this.expected,
      this.legacyCascade = false});
  final String name;
  final List<DBTable> before;
  final List<DBTable> after;
  final Map<String, List<Map<String, Object?>>> rows;
  final Map<String, List<Map<String, Object?>>>? expected;
  final bool rebuild;
  final bool invalid;
  final bool legacyCascade;
}

Map<String, List<Map<String, Object?>>> _rows(
        {Object? parentId = 1,
        bool other = false,
        bool matchingOther = true}) =>
    {
      'parent': [
        {'id': 1},
        {'id': 2}
      ],
      'child': [
        {'id': 10, 'parentId': parentId},
        {'id': 11, 'parentId': parentId}
      ],
      if (other)
        'other_parent': [
          {'id': matchingOther ? 1 : 99}
        ],
    };
List<_Case> _cases() {
  final plain = _child();
  final linked = _child(parent: _parent);
  final cases = <_Case>[
    _Case('add FK to populated valid values', [_parent, plain],
        [_parent, linked], _rows()),
    _Case('add FK with orphan values', [_parent, plain], [_parent, linked],
        _rows(parentId: 99),
        rebuild: true),
    _Case('add FK with NULL values', [_parent, plain], [_parent, linked],
        _rows(parentId: null)),
    _Case('retarget FK to matching parent table', [_parent, _other, linked],
        [_parent, _other, _child(parent: _other)], _rows(other: true)),
    _Case(
        'retarget FK to nonmatching parent table',
        [_parent, _other, linked],
        [_parent, _other, _child(parent: _other)],
        _rows(other: true, matchingOther: false),
        rebuild: true),
    _Case('remove FK and retain column', [_parent, linked], [_parent, plain],
        _rows()),
    _Case('remove FK and its parent table together', [_parent, linked], [plain],
        _rows(),
        expected: {'child': _rows()['child']!}),
    _Case('remove FK column', [_parent, linked],
        [_parent, _child(column: false)], _rows(),
        expected: {
          'parent': _rows()['parent']!,
          'child': [
            {'id': 10},
            {'id': 11}
          ]
        }),
    _Case('drop child table', [_parent, linked], [_parent], _rows(),
        expected: {'parent': _rows()['parent']!}),
    _Case('drop parent while child still references it', [_parent, linked],
        [linked], _rows(),
        invalid: true),
    _Case('missing referenced column', [_parent, plain],
        [_parent, _child(parent: _parent, reference: 'missing')], _rows(),
        invalid: true),
    _Case(
        'add required FK over existing NULLs',
        [_parent, plain],
        [_parent, _child(parent: _parent, required: true, value: 1)],
        _rows(parentId: null),
        rebuild: true),
    _Case('tighten FK nullability over valid rows', [_parent, linked],
        [_parent, _child(parent: _parent, required: true)], _rows()),
    _Case('change FK default without rewriting rows', [_parent, linked],
        [_parent, _child(parent: _parent, value: 2)], _rows()),
    _Case('remove legacy delete cascade without deleting children',
        [_parent, linked], [_parent, linked], _rows(),
        legacyCascade: true),
  ];
  final noColumn = _child(column: false);
  for (final variant in [
    (name: 'nullable', required: false, value: null, rebuild: false),
    (name: 'valid default', required: true, value: 1, rebuild: false),
    (name: 'orphan default', required: true, value: 99, rebuild: true),
    (name: 'required no default', required: true, value: null, rebuild: true),
  ]) {
    cases.add(_Case(
        'add FK column: ${variant.name}',
        [_parent, noColumn],
        [
          _parent,
          _child(
              parent: _parent, required: variant.required, value: variant.value)
        ],
        {
          'parent': [
            {'id': 1}
          ],
          'child': [
            {'id': 10},
            {'id': 11}
          ]
        },
        rebuild: variant.rebuild,
        expected: {
          'parent': [
            {'id': 1}
          ],
          'child': [
            {'id': 10, 'parentId': variant.value},
            {'id': 11, 'parentId': variant.value}
          ]
        }));
  }
  const withCode = DBTable(tableName: 'parent', fields: [
    _id,
    DBField(fieldName: 'code', fieldType: DBFieldType.integer)
  ]);
  const codeKey = DBTable(tableName: 'parent', fields: [
    DBField(fieldName: 'id', fieldType: DBFieldType.integer),
    DBField(
        fieldName: 'code', fieldType: DBFieldType.integer, isPrimaryKey: true)
  ]);
  final codeRows = {
    'parent': [
      {'id': 1, 'code': 10}
    ],
    'child': [
      {'id': 2, 'parentId': 10}
    ]
  };
  cases.add(_Case(
      'retarget reference to changed primary-key column',
      [withCode, plain],
      [codeKey, _child(parent: codeKey, reference: 'code')],
      codeRows,
      rebuild: true));
  cases.add(_Case('reference a nonunique non-primary column', [withCode, plain],
      [withCode, _child(parent: withCode, reference: 'code')], codeRows,
      invalid: true));

  const selfIdentity = DBTable(tableName: 'node', fields: [_id]);
  for (final orphan in [false, true]) {
    cases.add(_Case(
        'add self-reference, orphan=$orphan',
        [_child(name: 'node')],
        [_child(name: 'node', parent: selfIdentity)],
        {
          'node': [
            {'id': 1, 'parentId': null},
            {'id': 2, 'parentId': orphan ? 99 : 1}
          ]
        },
        rebuild: orphan));
  }
  const a = DBTable(tableName: 'a', fields: [_id]);
  const b = DBTable(tableName: 'b', fields: [_id]);
  cases.add(_Case('add cyclic references in reverse table order', [
    _child(name: 'a'),
    _child(name: 'b')
  ], [
    _child(name: 'b', parent: a),
    _child(name: 'a', parent: b)
  ], {
    'a': [
      {'id': 1, 'parentId': 2}
    ],
    'b': [
      {'id': 2, 'parentId': 1}
    ]
  }));
  for (final orphan in [false, true]) {
    cases.add(_Case(
        'multiple child tables, orphan=$orphan',
        [_parent, plain, _child(name: 'second_child')],
        [_parent, linked, _child(name: 'second_child', parent: _parent)],
        {
          ..._rows(),
          'second_child': [
            {'id': 20, 'parentId': orphan ? 99 : 2}
          ]
        },
        rebuild: orphan));
  }
  for (final parentType in DBFieldType.values) {
    for (final childType in DBFieldType.values) {
      final targetParent = DBTable(tableName: 'parent', fields: [
        DBField(fieldName: 'id', fieldType: parentType, isPrimaryKey: true),
      ]);
      cases.add(_Case(
          'populated FK types: parent=${parentType.name}, child=${childType.name}',
          [_parent, linked],
          [targetParent, _child(parent: targetParent, type: childType)],
          _rows(),
          rebuild:
              parentType == DBFieldType.text || childType == DBFieldType.text));
    }
  }
  return cases;
}

/// Each scenario uses populated, disposable files on the package's real backend.
void registerForeignKeyMatrix(
    void Function(String, Future<void> Function()) register) {
  for (final scenario in _cases()) {
    for (final enforce in [false, true]) {
      register('${scenario.name}; foreign_keys=$enforce',
          () => _run(scenario, enforce));
    }
  }
}

Future<void> _run(_Case scenario, bool enforce) async {
  final init = TunaiDBInitializer()
    ..setDBName('foreign_matrix_${DateTime.now().microsecondsSinceEpoch}')
    ..setTables([...scenario.before, _sentinel])
    ..setTriggers([]);
  String? path;
  try {
    await init.initDatabase('matrix');
    path = init.database.path;
    // Seed with enforcement off to cover legacy orphans and cyclic graphs.
    await init.database.execute('PRAGMA foreign_keys=OFF');
    for (final entry in scenario.rows.entries) {
      for (final row in entry.value) {
        await init.database.insert(entry.key, row);
      }
    }
    await init.database.insert('sentinel', {'id': 99});
    if (scenario.legacyCascade) {
      await init.database.execute('DROP TABLE child');
      await init.database.execute(
          'CREATE TABLE child(id INTEGER PRIMARY KEY NOT NULL, parentId INTEGER REFERENCES parent(id) ON DELETE CASCADE)');
      for (final row in scenario.rows['child']!) {
        await init.database.insert('child', row);
      }
    }
    await init.database
        .execute('PRAGMA foreign_keys=${enforce ? 'ON' : 'OFF'}');
    final target = [...scenario.after, _sentinel];
    final original = await _snapshot(init.database);
    if (scenario.rebuild || scenario.invalid) {
      await expectLater(
          SchemaReconciler.update(init.database, target,
              completeRegistry: true),
          throwsA(scenario.invalid
              ? isA<ArgumentError>()
              : anyOf(isA<SchemaIncompatibility>(), isA<DatabaseException>())));
      expect(await _snapshot(init.database), original,
          reason: 'Failed attempt must restore all rows and schema');
      expect(await _enforcement(init.database), enforce);
    }
    init.setTables(target);
    if (scenario.invalid) {
      await expectLater(init.initDatabase('matrix'), throwsArgumentError);
      expect(init.hasInit, isFalse);
      init.setTables([...scenario.before, _sentinel]);
      await init.initDatabase('matrix', updateDB: false);
      expect(await _snapshot(init.database), original);
      return;
    }
    // Test both the initializer's normal reopen path and restoration of an
    // explicitly enabled connection setting in the shared reconciliation engine.
    final events = <String>[];
    final result = enforce
        ? await SchemaReconciler.update(init.database, target,
            completeRegistry: true,
            recoverIncompatibleSchema: true,
            logRecovery: events.add)
        : await init.initDatabase('matrix');
    expect(
        result,
        scenario.rebuild
            ? DBInitializationResult.rebuilt
            : DBInitializationResult.ready);
    if (enforce) {
      expect(await _enforcement(init.database), isTrue);
      expect(events.isNotEmpty, scenario.rebuild);
    }
    final expected = scenario.expected ?? scenario.rows;
    for (final table in target) {
      expect(
          await init.database.query(table.tableName, orderBy: 'id'),
          scenario.rebuild
              ? isEmpty
              : table == _sentinel
                  ? [
                      {'id': 99}
                    ]
                  : expected[table.tableName]);
      final foreignKeys = await init.database
          .rawQuery('PRAGMA foreign_key_list(${table.tableName})');
      expect(foreignKeys, hasLength(table.foreignFields.length));
      for (final field in table.foreignFields) {
        final fk =
            foreignKeys.singleWhere((fk) => fk['from'] == field.fieldName);
        expect(fk['table'], field.reference!.table.tableName);
        expect(fk['to'], field.reference!.fieldName);
        expect(fk['on_delete'], 'NO ACTION');
        expect(fk['on_update'], 'NO ACTION');
      }
    }
    expect(await init.database.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect(
        (await init.database.rawQuery('PRAGMA quick_check'))
            .single
            .values
            .single,
        'ok');
    final beforeReopen = await _snapshot(init.database);
    expect(await init.initDatabase('matrix'), DBInitializationResult.ready);
    expect(await _snapshot(init.database), beforeReopen);
    // Check actual constraint behavior, not just metadata. Roll back probes so
    // success/failure never changes the fixture's persisted rows.
    await init.database.execute('PRAGMA foreign_keys=ON');
    for (final table in scenario.after
        .where((t) => t.fields.any((f) => f.fieldName == 'parentId'))) {
      await init.database.execute('SAVEPOINT probe');
      try {
        final insertion = init.database
            .insert(table.tableName, {'id': 9000, 'parentId': 876543});
        if (table.foreignFields.isEmpty) {
          await insertion;
        } else {
          await expectLater(insertion, throwsA(isA<DatabaseException>()));
          final reference = table.foreignFields.single.reference!;
          final parent = scenario.after
              .singleWhere((t) => t.tableName == reference.table.tableName);
          if (parent.foreignFields.isEmpty) {
            await init.database.insert(parent.tableName,
                {for (final field in parent.fields) field.fieldName: 9001});
            Object parentKey = 9001;
            num childKey = 9001;
            final parentField = parent.fields
                .singleWhere((f) => f.fieldName == reference.fieldName);
            if (parentField.fieldType == DBFieldType.text &&
                table.foreignFields.single.fieldType == DBFieldType.real) {
              // Older SQLite releases stringify whole REAL keys differently.
              // A fractional key gives a stable relationship on both engines.
              parentKey = '9001.5';
              childKey = 9001.5;
              await init.database.update(
                  parent.tableName, {reference.fieldName: parentKey},
                  where: '${reference.fieldName}=?', whereArgs: [9001]);
            }
            if (parentField.fieldType == DBFieldType.integer &&
                table.foreignFields.single.fieldType == DBFieldType.real &&
                !await _freshIntegerRealReferenceAccepts(init.database)) {
              // Some upstream engines reject this on an unmigrated schema too.
              // Require matching behavior; never relax foreign-key enforcement.
              await expectLater(
                  init.database.insert(
                      table.tableName, {'id': 9000, 'parentId': childKey}),
                  throwsA(isA<DatabaseException>().having(
                      (e) => e.toString(),
                      'constraint',
                      contains('FOREIGN KEY constraint failed'))));
              continue;
            }
            await init.database
                .insert(table.tableName, {'id': 9000, 'parentId': childKey});
            await expectLater(
                init.database.delete(parent.tableName,
                    where: '${reference.fieldName}=?', whereArgs: [parentKey]),
                throwsA(isA<DatabaseException>()));
            await expectLater(
                init.database.update(
                    parent.tableName, {reference.fieldName: 9002},
                    where: '${reference.fieldName}=?', whereArgs: [parentKey]),
                throwsA(isA<DatabaseException>()));
          }
        }
      } finally {
        await init.database.execute('ROLLBACK TO probe');
        await init.database.execute('RELEASE probe');
      }
    }
    expect(await _snapshot(init.database), beforeReopen);
  } finally {
    await init.close();
    init
      ..setTables([])
      ..setTriggers([])
      ..setDBName('tunaiDB');
    if (path != null) await deleteDatabase(path);
  }
}

Future<bool> _enforcement(Database db) async =>
    (await db.rawQuery('PRAGMA foreign_keys')).single.values.single == 1;
Future<Map<String, Object?>> _snapshot(Database db) async {
  final schema = await db.query('sqlite_master',
      columns: ['type', 'name', 'sql'], orderBy: 'type,name');
  final rows = <String, Object?>{};
  for (final table in schema.where((t) =>
      t['type'] == 'table' && !(t['name']! as String).startsWith('sqlite_'))) {
    rows[table['name']! as String] =
        await db.query(table['name']! as String, orderBy: 'id');
  }
  return {'schema': schema, 'rows': rows};
}

// Called inside the probe savepoint, so these fresh baseline tables roll back.
Future<bool> _freshIntegerRealReferenceAccepts(Database db) async {
  await db
      .execute('CREATE TABLE probe_parent(id INTEGER PRIMARY KEY NOT NULL)');
  await db.execute(
      'CREATE TABLE probe_child(parentId REAL REFERENCES probe_parent(id))');
  await db.execute('INSERT INTO probe_parent VALUES(9001)');
  try {
    await db.execute('INSERT INTO probe_child VALUES(9001)');
    return true;
  } on DatabaseException catch (error) {
    expect(error.toString(), contains('FOREIGN KEY constraint failed'));
    return false;
  }
}
