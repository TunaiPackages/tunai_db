import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:tunai_db/tunai_db.dart';
import 'package:tunai_db/src/schema/schema_reconciler.dart';

const _id = DBField(
    fieldName: 'id', fieldType: DBFieldType.integer, isPrimaryKey: true);
const _sentinel = DBTable(tableName: 'sentinel', fields: [_id]);
DBTable _model(
        {bool updated = false,
        bool required = false,
        Object? value,
        DBFieldType? valueType}) =>
    DBTable(tableName: 'items', fields: [
      _id,
      DBField(
          fieldName: 'value',
          fieldType:
              valueType ?? (updated ? DBFieldType.integer : DBFieldType.text),
          isNotNull: required,
          defaultValue: value,
          indexing: updated),
      const DBField(
          fieldName: 'untouched',
          fieldType: DBFieldType.text,
          isNotNull: false),
      DBField(
          fieldName: 'score',
          fieldType: updated ? DBFieldType.real : DBFieldType.text,
          isNotNull: false),
    ]);

void registerColumnConversionCases(
    void Function(String, Future<void> Function()) register) {
  register(
      'multi-column six type changes with add remove defaults and indexes',
      () => _fixture((init) async {
            const types = [
              DBFieldType.integer,
              DBFieldType.integer,
              DBFieldType.text,
              DBFieldType.text,
              DBFieldType.real,
              DBFieldType.real,
            ];
            const targets = [
              DBFieldType.text,
              DBFieldType.real,
              DBFieldType.integer,
              DBFieldType.real,
              DBFieldType.integer,
              DBFieldType.text,
            ];
            final old = DBTable(tableName: 'items', fields: [
              _id,
              for (var c = 0; c < types.length; c++)
                DBField(
                    fieldName: 'c$c',
                    fieldType: types[c],
                    isNotNull: false,
                    indexing: c == 0),
              const DBField(fieldName: 'keep', fieldType: DBFieldType.text),
              const DBField(fieldName: 'removed', fieldType: DBFieldType.text),
              const DBField(
                  fieldName: 'default_only',
                  fieldType: DBFieldType.text,
                  defaultValue: 'old',
                  isNotNull: false),
            ]);
            init.setTables([old, _sentinel]);
            await init.initDatabase('conversion');
            final batch = init.database.batch();
            for (var i = 0; i < 600; i++) {
              final inputs = i.isEven
                  ? <Object?>[7, 8, '009', '2.5', 10.0, 11.5]
                  : <Object?>[
                      Uint8List.fromList([255]),
                      'bad',
                      'bad',
                      'bad',
                      2.5,
                      null
                    ];
              batch.insert('items', {
                'id': i,
                for (var c = 0; c < inputs.length; c++) 'c$c': inputs[c],
                'keep': 'preserved $i 中文',
                'removed': 'obsolete',
                'default_only': i.isEven ? null : 'existing',
              });
            }
            await batch.commit(noResult: true);
            final target = DBTable(tableName: 'items', fields: [
              _id,
              // Deliberately reverse declaration order to catch parameter mixups.
              for (var c = targets.length - 1; c >= 0; c--)
                DBField(
                    fieldName: 'c$c',
                    fieldType: targets[c],
                    isNotNull: c.isEven,
                    indexing: c == 1,
                    defaultValue: c == 0
                        ? 'fallback'
                        : c == 2
                            ? -9
                            : c == 4
                                ? -10
                                : null),
              const DBField(fieldName: 'keep', fieldType: DBFieldType.text),
              const DBField(
                  fieldName: 'added',
                  fieldType: DBFieldType.text,
                  defaultValue: 'new',
                  indexing: true),
              const DBField(
                  fieldName: 'default_only',
                  fieldType: DBFieldType.text,
                  defaultValue: 'changed',
                  isNotNull: false),
            ]);
            init.setTables([target, _sentinel]);
            expect(await init.initDatabase('conversion'),
                DBInitializationResult.ready);
            final db = init.database;
            final rows = await db.query('items', orderBy: 'id');
            expect(rows, hasLength(600));
            for (var i = 0; i < rows.length; i++) {
              final expected = i.isEven
                  ? <Object?>['7', 8.0, 9, 2.5, 10, '11.5']
                  : <Object?>['fallback', null, -9, null, -10, null];
              expect(rows[i], {
                'id': i,
                for (var c = 0; c < expected.length; c++) 'c$c': expected[c],
                'keep': 'preserved $i 中文',
                'added': 'new',
                'default_only': i.isEven ? null : 'existing',
              });
            }
            final columns = await db.rawQuery('PRAGMA table_info(items)');
            expect(columns.map((c) => c['name']),
                target.fields.map((f) => f.fieldName));
            for (var c = 0; c < targets.length; c++) {
              final column = columns.singleWhere((row) => row['name'] == 'c$c');
              expect(column['type'], targets[c].query);
              expect(column['notnull'], c.isEven ? 1 : 0);
            }
            final indexed = <Object?>[];
            for (final index in await db.rawQuery('PRAGMA index_list(items)')) {
              if (index['origin'] == 'c') {
                final name = (index['name']! as String).replaceAll('"', '""');
                indexed.addAll((await db.rawQuery('PRAGMA index_info("$name")'))
                    .map((row) => row['name']));
              }
            }
            expect(indexed, unorderedEquals(['c1', 'added']));
            await db.insert('items', {'id': 600, 'keep': 'new row'});
            expect((await db.query('items', where: 'id=600')).single, {
              'id': 600,
              'c0': 'fallback',
              'c1': null,
              'c2': -9,
              'c3': null,
              'c4': -10,
              'c5': null,
              'keep': 'new row',
              'added': 'new',
              'default_only': 'changed',
            });
            expect(await db.query('sentinel'), [
              {'id': 99}
            ]);
            final finalRows = await db.query('items', orderBy: 'id');
            expect(await init.initDatabase('conversion'),
                DBInitializationResult.ready);
            expect(
                await init.database.query('items', orderBy: 'id'), finalRows);
          }));
  register(
      'multi-column late second-column failure rolls back and retries',
      () => _fixture((init) async {
            final db = init.database;
            final batch = db.batch();
            for (var i = 0; i < 600; i++) {
              batch.insert('items', {
                'id': i,
                'value': 'bad',
                'score': i == 599 ? 'bad' : '1.5',
                'untouched': 'keep $i'
              });
            }
            await batch.commit(noResult: true);
            final before = await db.query('items', orderBy: 'id');
            final schema = await db.query('sqlite_master', orderBy: 'name');
            DBTable target({double? fallback}) =>
                DBTable(tableName: 'items', fields: [
                  ..._model(updated: true, value: -1).fields.take(3),
                  DBField(
                      fieldName: 'score',
                      fieldType: DBFieldType.real,
                      defaultValue: fallback),
                ]);
            final logs = <String>[];
            await expectLater(
                SchemaReconciler.update(db, [target(), _sentinel],
                    completeRegistry: true, logRecovery: logs.add),
                throwsStateError);
            expect(await db.query('items', orderBy: 'id'), before);
            expect(await db.query('sqlite_master', orderBy: 'name'), schema);
            expect(logs, isEmpty);
            init.setTables([target(fallback: 2.5), _sentinel]);
            expect(await init.initDatabase('conversion'),
                DBInitializationResult.ready);
            final rows = await init.database.query('items', orderBy: 'id');
            expect(rows, hasLength(600));
            for (var i = 0; i < 600; i++) {
              expect(rows[i], {
                'id': i,
                'value': -1,
                'score': i == 599 ? 2.5 : 1.5,
                'untouched': 'keep $i'
              });
            }
            expect(await init.database.query('sentinel'), [
              {'id': 99}
            ]);
          }));
  for (final fallback in [false, true]) {
    register(
        'mixed conversion across 600 rows, default=$fallback',
        () => _fixture((init) async {
              final db = init.database;
              final inputs = <Object?>[
                '007',
                '7.0',
                '1e3',
                '-2.5',
                'bad',
                null,
                '9223372036854775807',
                '9223372036854775808',
                '12x',
                '0x10',
                Uint8List.fromList([1, 2]),
                '  -7  '
              ];
              final expected = <Object?>[
                7,
                7,
                1000,
                null,
                null,
                null,
                9223372036854775807,
                null,
                null,
                null,
                null,
                -7
              ];
              final batch = db.batch();
              for (var i = 0; i < 600; i++) {
                batch.insert('items', {
                  'id': i,
                  'value': inputs[i % inputs.length],
                  'untouched': i.isEven ? null : "retained '$i' 中文",
                  'score': i.isEven ? '1.25' : '1e-9999'
                });
              }
              await batch.commit(noResult: true);
              final target = _model(
                  updated: true,
                  required: fallback,
                  value: fallback ? -1 : null);
              final logs = <String>[];
              expect(
                  await SchemaReconciler.update(db, [target, _sentinel],
                      completeRegistry: true,
                      recoverIncompatibleSchema: true,
                      logRecovery: logs.add),
                  DBInitializationResult.ready);
              final rows = await db.query('items', orderBy: 'id');
              expect(rows, hasLength(600));
              for (var i = 0; i < rows.length; i++) {
                expect(rows[i], {
                  'id': i,
                  'value':
                      expected[i % expected.length] ?? (fallback ? -1 : null),
                  'untouched': i.isEven ? null : "retained '$i' 中文",
                  'score': i.isEven ? 1.25 : null
                });
              }
              expect(logs, hasLength(1));
              expect(logs.single, startsWith('schema_migration: committed;'));
              expect(logs.single, contains('defaulted=${fallback ? 350 : 0}'));
              expect(logs.single, isNot(contains('retained')));
              expect(await db.query('sentinel'), [
                {'id': 99}
              ]);
              init.setTables([target, _sentinel]);
              expect(await init.initDatabase('conversion'),
                  DBInitializationResult.ready);
              expect(await init.database.query('items', orderBy: 'id'), rows);
            }));
  }
  register(
      'required column without fallback rolls back late failure before recovery',
      () => _fixture((init) async {
            final db = init.database;
            final batch = db.batch();
            for (var i = 0; i < 600; i++) {
              batch.insert('items', {
                'id': i,
                'value': i == 599 ? 'bad' : '$i',
                'untouched': 'keep',
                'score': '1.5'
              });
            }
            await batch.commit(noResult: true);
            final before = await db.query('items', orderBy: 'id');
            final target = _model(updated: true, required: true);
            await expectLater(
                SchemaReconciler.update(db, [target, _sentinel],
                    completeRegistry: true),
                throwsStateError);
            expect(await db.query('items', orderBy: 'id'), before);
            expect(
                await db.query('sqlite_master',
                    where: "name LIKE '%__tunai_update%'"),
                isEmpty);
            init.setTables([target, _sentinel]);
            expect(await init.initDatabase('conversion'),
                DBInitializationResult.tablesRebuilt);
            expect(await init.database.query('items'), isEmpty);
            expect(await init.database.query('sentinel'), [
              {'id': 99}
            ]);
          }));
  register(
      'embedded NULs and unrelated blobs survive native conversion',
      () => _fixture((init) async {
            init.setTables([_model(valueType: DBFieldType.real), _sentinel]);
            await init.initDatabase('conversion');
            await init.database.rawInsert(
                'INSERT INTO items(id, value, untouched, score) VALUES(1, CAST(? AS TEXT), CAST(? AS TEXT), ?)',
                [
                  Uint8List.fromList(utf8.encode('before\u0000after')),
                  Uint8List.fromList(utf8.encode('kept\u0000intact')),
                  '1.25'
                ]);
            await init.database.insert('items', {
              'id': 2,
              'value': 32,
              'untouched': Uint8List.fromList([0, 255, 1]),
              'score': '2.5'
            });
            final before = await init.database.rawQuery(
                'SELECT id, hex(untouched) AS bytes FROM items ORDER BY id');
            final text = await init.database
                .rawQuery('SELECT hex(value) AS bytes FROM items WHERE id=1');
            init.setTables([
              _model(updated: true, valueType: DBFieldType.text),
              _sentinel
            ]);
            expect(await init.initDatabase('conversion'),
                DBInitializationResult.ready);
            expect(
                await init.database.rawQuery(
                    'SELECT id, hex(untouched) AS bytes FROM items ORDER BY id'),
                before);
            expect(
                await init.database.rawQuery(
                    'SELECT hex(value) AS bytes FROM items WHERE id=1'),
                text);
          }));
  register(
      'WITHOUT ROWID text identities survive conversion across batches',
      () => _fixture((init) async {
            await init.database.execute('DROP TABLE items');
            await init.database.execute(
                'CREATE TABLE items(id TEXT PRIMARY KEY NOT NULL, value TEXT, untouched TEXT, score TEXT) WITHOUT ROWID');
            final batch = init.database.batch();
            for (var i = 0; i < 600; i++) {
              batch.rawInsert(
                  "INSERT INTO items(id, value, score, untouched) VALUES('key'||char(0)||?, ?, ?, 'keep'||char(0)||?)",
                  [i.toString().padLeft(4, '0'), '$i', '1.5', '$i']);
            }
            await batch.commit(noResult: true);
            final before = await init.database.rawQuery(
                'SELECT hex(id) AS id, hex(untouched) AS data FROM items ORDER BY id');
            final target = DBTable(tableName: 'items', fields: [
              const DBField(
                  fieldName: 'id',
                  fieldType: DBFieldType.text,
                  isPrimaryKey: true),
              ..._model(updated: true).fields.skip(1),
            ]);
            init.setTables([target, _sentinel]);
            expect(await init.initDatabase('conversion'),
                DBInitializationResult.ready);
            expect(
                await init.database.rawQuery(
                    'SELECT hex(id) AS id, hex(untouched) AS data FROM items ORDER BY id'),
                before);
            expect(
                (await init.database.rawQuery(
                        'SELECT count(*) AS n, sum(value) AS total FROM items'))
                    .single,
                {'n': 600, 'total': 179700});
          }));
  register(
      'extreme exponents use fallback without overflow',
      () => _fixture((init) async {
            await init.database.insert('items', {
              'id': 1,
              'value': '1e-9223372036854775808',
              'score': '1e9999',
              'untouched': 'keep'
            });
            final target = _model(updated: true, required: true, value: -1);
            init.setTables([target, _sentinel]);
            expect(await init.initDatabase('conversion'),
                DBInitializationResult.ready);
            expect(await init.database.query('items'), [
              {'id': 1, 'value': -1, 'score': null, 'untouched': 'keep'}
            ]);
          }));
  register(
      'unusable target default preserves original database',
      () => _fixture((init) async {
            await init.database.insert(
                'items', {'id': 1, 'value': 'bad', 'untouched': 'keep'});
            init.setTables([
              _model(updated: true, required: true, value: 'also bad'),
              _sentinel
            ]);
            await expectLater(
                init.initDatabase('conversion'), throwsArgumentError);
            expect(init.hasInit, isFalse);
            init.setTables([_model(), _sentinel]);
            await init.initDatabase('conversion', updateDB: false);
            expect((await init.database.query('items')).single['value'], 'bad');
            expect(await init.database.query('sentinel'), [
              {'id': 99}
            ]);
          }));
}

Future<void> _fixture(Future<void> Function(TunaiDBInitializer) body) async {
  final init = TunaiDBInitializer()
    ..setDBName('conversion_${DateTime.now().microsecondsSinceEpoch}')
    ..setTables([_model(), _sentinel])
    ..setTriggers([]);
  String? path;
  try {
    await init.initDatabase('conversion');
    path = init.database.path;
    await init.database.insert('sentinel', {'id': 99});
    await body(init);
  } finally {
    await init.close();
    init
      ..setTables([])
      ..setTriggers([])
      ..setDBName('tunaiDB');
    if (path != null) await deleteDatabase(path);
  }
}
