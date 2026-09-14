import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart' as paths;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tunai_db/tunai_db.dart';

const _id = DBField(
  fieldName: 'id',
  fieldType: DBFieldType.integer,
  isPrimaryKey: true,
);
const _items = DBTable(tableName: 'items', fields: [
  _id,
  DBField(fieldName: 'value', fieldType: DBFieldType.integer, defaultValue: 7),
]);
const _other = DBTable(tableName: 'other', fields: [_id]);

void main() => runVersionZeroTests();

// Shared with the example's native integration entry point.
void runVersionZeroTests({bool native = false}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String path;
  late Database db;
  late DatabaseFactory factory;
  late PathProviderPlatform originalPaths;
  late _Logs logs;
  final initializer = TunaiDBInitializer();

  setUp(() async {
    originalPaths = PathProviderPlatform.instance;
    if (native) {
      if (Platform.isAndroid) sqfliteFfiInit();
      dir = Platform.isAndroid
          ? await paths.getApplicationSupportDirectory()
          : await paths.getLibraryDirectory();
    } else {
      dir = await Directory.systemTemp.createTemp('tunai-version-zero-');
      PathProviderPlatform.instance = _Paths(dir.path);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    factory =
        native && !Platform.isAndroid ? databaseFactory : databaseFactoryFfi;
    final name = 'version_zero_${DateTime.now().microsecondsSinceEpoch}';
    path = '${dir.path}/${name}_test.db';
    db = await factory.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    logs = _Logs();
    TunaiDBInitializer.setLogger(logs);
    initializer
      ..setDBName(name)
      ..setTables([_items, _other])
      ..setTriggers([]);
  });

  tearDown(() async {
    await initializer.close();
    if (db.isOpen) await db.close();
    await factory.deleteDatabase(path);
    initializer
      ..setDBName('tunaiDB')
      ..setTables([])
      ..setTriggers([]);
    TunaiDBInitializer.setLogger(TunaiDBLoggerImpl());
    PathProviderPlatform.instance = originalPaths;
    if (!native) await dir.delete(recursive: true);
  });

  Future<void> verifyReady() async {
    expect(initializer.hasInit, isTrue);
    expect(
      (await initializer.database.rawQuery('PRAGMA quick_check'))
          .map((row) => row.values.single),
      ['ok'],
    );
    expect(await initializer.database.rawQuery('PRAGMA foreign_key_check'),
        isEmpty);
    expect(await initializer.database.getVersion(), 1);
  }

  test('version zero matching populated schema preserves rows and reopens',
      () async {
    await db.execute(_items.createTableQuery);
    await db.execute(_other.createTableQuery);
    await db.insert('items', {'id': 1, 'value': 42});
    expect(await db.getVersion(), 0);
    await db.close();
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    expect(await initializer.database.query('items'), [
      {'id': 1, 'value': 42}
    ]);
    expect(initializer.rebuiltTables, isEmpty);
    expect(logs.events.any((e) => e.contains('existing_schema_detected;')),
        isTrue);
    expect(logs.events.any((e) => e.contains('creating_table;')), isFalse);
    await verifyReady();
    await initializer.database.insert('items', {'id': 2});
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    expect(await initializer.database.query('items', orderBy: 'id'), [
      {'id': 1, 'value': 42},
      {'id': 2, 'value': 7},
    ]);
  });

  test('version zero partial schema migrates values and creates missing table',
      () async {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value TEXT)');
    await db.insert('items', {'id': 1, 'value': '42'});
    await db.close();
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    expect(await initializer.database.query('items'), [
      {'id': 1, 'value': 42}
    ]);
    await initializer.database.insert('other', {'id': 2});
    await verifyReady();
  });

  test('version zero incompatible identity recovers only affected tables',
      () async {
    await db.execute(
        'CREATE TABLE items(id TEXT PRIMARY KEY NOT NULL, value INTEGER)');
    await db.insert('items', {'id': 'not-a-number', 'value': 42});
    await db.execute(_other.createTableQuery);
    await db.insert('other', {'id': 9});
    await db.close();
    expect(await initializer.initDatabase('test'),
        DBInitializationResult.tablesRebuilt);
    expect(initializer.rebuiltTables, {'items'});
    expect(await initializer.database.query('items'), isEmpty);
    expect(await initializer.database.query('other'), [
      {'id': 9}
    ]);
    await verifyReady();
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
  });

  test('version zero view occupying table name reaches recovery', () async {
    await db.execute(_other.createTableQuery);
    await db.insert('other', {'id': 9});
    await db.execute('CREATE VIEW items AS SELECT id, 7 AS value FROM other');
    await db.close();
    await initializer.initDatabase('test');
    expect(await initializer.database.query('other'), [
      {'id': 9}
    ]);
    await initializer.database.insert('items', {'id': 1});
    await verifyReady();
  });

  test('version zero invalid target preserves partial schema and allows retry',
      () async {
    await db.execute(_items.createTableQuery);
    await db.insert('items', {'id': 1, 'value': 42});
    await db.close();
    initializer.setTables([_items, _other, _other]);
    await expectLater(initializer.initDatabase('test'), throwsArgumentError);
    expect(initializer.hasInit, isFalse);
    db = await factory.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    expect(await db.query('items'), [
      {'id': 1, 'value': 42}
    ]);
    expect(
        await db.rawQuery("SELECT name FROM sqlite_master WHERE name='other'"),
        isEmpty);
    await db.close();
    initializer.setTables([_items, _other]);
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    expect(await initializer.database.query('items'), [
      {'id': 1, 'value': 42}
    ]);
  });

  test('version zero update disabled does not silently enable reconciliation',
      () async {
    await db.execute(_items.createTableQuery);
    await db.insert('items', {'id': 1, 'value': 42});
    await db.close();
    await expectLater(
        initializer.initDatabase('test', updateDB: false), throwsA(anything));
    expect(initializer.hasInit, isFalse);
    db = await factory.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    expect(await db.query('items'), [
      {'id': 1, 'value': 42}
    ]);
    expect(await db.getVersion(), 0);
  });

  test('empty version zero database still creates usable schema', () async {
    await db.close();
    expect(
        await initializer.initDatabase('test'), DBInitializationResult.ready);
    await initializer.database.insert('items', {'id': 1});
    expect(await initializer.database.query('items'), [
      {'id': 1, 'value': 7}
    ]);
    expect(logs.events.any((e) => e.contains('creation_started;')), isTrue);
    await verifyReady();
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

class _Logs extends TunaiDBLoggerImpl {
  final events = <String>[];
  @override
  void logInit(String message) => events.add(message);
}
