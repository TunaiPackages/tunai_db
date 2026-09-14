import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:tunai_db/tunai_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  const id = DBField(
      fieldName: 'id', fieldType: DBFieldType.integer, isPrimaryKey: true);
  DBTable schema(
          {Object? value = 0,
          bool nullable = false,
          DBFieldType type = DBFieldType.integer}) =>
      DBTable(tableName: 'items', fields: [
        id,
        DBField(
            fieldName: 'value',
            fieldType: type,
            defaultValue: value,
            isNotNull: !nullable,
            indexing: true)
      ]);
  Future<void> update(DBTable table) =>
      TunaiDBInitializer().updateTables(db, [table]);
  Future<Object?> defaultValue() async =>
      (await db.rawQuery('PRAGMA table_info(items)'))
          .firstWhere((r) => r['name'] == 'value')['dflt_value'];
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  });
  tearDown(() => db.close());

  test(
      'upgrades legacy defaults, keeps rows and unknown schema, and is idempotent',
      () async {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value INTEGER NOT NULL, extra TEXT UNIQUE CHECK(length(extra)>0))');
    await db.execute("INSERT INTO items VALUES(7,3,'kept')");
    await db.execute('CREATE TABLE audit(value INTEGER)');
    await db.execute('CREATE INDEX custom_index ON items(extra)');
    await db.execute(
        'CREATE TRIGGER custom_trigger AFTER INSERT ON items BEGIN INSERT INTO audit VALUES(NEW.value); END');
    await db.execute('CREATE VIEW item_view AS SELECT * FROM items');
    await update(schema());
    final version = await db.getVersion();
    final schemaVersion = await db.rawQuery('PRAGMA schema_version');
    await update(schema());
    expect(await db.rawQuery('PRAGMA schema_version'), schemaVersion);
    expect(await db.getVersion(), version);
    expect(await defaultValue(), '0');
    expect(await db.query('item_view'), [
      {'id': 7, 'value': 3, 'extra': 'kept'}
    ]);
    await db.execute("INSERT INTO items(id,extra) VALUES(8,'next')");
    expect(await db.query('audit'), [
      {'value': 0}
    ]);
    await expectLater(
        db.execute("INSERT INTO items(id,extra) VALUES(9,'kept')"),
        throwsA(isA<DatabaseException>()));
    expect(
        await db.query('sqlite_master',
            where: 'name = ?', whereArgs: ['custom_index']),
        hasLength(1));
  });

  test(
      'initDatabase updateDB repairs before triggers and false skips reconciliation',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('tunai-schema-init-');
    final originalProvider = PathProviderPlatform.instance;
    final originalFactory = databaseFactory;
    PathProviderPlatform.instance = _Paths(directory.path);
    databaseFactory = databaseFactoryFfi;
    final initializer = TunaiDBInitializer()..setDBName('startup');
    try {
      final seed = await databaseFactoryFfi
          .openDatabase('${directory.path}/startup_outlet.db');
      await seed.execute(
          'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value INTEGER NOT NULL)');
      await seed.execute('INSERT INTO items VALUES(1,7)');
      await seed.setVersion(1);
      await seed.close();
      initializer.setTables([
        schema(),
        const DBTable(tableName: 'audit', fields: [id])
      ]);
      initializer.setTriggers(const [
        DBTrigger(
            name: 'audit_insert',
            table: 'items',
            timing: TriggerTiming.after,
            event: TriggerEvent.insert,
            body: 'INSERT INTO audit(id) VALUES(NEW.id);')
      ]);
      await initializer.initDatabase('outlet', updateDB: false);
      expect(
          await initializer.database
              .query('sqlite_master', where: 'name = ?', whereArgs: ['audit']),
          isEmpty);
      await initializer.close();
      await initializer.initDatabase('outlet', updateDB: true);
      final opened = initializer.database;
      expect(
          (await opened.rawQuery('PRAGMA table_info(items)'))
              .last['dflt_value'],
          '0');
      expect(await opened.query('items'), [
        {'id': 1, 'value': 7}
      ]);
      await opened.execute('INSERT INTO items(id) VALUES(2)');
      expect(await opened.query('audit'), [
        {'id': 2}
      ]);
    } finally {
      await initializer.close();
      initializer
        ..initExistingDatabase(db)
        ..setTables([])
        ..setTriggers([])
        ..setDBName('tunaiDB');
      PathProviderPlatform.instance = originalProvider;
      databaseFactory = originalFactory;
      await directory.delete(recursive: true);
    }
  });

  test(
      'trigger replacement preserves literal case, unknown triggers and rolls back failures',
      () async {
    await db.execute('CREATE TABLE audit(value TEXT)');
    await update(schema());
    await db.execute(
        "CREATE TRIGGER registered AFTER INSERT ON items BEGIN INSERT INTO audit VALUES('Old'); END");
    await db.execute(
        "CREATE TRIGGER unknown AFTER INSERT ON items BEGIN SELECT 1; END");
    final initializer = TunaiDBInitializer()..initExistingDatabase(db);
    initializer.setTriggers(const [
      DBTrigger(
          name: 'registered',
          table: 'items',
          timing: TriggerTiming.after,
          event: TriggerEvent.insert,
          body: "INSERT INTO audit VALUES('old');")
    ]);
    await initializer.synchronizeTriggers();
    await db.execute('INSERT INTO items(id) VALUES(1)');
    expect(await db.query('audit'), [
      {'value': 'old'}
    ]);
    expect(
        await db
            .query('sqlite_master', where: 'name = ?', whereArgs: ['unknown']),
        hasLength(1));
    initializer.setTriggers(const [
      DBTrigger(
          name: 'registered',
          table: 'items',
          timing: TriggerTiming.after,
          event: TriggerEvent.insert,
          body: 'INVALID SQL;')
    ]);
    await expectLater(
        initializer.synchronizeTriggers(), throwsA(isA<DatabaseException>()));
    await db.execute('INSERT INTO items(id) VALUES(2)');
    expect(await db.query('audit'), [
      {'value': 'old'},
      {'value': 'old'}
    ]);
    initializer.setTriggers([]);
  });

  test('fresh creation adds indexes and uses escaped nonempty defaults',
      () async {
    await update(schema(value: "It's ready", type: DBFieldType.text));
    await db.execute('INSERT INTO items(id) VALUES(1)');
    expect((await db.query('items')).single['value'], "It's ready");
    expect(await db.rawQuery('PRAGMA index_list(items)'), hasLength(1));
  });

  test('adds required columns with defaults to populated tables', () async {
    await db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL)');
    await db.execute('INSERT INTO items VALUES(1)');
    await update(schema());
    expect(await db.query('items'), [
      {'id': 1, 'value': 0}
    ]);
  });

  test(
      'rewrites quoted and parenthesized defaults without changing existing NULLs',
      () async {
    await db.execute(
        "CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value TEXT DEFAULT ('old' || ' value'), \"extra, field\" TEXT DEFAULT 'keep, this')");
    await db.execute('INSERT INTO items(id,value) VALUES(1,NULL)');
    await update(
        schema(value: "It's new", type: DBFieldType.text, nullable: true));
    expect((await db.query('items')).single['value'], isNull);
    await db.execute('INSERT INTO items(id) VALUES(2)');
    expect(
        (await db.query('items', where: 'id=2')).single['value'], "It's new");
    expect((await db.query('items')).first['extra, field'], 'keep, this');
  });

  test('tightens nullability when all data satisfies it and can relax it',
      () async {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value INTEGER)');
    await db.execute('INSERT INTO items VALUES(1,7)');
    await update(schema());
    await expectLater(db.execute('INSERT INTO items VALUES(2,NULL)'),
        throwsA(isA<DatabaseException>()));
    await update(schema(nullable: true));
    await db.execute('INSERT INTO items VALUES(2,NULL)');
    expect((await db.query('items')).last['value'], isNull);
  });

  test('rolls back all schema and rows when required existing data is NULL',
      () async {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value INTEGER)');
    await db.execute('INSERT INTO items VALUES(1,NULL)');
    await expectLater(
        TunaiDBInitializer().updateTables(db, [
          const DBTable(tableName: 'new_table', fields: [id]),
          schema()
        ]),
        throwsA(isA<DatabaseException>()));
    expect(
        await db.query('sqlite_master',
            where: 'name = ?', whereArgs: ['new_table']),
        isEmpty);
    expect(await defaultValue(), isNull);
    expect((await db.query('items')).single['value'], isNull);
    await db.execute('UPDATE items SET value=3');
    await update(schema());
    expect(await defaultValue(), '0');
  });

  test(
      'allows empty-table required additions but rejects populated additions without a default',
      () async {
    await db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL)');
    await db.execute('INSERT INTO items VALUES(1)');
    await expectLater(
        update(schema(value: null)), throwsA(isA<DatabaseException>()));
    expect(await db.rawQuery('PRAGMA table_info(items)'), hasLength(1));
    await db.delete('items');
    await update(schema(value: null));
    expect(await db.rawQuery('PRAGMA table_info(items)'), hasLength(2));
  });

  test('rejects affinity conversions that alter stored values', () async {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value TEXT NOT NULL)');
    await db.execute("INSERT INTO items VALUES(1,'001')");
    await expectLater(update(schema()), throwsA(isA<StateError>()));
    expect((await db.query('items')).single['value'], '001');
    expect(
        (await db.rawQuery('PRAGMA table_info(items)')).last['type'], 'TEXT');
  });

  test('updates declared type when existing numeric values survive exactly',
      () async {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value INT NOT NULL)');
    await db.execute('INSERT INTO items VALUES(1,12)');
    await update(schema());
    expect((await db.query('items')).single['value'], 12);
    expect((await db.rawQuery('PRAGMA table_info(items)')).last['type'],
        'INTEGER');
  });

  test('preserves child foreign keys and does not fire delete cascades',
      () async {
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value INTEGER NOT NULL)');
    await db.execute(
        'CREATE TABLE child(id INTEGER PRIMARY KEY, parent INTEGER REFERENCES items(id) ON DELETE CASCADE)');
    await db.execute('INSERT INTO items VALUES(1,7)');
    await db.execute('INSERT INTO child VALUES(9,1)');
    await update(schema());
    expect(await db.query('child'), [
      {'id': 9, 'parent': 1}
    ]);
    expect(Sqflite.firstIntValue(await db.rawQuery('PRAGMA foreign_keys')), 1);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect(
        (await db.rawQuery('PRAGMA foreign_key_list(child)')).single['table'],
        'items');
  });

  test('restores PRAGMAs and rolls back when foreign-key validation fails',
      () async {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value INTEGER NOT NULL)');
    await db.execute('CREATE TABLE child(parent INTEGER REFERENCES items(id))');
    await db.execute('INSERT INTO child VALUES(42)');
    await db.execute('PRAGMA foreign_keys=ON');
    final legacyAlter = await db.rawQuery('PRAGMA legacy_alter_table');
    await expectLater(update(schema()), throwsA(isA<StateError>()));
    expect(await defaultValue(), isNull);
    expect(Sqflite.firstIntValue(await db.rawQuery('PRAGMA foreign_keys')), 1);
    expect(await db.rawQuery('PRAGMA legacy_alter_table'), legacyAlter);
  });

  test('preserves AUTOINCREMENT high-water mark after deleting highest row',
      () async {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, value INTEGER NOT NULL)');
    await db.execute('INSERT INTO items VALUES(100,7)');
    await db.delete('items');
    await update(const DBTable(tableName: 'items', fields: [
      DBField(
          fieldName: 'id',
          fieldType: DBFieldType.integer,
          isPrimaryKey: true,
          isAutoIncrement: true),
      DBField(
          fieldName: 'value', fieldType: DBFieldType.integer, defaultValue: 0)
    ]));
    await db.execute('INSERT INTO items(value) VALUES(7)');
    expect((await db.query('items')).single['id'], 101);
  });

  test('preserves hidden rowids, generated columns and STRICT table options',
      () async {
    await db.execute(
        'CREATE TABLE items(id TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL, doubled INTEGER GENERATED ALWAYS AS (value*2) STORED) STRICT');
    await db.execute("INSERT INTO items(rowid,id,value) VALUES(91,'a',4)");
    await update(const DBTable(tableName: 'items', fields: [
      DBField(fieldName: 'id', fieldType: DBFieldType.text, isPrimaryKey: true),
      DBField(
          fieldName: 'value', fieldType: DBFieldType.integer, defaultValue: 0)
    ]));
    expect(await db.rawQuery('SELECT rowid,* FROM items'), [
      {'rowid': 91, 'id': 'a', 'value': 4, 'doubled': 8}
    ]);
    expect(
        (await db.query('sqlite_master',
                where: 'name = ?', whereArgs: ['items']))
            .single['sql'],
        endsWith('STRICT'));
  });

  test(
      'preserves WITHOUT ROWID and named constraints when only default changes',
      () async {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value INTEGER CONSTRAINT required NOT NULL ON CONFLICT FAIL) WITHOUT ROWID');
    await db.execute('INSERT INTO items VALUES(1,7)');
    await update(schema());
    final sql = (await db
            .query('sqlite_master', where: 'name = ?', whereArgs: ['items']))
        .single['sql'] as String;
    expect(sql, contains('CONSTRAINT required NOT NULL ON CONFLICT FAIL'));
    expect(sql, endsWith('WITHOUT ROWID'));
    expect((await db.query('items')).single['value'], 7);
  });

  test(
      'separate handles serialize repeated rebuilds and preserve temp-name collisions',
      () async {
    final directory = await Directory.systemTemp.createTemp('tunai-schema-');
    final path = '${directory.path}/db.sqlite';
    final first = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final second = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      await first.execute(
          'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value INTEGER NOT NULL)');
      await first.execute('INSERT INTO items VALUES(1,7)');
      await first.execute('CREATE TABLE items__tunai_update(kept INTEGER)');
      await first.execute('INSERT INTO items__tunai_update VALUES(9)');
      await Future.wait([
        TunaiDBInitializer().updateTables(first, [schema()]),
        TunaiDBInitializer().updateTables(second, [schema()])
      ]);
      expect(await first.query('items'), [
        {'id': 1, 'value': 7}
      ]);
      expect(await first.query('items__tunai_update'), [
        {'kept': 9}
      ]);
    } finally {
      await first.close();
      await second.close();
      await directory.delete(recursive: true);
    }
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
