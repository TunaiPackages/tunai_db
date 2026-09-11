import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tunai_db/tunai_db.dart';
import 'package:tunai_db/src/schema/schema_reconciler.dart';

const id = DBField(
  fieldName: 'id',
  fieldType: DBFieldType.integer,
  isPrimaryKey: true,
);
DBTable schema({bool required = true}) => DBTable(
      tableName: 'items',
      fields: [
        id,
        DBField(
          fieldName: 'value',
          fieldType: DBFieldType.integer,
          isNotNull: required,
          defaultValue: 0,
          indexing: true,
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Database db;
  late PathProviderPlatform paths;
  final initializer = TunaiDBInitializer();
  setUp(() async {
    paths = PathProviderPlatform.instance;
    dir = await Directory.systemTemp.createTemp('tunai-recovery-test-');
    PathProviderPlatform.instance = _Paths(dir.path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await databaseFactoryFfi.openDatabase(
      '${dir.path}/recovery_test.db',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await db.setVersion(1);
    await db.execute(
      'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value INTEGER)',
    );
    await db.execute('INSERT INTO items VALUES(1,NULL)');
    await db.execute('CREATE TABLE unregistered(secret TEXT)');
    await db.execute("INSERT INTO unregistered VALUES('keep on failure')");
    initializer
      ..setDBName('recovery')
      ..setTables([schema()])
      ..setTriggers([]);
  });
  tearDown(() async {
    await initializer.close();
    if (db.isOpen) await db.close();
    initializer
      ..setTables([])
      ..setTriggers([])
      ..setDBName('tunaiDB');
    PathProviderPlatform.instance = paths;
    await dir.delete(recursive: true);
  });

  test(
    'initialization rebuilds incompatible populated database and persists result',
    () async {
      await db.close();
      initializer.setTriggers(const [
        DBTrigger(
          name: 'insert_marker',
          table: 'items',
          timing: TriggerTiming.after,
          event: TriggerEvent.insert,
          body: 'UPDATE items SET value=5 WHERE id=NEW.id;',
        ),
      ]);
      expect(
        await initializer.initDatabase('test'),
        DBInitializationResult.tablesRebuilt,
      );
      expect(initializer.hasInit, isTrue);
      expect(initializer.rebuiltTables, {'items'});
      expect(await initializer.database.query('items'), isEmpty);
      expect(
        await initializer.database.query(
          'sqlite_master',
          where: 'name=?',
          whereArgs: ['unregistered'],
        ),
        isEmpty,
      );
      expect(
        await initializer.database.rawQuery('PRAGMA index_list(items)'),
        hasLength(1),
      );
      await initializer.database.insert('items', {'id': 2});
      expect((await initializer.database.query('items')).single['value'], 5);
      await initializer.close();
      expect(initializer.hasInit, isFalse);
      expect(() => initializer.database, throwsStateError);
      expect(
        await initializer.initDatabase('test'),
        DBInitializationResult.ready,
      );
      expect(initializer.rebuiltTables, isEmpty);
      expect((await initializer.database.query('items')).single['id'], 2);
    },
  );

  test('supported update preserves stored NULL and removes undeclared tables',
      () async {
    initializer.setTables([schema(required: false)]);
    await db.close();
    expect(
      await initializer.initDatabase('test'),
      DBInitializationResult.ready,
    );
    expect((await initializer.database.query('items')).single['value'], isNull);
    expect(
        await initializer.database.query('sqlite_master',
            where: 'name=?', whereArgs: ['unregistered']),
        isEmpty);
  });

  test(
    'bad replacement trigger rolls back entire rebuild and invalidates handle',
    () async {
      initializer.setTriggers(const [
        DBTrigger(
          name: 'broken',
          table: 'items',
          timing: TriggerTiming.after,
          event: TriggerEvent.insert,
          body: 'INVALID SQL;',
        ),
      ]);
      await expectLater(
        initializer.initDatabase('test', singleInstance: false),
        throwsA(isA<DatabaseException>()),
      );
      expect(initializer.hasInit, isFalse);
      expect(() => initializer.database, throwsStateError);
      expect((await db.query('items')).single['value'], isNull);
      expect(await db.query('unregistered'), hasLength(1));
      expect(await db.rawQuery('PRAGMA table_info(items)'), hasLength(2));
    },
  );

  test('partial update never rebuilds whole database', () async {
    await expectLater(
      initializer.updateTables(db, [schema()]),
      throwsA(isA<DatabaseException>()),
    );
    expect(await db.query('unregistered'), hasLength(1));
    expect((await db.query('items')).single['value'], isNull);
  });

  test('duplicate target declarations cannot trigger recovery', () async {
    final events = <String>[];
    await expectLater(
      SchemaReconciler.update(
        db,
        [schema(), schema()],
        recoverIncompatibleSchema: true,
        completeRegistry: true,
        logRecovery: events.add,
      ),
      throwsArgumentError,
    );
    expect(events, isEmpty);
    expect(await db.query('unregistered'), hasLength(1));
  });

  test('read-only failure cannot trigger recovery', () async {
    await db.close();
    db = await databaseFactoryFfi.openDatabase(
      '${dir.path}/recovery_test.db',
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    final events = <String>[];
    await expectLater(
      SchemaReconciler.update(
        db,
        [schema()],
        recoverIncompatibleSchema: true,
        completeRegistry: true,
        logRecovery: events.add,
      ),
      throwsA(isA<DatabaseException>()),
    );
    expect(events, isEmpty);
    expect(await db.query('unregistered'), hasLength(1));
  });

  test(
    'key incompatibility rebuilds and restores foreign key settings',
    () async {
      await db.execute('PRAGMA foreign_keys=ON');
      final events = <String>[];
      const target = DBTable(
        tableName: 'items',
        fields: [
          DBField(
            fieldName: 'newId',
            fieldType: DBFieldType.integer,
            isPrimaryKey: true,
          ),
        ],
      );
      expect(
        await SchemaReconciler.update(
          db,
          [target],
          recoverIncompatibleSchema: true,
          completeRegistry: true,
          logRecovery: events.add,
        ),
        DBInitializationResult.tablesRebuilt,
      );
      expect(await db.query('items'), isEmpty);
      expect(
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA foreign_keys')),
        1,
      );
      expect(events, [
        'schema_recovery: key_change; rebuilding_tables=items',
        'schema_recovery: tables_replacement_committed',
        'schema_recovery: rebuilt_empty_tables=items',
      ]);
    },
  );

  test('database-full error preserves rows and never starts recovery',
      () async {
    final pages =
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA page_count'))!;
    await db.rawQuery('PRAGMA max_page_count=$pages');
    final events = <String>[];
    await expectLater(
        SchemaReconciler.update(
            db,
            [
              schema(),
              const DBTable(tableName: 'unregistered', fields: [
                DBField(
                    fieldName: 'secret',
                    fieldType: DBFieldType.text,
                    isNotNull: false)
              ])
            ],
            recoverIncompatibleSchema: true,
            completeRegistry: true,
            logRecovery: events.add),
        throwsA(isA<DatabaseException>()));
    expect(events, isEmpty);
    expect((await db.query('items')).single['value'], isNull);
    expect(await db.query('unregistered'), hasLength(1));
  });

  test('valid quoted legacy SQL reconciles without losing rows', () async {
    await db.execute('DROP TABLE items');
    await db.execute(
        "CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, 'value' INTEGER)");
    await db.execute('INSERT INTO items VALUES(1,7)');
    await db.close();
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    expect((await initializer.database.query('items')).single['value'], 7);
  });

  test('legacy view occupying a registered table name recovers', () async {
    await db.execute('DROP TABLE items');
    await db.execute('CREATE VIEW items AS SELECT 1 AS id, 7 AS value');
    await db.close();
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    expect(await initializer.database.query('items'), isEmpty);
    await initializer.database.insert('items', {'id': 2});
  });

  test(
      'full model removes obsolete schema while retaining rows and is idempotent',
      () async {
    await db.execute('ALTER TABLE items ADD COLUMN obsolete TEXT');
    await db.execute('CREATE INDEX old_index ON items(obsolete)');
    await db.execute(
        'CREATE UNIQUE INDEX items_value_index ON items(value) WHERE value IS NOT NULL');
    await db.execute('CREATE VIEW old_view AS SELECT obsolete FROM items');
    await db.execute(
        'CREATE TRIGGER old_trigger AFTER INSERT ON items BEGIN UPDATE items SET obsolete=1; END');
    await db.update('items', {'value': 7, 'obsolete': 'discard'});
    await db.close();
    initializer.setTables([schema(required: false)]);
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    final connection = initializer.database;
    expect(await connection.query('items'), [
      {'id': 1, 'value': 7}
    ]);
    final objects = await connection.query('sqlite_master',
        where: "name NOT LIKE 'sqlite_%'");
    expect(
        objects.map((o) => o['name']).toSet(), {'items', 'items_value_index'});
    final version = Sqflite.firstIntValue(
        await connection.rawQuery('PRAGMA schema_version'));
    await initializer.close();
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    expect(
        Sqflite.firstIntValue(
            await initializer.database.rawQuery('PRAGMA schema_version')),
        version);
    // Disabling indexing removes the physical index without clearing rows.
    initializer.setTables([
      const DBTable(tableName: 'items', fields: [
        id,
        DBField(
            fieldName: 'value',
            fieldType: DBFieldType.integer,
            isNotNull: false,
            defaultValue: 0)
      ])
    ]);
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    expect(await initializer.database.rawQuery('PRAGMA index_list(items)'),
        isEmpty);
    expect(await initializer.database.query('items'), [
      {'id': 1, 'value': 7}
    ]);
  });

  test(
      'removal and new required column failure roll back selected schema changes',
      () async {
    await db.execute('ALTER TABLE items ADD COLUMN obsolete TEXT');
    const invalid = DBTable(
        tableName: 'items',
        fields: [id, DBField(fieldName: 'added', fieldType: DBFieldType.text)]);
    await expectLater(
        SchemaReconciler.update(db, [invalid], completeRegistry: true),
        throwsA(isA<DatabaseException>()));
    expect(await db.query('unregistered'), hasLength(1));
    expect(
        (await db.rawQuery('PRAGMA table_info(items)')).map((c) => c['name']),
        ['id', 'value', 'obsolete']);
  });

  test('full model key change uses explicit last-resort recovery', () async {
    initializer.setTables([
      const DBTable(tableName: 'items', fields: [
        DBField(
            fieldName: 'newId',
            fieldType: DBFieldType.integer,
            isPrimaryKey: true),
        DBField(fieldName: 'value', fieldType: DBFieldType.integer),
      ])
    ]);
    await db.close();
    expect(await initializer.initDatabase('test'),
        DBInitializationResult.tablesRebuilt);
    expect(await initializer.database.query('items'), isEmpty);
    expect(
        (await initializer.database.rawQuery('PRAGMA table_info(items)'))
            .first['name'],
        'newId');
  });

  test('undeclared foreign key target fails without committing removals',
      () async {
    const parent = DBTable(tableName: 'missing_parent', fields: [id]);
    initializer.setTables([
      const DBTable(tableName: 'items', fields: [
        id,
        DBField(
            fieldName: 'value',
            fieldType: DBFieldType.integer,
            reference: DBReference(table: parent, fieldName: 'id')),
      ])
    ]);
    await expectLater(initializer.initDatabase('test', singleInstance: false),
        throwsArgumentError);
    expect(await db.query('unregistered'), hasLength(1));
    expect((await db.query('items')).single['value'], isNull);
  });

  test(
      'full model preserves related rows while removing columns and old constraints',
      () async {
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute(
        'CREATE TABLE parent(id INTEGER PRIMARY KEY NOT NULL, obsolete TEXT UNIQUE)');
    await db.execute(
        'CREATE TABLE child(id INTEGER PRIMARY KEY NOT NULL, parentId INTEGER NOT NULL REFERENCES parent(id) ON DELETE CASCADE)');
    await db.insert('parent', {'id': 1, 'obsolete': 'remove'});
    await db.insert('child', {'id': 2, 'parentId': 1});
    const parent = DBTable(tableName: 'parent', fields: [id]);
    const child = DBTable(tableName: 'child', fields: [
      id,
      DBField(
          fieldName: 'parentId',
          fieldType: DBFieldType.integer,
          reference: DBReference(table: parent, fieldName: 'id')),
    ]);
    expect(
        await SchemaReconciler.update(db, [parent, child],
            completeRegistry: true),
        DBInitializationResult.ready);
    expect(await db.query('parent'), [
      {'id': 1}
    ]);
    expect(await db.query('child'), [
      {'id': 2, 'parentId': 1}
    ]);
    expect(
        (await db.rawQuery('PRAGMA foreign_key_list(child)'))
            .single['on_delete'],
        'NO ACTION');
    expect(await db.rawQuery('PRAGMA index_list(parent)'), isEmpty);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('case-only column spelling changes preserve values', () async {
    await db.update('items', {'value': 7});
    initializer.setTables([
      const DBTable(tableName: 'items', fields: [
        id,
        DBField(
            fieldName: 'Value',
            fieldType: DBFieldType.integer,
            defaultValue: 0),
      ])
    ]);
    await db.close();
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    expect(await initializer.database.query('items'), [
      {'id': 1, 'Value': 7}
    ]);
  });

  test('empty complete registry removes all user objects', () async {
    initializer.setTables([]);
    await db.close();
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    expect(
        await initializer.database
            .query('sqlite_master', where: "name NOT LIKE 'sqlite_%'"),
        isEmpty);
  });

  test('updateDB false does not reconcile or rebuild', () async {
    await db.close();
    expect(
      await initializer.initDatabase('test', updateDB: false),
      DBInitializationResult.ready,
    );
    expect((await initializer.database.query('items')).single['value'], isNull);
    expect(await initializer.database.query('unregistered'), hasLength(1));
  });
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getLibraryPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
