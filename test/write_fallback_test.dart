import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tunai_db/tunai_db.dart';

// Each test file has its own isolate. Attaching a handle before initDatabase
// leaves capability detection false and exercises the pre-UPSERT code path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database raw;
  final db = _Rows();
  setUp(() async {
    sqfliteFfiInit();
    raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await raw.execute(
        'CREATE TABLE rows(id INTEGER PRIMARY KEY, value TEXT UNIQUE)');
    TunaiDBInitializer().initExistingDatabase(raw);
    expect(TunaiDBInitializer.isSupportUpsert, isFalse);
  });
  tearDown(() => TunaiDBInitializer().close());

  test('fallback batch upserts duplicate new keys and preserves NULL',
      () async {
    await db.insertList([
      {'id': 1, 'value': 'first'},
      {'id': 1, 'value': null}
    ]);
    expect(await db.fetch(), [
      {'id': 1, 'value': null}
    ]);
    await db.insertList([
      {'id': 1},
      {'id': 2, 'value': "O'Brien"}
    ]);
    expect(await db.getCount(), 2);
    expect(
        (await db.fetch(filters: [const DBFilter(fieldName: 'id', matched: 1)]))
            .single['value'],
        isNull);
  });

  test('fallback JSON upserts see previous entries in the same transaction',
      () async {
    await db.insertJsons([
      {'id': 1, 'value': 'first'},
      {'id': 1, 'value': 'last'}
    ]);
    expect((await db.fetch()).single['value'], 'last');
  });

  test('fallback constraints throw, roll back and leave queue usable',
      () async {
    await expectLater(
        db.insertList([
          {'id': 1, 'value': 'same'},
          {'id': 2, 'value': 'same'}
        ]),
        throwsA(isA<DatabaseException>()));
    expect(await db.getCount(), 0);
    await db.insert({'id': 3, 'value': 'good'});
    await expectLater(db.insert({'id': 4, 'value': 'good'}),
        throwsA(isA<DatabaseException>()));
    expect(await db.getCount(), 1);
  });

  test('fallback conversion failures roll back earlier batches', () async {
    await expectLater(
        db.insertList([
          {'id': 1},
          {'id': 2}
        ], batchSize: 1, toMap: (row) {
          if (row['id'] == 2) throw const FormatException('bad source');
          return row;
        }),
        throwsA(isA<FormatException>()));
    expect(await db.getCount(), 0);
  });
}

class _Rows extends TunaiDB<Map<String, Object?>> {
  @override
  DBTable get table => const DBTable(tableName: 'rows', fields: [
        DBField(
            fieldName: 'id',
            fieldType: DBFieldType.integer,
            isPrimaryKey: true),
        DBField(
            fieldName: 'value', fieldType: DBFieldType.text, isNotNull: false),
      ]);
  @override
  DBDataConverter<Map<String, Object?>> get dbTableDataConverter =>
      _Converter();
}

class _Converter extends DBDataConverter<Map<String, Object?>> {
  @override
  Map<String, Object?> fromMap(Map<String, Object?> map) => map;
  @override
  Map<String, Object?> toMap(Map<String, Object?> map) => map;
}
