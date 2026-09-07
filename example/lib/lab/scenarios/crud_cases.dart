import 'dart:convert';

import 'package:tunai_db/tunai_db.dart';

import '../lab_case.dart';
import '../lab_database.dart';

List<LabCase> crudCases() => [
  LabCase(
    'crud-null-write',
    'Writes',
    'Nullable TEXT stays SQL NULL across every write API',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await db.insert(item(1));
      await db.insertList([item(2)]);
      await db.insertJsons([item(3)]);
      await db.insert(item(4, note: 'before'));
      await db.update(
        newData: item(4),
        filters: [const DBFilter(fieldName: 'id', matched: 4)],
      );
      final rows = await f.raw.query('items', orderBy: 'id');
      equal(
        rows.map((r) => r['note']).toList(),
        [null, null, null, null],
        'NULL must never become the literal text "null"',
      );
    },
    crucial: true,
  ),
  LabCase(
    'crud-chunk-failure',
    'Writes',
    'A failed later transaction preserves prior committed chunks',
    (f) async {
      await f.open([]);
      await f.raw.execute(
        'CREATE TABLE items (id INTEGER PRIMARY KEY, groupID INTEGER, name TEXT UNIQUE, amount REAL, note TEXT)',
      );
      final db = RowDB(itemTable);
      await rejects(
        () => db.insertList(
          [
            item(1, name: 'one'),
            item(2, name: 'two'),
            item(3, name: 'duplicate'),
            item(4, name: 'duplicate'),
          ],
          transactionSize: 2,
          batchSize: 2,
        ),
      );
      equal(
        (await db.fetch(
          sorter: const DBSorter(fieldName: 'id', sortType: DBSortType.asc),
        )).map((r) => r['id']).toList(),
        [1, 2],
        'Transaction chunks commit independently; failed chunk rolls back',
      );
      await db.insert(item(5, name: 'retry'));
      equal(
        await db.getCount(),
        3,
        'Queue recovers after partial batch failure',
      );
    },
    crucial: true,
  ),
  LabCase(
    'crud-roundtrip',
    'Writes',
    'Insert and converter round trip: Unicode, quotes and JSON',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      final row = item(
        1,
        name: "O'Brien / 中文 🌱",
        note: jsonEncode({
          'tags': ['a', 'b'],
          'enabled': true,
        }),
      );
      await db.insert(row);
      equal(await db.fetch(), [row], 'Stored values must round trip exactly');
    },
    crucial: true,
  ),
  LabCase(
    'crud-upsert',
    'Writes',
    'Upsert changes one identity without losing other columns',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await db.insert(item(1, note: 'keep'));
      await db.insert({'id': 1, 'name': 'Updated'});
      final rows = await db.fetch();
      check(
        rows.length == 1 &&
            rows.single['name'] == 'Updated' &&
            rows.single['note'] == 'keep',
        'Upsert must preserve omitted fields and one identity',
      );
    },
    crucial: true,
  ),
  LabCase(
    'crud-batch',
    'Writes',
    'Batch insertion crosses transaction boundaries (1,205 rows)',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await db.insertList(
        List.generate(1205, (i) => item(i + 1)),
        batchSize: 37,
        transactionSize: 300,
      );
      equal(await db.getCount(), 1205, 'Every batch row must persist');
      await db.insertList([item(1, name: 'new'), item(1205, name: 'last')]);
      equal(
        await db.getCount(),
        1205,
        'Batch upsert must not duplicate identities',
      );
    },
    crucial: true,
  ),
  LabCase('crud-json', 'Writes', 'Database-shaped JSON inserts and upserts', (
    f,
  ) async {
    await f.open([itemTable]);
    final db = RowDB(itemTable);
    await db.insertJsons([item(1), item(2)]);
    await db.insertJsons([item(1, name: 'changed')]);
    check(await db.getCount() == 2, 'JSON upsert must preserve identity');
    equal(
      (await db.fetch(
        filters: [const DBFilter(fieldName: 'id', matched: 1)],
      )).single['name'],
      'changed',
      'JSON write must be visible',
    );
  }),
  LabCase(
    'crud-scoped-update-delete',
    'Writes',
    'Update and delete affect only the selected rows',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await db.insertList([item(1), item(2), item(3)]);
      await db.update(
        newData: item(2, name: 'edited'),
        filters: [const DBFilter(fieldName: 'id', matched: 2)],
      );
      await db.delete([
        const DBFilterIn(fieldName: 'id', matched: [1, 3]),
      ]);
      equal(await db.fetch(), [
        item(2, name: 'edited'),
      ], 'Mutation filters must retain only edited row');
      await db.deleteAll();
      equal(await db.getCount(), 0, 'deleteAll must empty only this lab table');
    },
    crucial: true,
  ),
  LabCase(
    'crud-queue',
    'Writes',
    'Concurrent awaited writes finish without missing records',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await Future.wait(List.generate(40, (i) => db.insert(item(i + 1))));
      equal(await db.getCount(), 40, 'All queued writes must complete');
    },
    crucial: true,
  ),
  LabCase(
    'crud-constraint-rollback',
    'Writes',
    'A failed batch transaction rolls back and the queue recovers',
    (f) async {
      await f.open([]);
      await f.raw.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, groupID INTEGER NOT NULL DEFAULT 0, name TEXT NOT NULL UNIQUE, amount REAL NOT NULL DEFAULT 0, note TEXT)',
      );
      final db = RowDB(itemTable);
      await rejects(
        () => db.insertList([item(1, name: 'same'), item(2, name: 'same')]),
        accepts: (e) => e is Exception,
      );
      equal(
        await db.getCount(),
        0,
        'The failed transaction must not partially commit',
      );
      await db.insert(item(3, name: 'valid'));
      equal(
        await db.getCount(),
        1,
        'The write queue must work after a failure',
      );
    },
    crucial: true,
  ),
  LabCase(
    'crud-converter-write-error',
    'Writes',
    'Batch conversion errors must reach the caller',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable, converter: const _FailingConverter());
      await rejects(() => db.insertList([item(1), item(2)]));
    },
    crucial: true,
  ),
  LabCase(
    'crud-converter-read-error',
    'Writes',
    'Malformed rows are rejected by the read converter',
    (f) async {
      await f.open([itemTable]);
      await RowDB(itemTable).insert(item(2));
      await rejects(() async {
        await RowDB(itemTable, converter: const _FailingConverter()).fetch();
      }, accepts: (e) => e is FormatException);
    },
    crucial: true,
  ),
  LabCase(
    'crud-missing-key',
    'Writes',
    'Writes without a modeled primary key must reject',
    (f) async {
      const table = DBTable(
        tableName: 'no_key',
        fields: [DBField(fieldName: 'value', fieldType: DBFieldType.text)],
      );
      await f.open([table]);
      await rejects(() => RowDB(table).insert({'value': 'must not disappear'}));
    },
    crucial: true,
  ),
];

class _FailingConverter extends RowConverter {
  const _FailingConverter();
  void validate(Map<String, Object?> row) {
    if (row['id'] == 2) throw const FormatException('Synthetic invalid row');
  }

  @override
  Map<String, Object?> toMap(Map<String, Object?> row) {
    validate(row);
    return super.toMap(row);
  }

  @override
  Map<String, Object?> fromMap(Map<String, Object?> row) {
    validate(row);
    return super.fromMap(row);
  }
}
