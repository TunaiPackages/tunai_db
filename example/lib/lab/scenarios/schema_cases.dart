import 'package:tunai_db/tunai_db.dart';

import '../lab_case.dart';
import '../lab_database.dart';

const _id = DBField(
  fieldName: 'id',
  fieldType: DBFieldType.integer,
  isPrimaryKey: true,
);
DBTable _schema({
  Object? value = 0,
  bool nullable = false,
  DBFieldType type = DBFieldType.integer,
}) => DBTable(
  tableName: 'probe',
  fields: [
    _id,
    DBField(
      fieldName: 'value',
      fieldType: type,
      defaultValue: value,
      isNotNull: !nullable,
      indexing: true,
    ),
  ],
);
Future<Object?> _default(LabDatabase f) async => (await f.raw.rawQuery(
  'PRAGMA table_info(probe)',
)).singleWhere((c) => c['name'] == 'value')['dflt_value'];
Future<void> _legacy(
  LabDatabase f, {
  String column = 'INTEGER NOT NULL',
  String suffix = '',
}) async {
  await f.open([]);
  await f.raw.execute(
    'CREATE TABLE probe(id INTEGER PRIMARY KEY NOT NULL,value $column)$suffix',
  );
}

List<LabCase> schemaCases() => [
  LabCase(
    'schema-legacy-color',
    'Schema updates',
    'Legacy appointment color default upgrades without losing rows',
    (f) async {
      await f.open([]);
      await f.raw.execute(
        'CREATE TABLE base_appt(bookID INTEGER PRIMARY KEY NOT NULL,colorID INTEGER NOT NULL,notes TEXT)',
      );
      await f.raw.insert('base_appt', {
        'bookID': 42,
        'colorID': 7,
        'notes': null,
      });
      const table = DBTable(
        tableName: 'base_appt',
        fields: [
          DBField(
            fieldName: 'bookID',
            fieldType: DBFieldType.integer,
            isPrimaryKey: true,
          ),
          DBField(
            fieldName: 'colorID',
            fieldType: DBFieldType.integer,
            defaultValue: 0,
          ),
        ],
      );
      await f.reopen([table]);
      equal(await f.raw.query('base_appt'), [
        {'bookID': 42, 'colorID': 7, 'notes': null},
      ], 'Existing appointment retained');
      await f.raw.insert('base_appt', {'bookID': 43});
      equal(
        (await f.raw.query(
          'base_appt',
          where: 'bookID = ?',
          whereArgs: [43],
        )).single['colorID'],
        0,
        'Future inserts receive new default',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-add-column',
    'Schema updates',
    'New required columns fill populated tables from a declared default',
    (f) async {
      await f.open([]);
      await f.raw.execute(
        'CREATE TABLE probe(id INTEGER PRIMARY KEY NOT NULL)',
      );
      await f.raw.insert('probe', {'id': 1});
      await f.reconcile([_schema()]);
      equal(await f.raw.query('probe'), [
        {'id': 1, 'value': 0},
      ], 'New column backfill');
      check(
        (await f.raw.rawQuery('PRAGMA index_list(probe)')).isNotEmpty,
        'Declared index must exist',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-string-default',
    'Schema updates',
    'Nonempty quoted defaults and expression replacement',
    (f) async {
      await _legacy(f, column: "TEXT NOT NULL DEFAULT ('old' || ' value')");
      await f.raw.insert('probe', {'id': 1});
      await f.reconcile([_schema(value: "It's ready", type: DBFieldType.text)]);
      await f.raw.insert('probe', {'id': 2});
      equal(
        (await f.raw.query('probe', where: 'id=1')).single['value'],
        'old value',
        'Existing string unchanged',
      );
      equal(
        (await f.raw.query('probe', where: 'id=2')).single['value'],
        "It's ready",
        'Escaped new default',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-null-preservation',
    'Schema updates',
    'Changing a default never coalesces existing NULL values',
    (f) async {
      await _legacy(f, column: 'INTEGER');
      await f.raw.insert('probe', {'id': 1, 'value': null});
      await f.reconcile([_schema(nullable: true)]);
      equal(
        (await f.raw.query('probe')).single['value'],
        null,
        'NULL must remain NULL',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-rollback',
    'Schema updates',
    'Unsafe nullability change rolls back all selected tables',
    (f) async {
      await _legacy(f, column: 'INTEGER');
      await f.raw.insert('probe', {'id': 1, 'value': null});
      await rejects(() => f.reconcile([groupTable, _schema()]));
      equal(
        await f.raw.query(
          'sqlite_master',
          where: 'name = ?',
          whereArgs: ['groups'],
        ),
        [],
        'Unrelated creation must roll back too',
      );
      equal(await _default(f), null, 'Default change also rolls back');
      await f.raw.update('probe', {'value': 8});
      await f.reconcile([_schema()]);
      equal(
        await _default(f),
        '0',
        'Retry after correcting incompatibility succeeds',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-required-no-default',
    'Schema updates',
    'Required columns without defaults reject populated upgrades',
    (f) async {
      await f.open([]);
      await f.raw.execute(
        'CREATE TABLE probe(id INTEGER PRIMARY KEY NOT NULL)',
      );
      await f.raw.insert('probe', {'id': 1});
      await rejects(() => f.reconcile([_schema(value: null)]));
      equal(await f.raw.query('probe'), [
        {'id': 1},
      ], 'Original row/schema preserved');
      await f.raw.delete('probe');
      await f.reconcile([_schema(value: null)]);
      check(
        (await f.raw.rawQuery('PRAGMA table_info(probe)')).length == 2,
        'Empty table accepts required column',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-type-safe',
    'Schema updates',
    'Equivalent numeric declarations update without changing values',
    (f) async {
      await _legacy(f, column: 'INT NOT NULL');
      await f.raw.insert('probe', {'id': 1, 'value': 123});
      await f.reconcile([_schema()]);
      equal(
        (await f.raw.query('probe')).single['value'],
        123,
        'Value-preserving type change',
      );
    },
  ),
  LabCase(
    'schema-type-lossy',
    'Schema updates',
    'Lossy text-to-number conversion is rejected and rolled back',
    (f) async {
      await _legacy(f, column: 'TEXT NOT NULL');
      await f.raw.insert('probe', {'id': 1, 'value': '001'});
      await rejects(() => f.reconcile([_schema()]));
      equal(
        (await f.raw.query('probe')).single['value'],
        '001',
        'Leading zeros must not disappear',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-preserve-objects',
    'Schema updates',
    'Rebuild preserves extra columns, CHECK, UNIQUE, indexes, triggers and views',
    (f) async {
      await f.open([]);
      await f.raw.execute(
        'CREATE TABLE probe(id INTEGER PRIMARY KEY NOT NULL,value INTEGER NOT NULL,extra TEXT UNIQUE CHECK(length(extra)>0))',
      );
      await f.raw.execute('CREATE TABLE audit(value INTEGER)');
      await f.raw.execute('CREATE INDEX custom_index ON probe(extra)');
      await f.raw.execute('CREATE VIEW probe_view AS SELECT * FROM probe');
      await f.raw.execute(
        'CREATE TRIGGER custom_trigger AFTER INSERT ON probe BEGIN INSERT INTO audit VALUES(NEW.value); END',
      );
      await f.raw.insert('probe', {'id': 1, 'value': 7, 'extra': 'kept'});
      await f.reconcile([_schema()]);
      equal(await f.raw.query('probe_view'), [
        {'id': 1, 'value': 7, 'extra': 'kept'},
      ], 'View and extra data');
      await rejects(
        () => f.raw.insert('probe', {'id': 2, 'extra': 'kept'}).then((_) {}),
      );
      await rejects(
        () => f.raw.insert('probe', {'id': 2, 'extra': ''}).then((_) {}),
      );
      await f.raw.insert('probe', {'id': 2, 'extra': 'new'});
      equal(await f.raw.query('audit'), [
        {'value': 7},
        {'value': 0},
      ], 'Custom trigger still operates');
      check(
        (await f.raw.query(
              'sqlite_master',
              where: 'name = ?',
              whereArgs: ['custom_index'],
            )).length ==
            1,
        'Custom index retained',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-idempotence',
    'Schema updates',
    'Repeated reconciliation is a no-op and preserves unknown tables',
    (f) async {
      await f.open([_schema(), groupTable]);
      await f.raw.insert('groups', {'groupID': 7, 'label': 'keep'});
      final before = await f.raw.rawQuery('PRAGMA schema_version');
      await f.reconcile([_schema()]);
      equal(
        await f.raw.rawQuery('PRAGMA schema_version'),
        before,
        'No repeated rebuild',
      );
      equal(
        (await f.raw.query('groups')).single['label'],
        'keep',
        'Older registry must not delete newer data',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-foreign-keys',
    'Integrity',
    'Rebuild preserves foreign keys without firing delete cascades',
    (f) async {
      await _legacy(f);
      await f.raw.execute('PRAGMA foreign_keys=ON');
      await f.raw.execute(
        'CREATE TABLE child(id INTEGER PRIMARY KEY,parent INTEGER REFERENCES probe(id) ON DELETE CASCADE)',
      );
      await f.raw.insert('probe', {'id': 1, 'value': 7});
      await f.raw.insert('child', {'id': 9, 'parent': 1});
      await f.reconcile([_schema()]);
      equal(await f.raw.query('child'), [
        {'id': 9, 'parent': 1},
      ], 'Rebuild must not cascade delete');
      equal(
        await f.raw.rawQuery('PRAGMA foreign_key_check'),
        [],
        'No broken references',
      );
      equal(
        (await f.raw.rawQuery('PRAGMA foreign_keys')).single.values.single,
        1,
        'Foreign-key setting restored',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-fk-rollback',
    'Integrity',
    'Foreign-key validation failure restores PRAGMAs and old schema',
    (f) async {
      await _legacy(f);
      await f.raw.execute(
        'CREATE TABLE child(parent INTEGER REFERENCES probe(id))',
      );
      await f.raw.insert('child', {'parent': 99});
      await f.raw.execute('PRAGMA foreign_keys=ON');
      await rejects(() => f.reconcile([_schema()]));
      equal(await _default(f), null, 'Schema rolled back');
      equal(
        (await f.raw.rawQuery('PRAGMA foreign_keys')).single.values.single,
        1,
        'FK setting restored after failure',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-autoincrement',
    'Integrity',
    'Rebuild preserves AUTOINCREMENT high-water mark',
    (f) async {
      await f.open([]);
      await f.raw.execute(
        'CREATE TABLE probe(id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,value INTEGER NOT NULL)',
      );
      await f.raw.insert('probe', {'id': 100, 'value': 7});
      await f.raw.delete('probe');
      await f.reconcile([
        const DBTable(
          tableName: 'probe',
          fields: [
            DBField(
              fieldName: 'id',
              fieldType: DBFieldType.integer,
              isPrimaryKey: true,
              isAutoIncrement: true,
            ),
            DBField(
              fieldName: 'value',
              fieldType: DBFieldType.integer,
              defaultValue: 0,
            ),
          ],
        ),
      ]);
      equal(
        await f.raw.insert('probe', {'value': 7}),
        101,
        'Deleted row identity must not be reused',
      );
    },
    crucial: true,
  ),
  LabCase(
    'schema-generated',
    'Integrity',
    'Generated columns, rowids and STRICT options survive rebuild',
    (f) async {
      await f.open([]);
      await f.raw.execute(
        'CREATE TABLE probe(id TEXT PRIMARY KEY NOT NULL,value INTEGER NOT NULL,doubled INTEGER GENERATED ALWAYS AS(value*2) STORED) STRICT',
      );
      await f.raw.execute("INSERT INTO probe(rowid,id,value) VALUES(91,'a',4)");
      await f.reconcile([
        const DBTable(
          tableName: 'probe',
          fields: [
            DBField(
              fieldName: 'id',
              fieldType: DBFieldType.text,
              isPrimaryKey: true,
            ),
            DBField(
              fieldName: 'value',
              fieldType: DBFieldType.integer,
              defaultValue: 0,
            ),
          ],
        ),
      ]);
      equal(
        await f.raw.rawQuery('SELECT rowid,* FROM probe'),
        [
          {'rowid': 91, 'id': 'a', 'value': 4, 'doubled': 8},
        ],
        'Hidden identity and generated value',
      );
      check(
        ((await f.raw.query(
                  'sqlite_master',
                  where: 'name = ?',
                  whereArgs: ['probe'],
                )).single['sql']!
                as String)
            .endsWith('STRICT'),
        'STRICT option retained',
      );
    },
  ),
  LabCase(
    'schema-key-change',
    'Integrity',
    'Uninferable key changes reject without deleting data',
    (f) async {
      await f.open([]);
      await f.raw.execute(
        'CREATE TABLE probe(id INTEGER NOT NULL,value INTEGER NOT NULL)',
      );
      await f.raw.insert('probe', {'id': 1, 'value': 7});
      await rejects(() => f.reconcile([_schema()]));
      equal(await f.raw.query('probe'), [
        {'id': 1, 'value': 7},
      ], 'Key-change rejection preserves row');
    },
    crucial: true,
  ),
];
