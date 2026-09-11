import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tunai_db/tunai_db.dart';
import 'package:tunai_db/src/schema/schema_reconciler.dart';

const id = DBField(
    fieldName: 'id', fieldType: DBFieldType.integer, isPrimaryKey: true);
DBTable table(String name, {String? parent, bool incompatible = false}) =>
    DBTable(tableName: name, fields: [
      id,
      if (parent != null)
        DBField(
            fieldName: 'parent',
            fieldType: DBFieldType.integer,
            reference: DBReference(
                table: DBTable(tableName: parent, fields: const [id]),
                fieldName: 'id')),
      if (incompatible)
        const DBField(fieldName: 'required_new', fieldType: DBFieldType.text),
    ]);
void main() {
  sqfliteFfiInit();
  late Database db;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  });
  tearDown(() async {
    await db.close();
  });
  Future<DBInitializationResult> update(List<DBTable> tables,
          {List<DBTrigger> triggers = const [],
          bool recover = true,
          void Function(Set<String>)? names}) =>
      SchemaReconciler.update(db, tables,
          completeRegistry: true,
          recoverIncompatibleSchema: recover,
          triggers: triggers,
          onTablesRebuilt: names);
  Future<void> seed(List<DBTable> tables) async {
    await update(tables);
    for (final t in tables) {
      await db.insert(
          t.tableName, {'id': 1, if (t.foreignFields.isNotEmpty) 'parent': 1});
    }
  }

  test(
      'recovery clears only affected parent and transitive children, preserves other parent and unrelated rows',
      () async {
    final old = [
      table('a'),
      table('b', parent: 'a'),
      table('c', parent: 'b'),
      table('keep')
    ];
    await seed(old);
    Set<String>? names;
    final target = [table('a', incompatible: true), ...old.skip(1)];
    expect(await update(target, names: (n) => names = n),
        DBInitializationResult.tablesRebuilt);
    expect(names, {'a', 'b', 'c'});
    for (final name in ['a', 'b', 'c']) {
      expect(await db.query(name), isEmpty);
    }
    expect(await db.query('keep'), [
      {'id': 1}
    ]);
    expect(await update(target), DBInitializationResult.ready);
  });
  test('child recovery retains parent and unrelated tables', () async {
    final old = [table('a'), table('b', parent: 'a'), table('keep')];
    await seed(old);
    Set<String>? names;
    expect(
        await update(
            [old[0], table('b', parent: 'a', incompatible: true), old[2]],
            names: (n) => names = n),
        DBInitializationResult.tablesRebuilt);
    expect(names, {'b'});
    expect(await db.query('a'), hasLength(1));
    expect(await db.query('keep'), hasLength(1));
  });
  test('multiple failures accumulate atomically and recover cycles', () async {
    final old = [
      table('a', parent: 'b'),
      table('b', parent: 'a'),
      table('d'),
      table('keep')
    ];
    await seed(old);
    Set<String>? names;
    expect(
        await update([
          table('a', parent: 'b', incompatible: true),
          old[1],
          table('d', incompatible: true),
          old[3]
        ], names: (n) => names = n),
        DBInitializationResult.tablesRebuilt);
    expect(names, {'a', 'b', 'd'});
    expect(await db.query('keep'), hasLength(1));
  });
  test('old FK edges protect dependents even when removed in target', () async {
    final old = [table('a'), table('b', parent: 'a'), table('keep')];
    await seed(old);
    Set<String>? names;
    await update([table('a', incompatible: true), table('b'), old[2]],
        names: (n) => names = n);
    expect(names, {'a', 'b'});
    expect(await db.query('keep'), hasLength(1));
  });
  test('new FK violation clears child only', () async {
    await seed([table('a'), table('b'), table('keep')]);
    await db.execute('ALTER TABLE b ADD COLUMN parent INTEGER');
    await db.update('b', {'parent': 99});
    Set<String>? names;
    await update([table('a'), table('b', parent: 'a'), table('keep')],
        names: (n) => names = n);
    expect(names, {'b'});
    expect(await db.query('a'), hasLength(1));
    expect(await db.query('keep'), hasLength(1));
  });
  test(
      'empty primary key change preserves every unrelated row without recovery',
      () async {
    await seed([table('a'), table('keep')]);
    await db.delete('a');
    expect(
        await update([
          const DBTable(tableName: 'a', fields: [
            DBField(
                fieldName: 'new_id',
                fieldType: DBFieldType.text,
                isPrimaryKey: true)
          ]),
          table('keep')
        ]),
        DBInitializationResult.ready);
    expect(await db.query('keep'), hasLength(1));
  });
  test(
      'failed target trigger rolls back all scoped attempts and preserves original rows',
      () async {
    final old = [table('a'), table('keep')];
    await seed(old);
    await expectLater(
        update([
          table('a', incompatible: true),
          old[1]
        ], triggers: const [
          DBTrigger(
              name: 'bad',
              table: 'a',
              timing: TriggerTiming.after,
              event: TriggerEvent.insert,
              body: 'INVALID SQL;')
        ]),
        throwsA(isA<DatabaseException>()));
    expect(await db.query('a'), [
      {'id': 1}
    ]);
    expect(await db.query('keep'), [
      {'id': 1}
    ]);
    expect(
        await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE name LIKE '%__tunai_update%'"),
        isEmpty);
  });
  test('incomplete registry never discards data even when recovery requested',
      () async {
    await seed([table('a'), table('keep')]);
    await expectLater(
        SchemaReconciler.update(db, [table('a', incompatible: true)],
            recoverIncompatibleSchema: true),
        throwsA(anything));
    expect(await db.query('a'), hasLength(1));
    expect(await db.query('keep'), hasLength(1));
  });
}
