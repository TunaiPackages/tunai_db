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
        DBInitializationResult.rebuilt,
      );
      expect(initializer.hasInit, isTrue);
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
      expect((await initializer.database.query('items')).single['id'], 2);
    },
  );

  test('supported update preserves stored NULL and unknown objects', () async {
    initializer.setTables([schema(required: false)]);
    await db.close();
    expect(
      await initializer.initDatabase('test'),
      DBInitializationResult.ready,
    );
    expect((await initializer.database.query('items')).single['value'], isNull);
    expect(await initializer.database.query('unregistered'), hasLength(1));
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
          logRecovery: events.add,
        ),
        DBInitializationResult.rebuilt,
      );
      expect(await db.query('items'), isEmpty);
      expect(
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA foreign_keys')),
        1,
      );
      expect(events, [
        'schema_recovery: new_key; rebuilding',
        'schema_recovery: replacement_committed',
        'schema_recovery: rebuilt_empty_database',
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
        SchemaReconciler.update(db, [schema()],
            recoverIncompatibleSchema: true, logRecovery: events.add),
        throwsA(isA<DatabaseException>()));
    expect(events, isEmpty);
    expect((await db.query('items')).single['value'], isNull);
    expect(await db.query('unregistered'), hasLength(1));
  });

  test('valid legacy SQL outside parser support rebuilds instead of blocking',
      () async {
    await db.execute('DROP TABLE items');
    await db.execute(
        "CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, 'value' INTEGER)");
    await db.execute('INSERT INTO items VALUES(1,7)');
    await db.close();
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.rebuilt);
    expect(await initializer.database.query('items'), isEmpty);
  });

  test('legacy view occupying a registered table name recovers', () async {
    await db.execute('DROP TABLE items');
    await db.execute('CREATE VIEW items AS SELECT 1 AS id, 7 AS value');
    await db.close();
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.rebuilt);
    expect(await initializer.database.query('items'), isEmpty);
    await initializer.database.insert('items', {'id': 2});
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
