import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import 'package:tunai_db/tunai_db.dart';

import '../lab_case.dart';
import '../lab_database.dart';

List<LabCase> safetyCases() => [
  LabCase(
    'safety-mutation-scope',
    'Safety regressions',
    'Quoted and hostile text cannot widen update, count or delete',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      const hostile = "unknown' OR 1=1 --";
      await db.insertList([
        item(1, name: "O'Brien"),
        item(2, name: hostile),
        item(3, name: 'keep'),
      ]);
      await db.update(
        newData: {'note': 'changed'},
        filters: [const DBFilter(fieldName: 'name', matched: hostile)],
      );
      equal(
        (await db.fetch(
          filters: [const DBFilter(fieldName: 'id', matched: 3)],
        )).single['note'],
        null,
        'Unselected row remains unchanged',
      );
      equal(
        await db.getCount(
          filters: [const DBFilter(fieldName: 'name', matched: hostile)],
        ),
        1,
        'Count binds the literal',
      );
      await db.delete([
        const DBFilterIn(fieldName: 'name', matched: ["O'Brien", hostile]),
      ]);
      equal((await db.fetch()).single['id'], 3, 'Delete keeps unrelated rows');
      await db.delete([const DBFilterIn(fieldName: 'id', matched: [])]);
      equal(await db.getCount(), 1, 'Empty IN never deletes all rows');
    },
    crucial: true,
  ),
  LabCase(
    'safety-composite-scope',
    'Safety regressions',
    'Nested OR filters remain grouped inside AND selections',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await db.insertList([
        item(1, group: 1),
        item(2, group: 2),
        item(3, group: 1),
      ]);
      const filters = [
        CompositeDBFilter(
          filterJoinType: DBFilterJoinType.or,
          filters: [
            DBFilter(fieldName: 'id', matched: 1),
            DBFilter(fieldName: 'id', matched: 2),
          ],
        ),
        DBFilter(fieldName: 'groupID', matched: 2),
      ];
      equal(
        (await db.fetch(filters: filters)).single['id'],
        2,
        'OR must not escape AND scope',
      );
      await db.delete(filters);
      equal(await db.getCount(), 2, 'Only the scoped row is deleted');
      await rejects(
        () => db.delete([
          const CompositeDBFilter(
            filterJoinType: DBFilterJoinType.and,
            filters: [],
          ),
        ]),
      );
      equal(await db.getCount(), 2, 'Empty composite cannot erase a table');
    },
    crucial: true,
  ),
  LabCase(
    'safety-scalar-roundtrip',
    'Safety regressions',
    'Bound writes preserve scalar types and blobs; unsafe text rejects',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      final bytes = Uint8List.fromList([0, 39, 128, 255]);
      await db.insert({
        'id': 1,
        'groupID': true,
        'name': "a'b 中文",
        'amount': 1.25,
        'note': bytes,
      });
      final row = (await db.fetch(
        filters: [const DBFilter(fieldName: 'name', matched: "a'b 中文")],
      )).single;
      equal(row['name'], "a'b 中文", 'Quoted Unicode text');
      equal(row['note'], bytes, 'Blob bytes');
      equal(row['groupID'], 1, 'Boolean SQLite encoding');
      equal(row['amount'], 1.25, 'Real value');
      await rejects(() => db.insert({'id': 2, 'amount': double.nan}));
      equal(await db.getCount(), 1, 'Invalid scalar rejects without a write');
      final invalid = {'id': 2, 'name': 'a\u0000b'};
      await rejects(
        () => db.insert(invalid),
        accepts: (e) => e is ArgumentError,
      );
      await rejects(
        () => db.insertList([invalid]),
        accepts: (e) => e is ArgumentError,
      );
      await rejects(
        () => db.insertJsons([invalid]),
        accepts: (e) => e is ArgumentError,
      );
      await rejects(
        () => db.update(
          newData: {'name': 'a\u0000b'},
          filters: [const DBFilter(fieldName: 'id', matched: 1)],
        ),
        accepts: (e) => e is ArgumentError,
      );
      equal(await db.getCount(), 1, 'NUL text rejects across all write APIs');
      equal(
        (await db.fetch()).single['name'],
        "a'b 中文",
        'Rejected update preserves the original text',
      );
    },
    crucial: true,
  ),
  LabCase(
    'safety-primary-only',
    'Safety regressions',
    'Primary-key-only upserts retain defaults and existing values',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await db.insert({'id': 1});
      await db.update(
        newData: {'name': 'keep'},
        filters: [const DBFilter(fieldName: 'id', matched: 1)],
      );
      await db.insert({'id': 1});
      await db.insertList([
        {'id': 1},
        {'id': 2},
      ]);
      await db.insertJsons([
        {'id': 1},
        {'id': 3},
      ]);
      equal(await db.getCount(), 3, 'Primary-key-only rows insert and upsert');
      equal(
        (await db.fetch(
          filters: [const DBFilter(fieldName: 'id', matched: 1)],
        )).single['name'],
        'keep',
        'No empty UPDATE clause or data loss',
      );
    },
    crucial: true,
  ),
  LabCase(
    'safety-converter-rollback',
    'Safety regressions',
    'A later converter error rolls back previous batches in its transaction',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await rejects(
        () => db.insertList(
          [item(1), item(2)],
          batchSize: 1,
          toMap: (row) {
            if (row['id'] == 2) {
              throw const FormatException('Invalid source row');
            }
            return row;
          },
        ),
        accepts: (e) => e is FormatException,
      );
      equal(await db.getCount(), 0, 'First executed batch rolled back');
      await db.insert(item(3));
      equal(await db.getCount(), 1, 'Queue accepts a subsequent write');
    },
    crucial: true,
  ),
  LabCase(
    'safety-invalid-write-contract',
    'Safety regressions',
    'All insert APIs reject absent modeled keys and invalid batch sizes',
    (f) async {
      const table = DBTable(
        tableName: 'unkeyed',
        fields: [DBField(fieldName: 'name', fieldType: DBFieldType.text)],
      );
      await f.open([table]);
      final db = RowDB(table);
      await rejects(
        () => db.insert({'name': 'one'}),
        accepts: (e) => e is StateError,
      );
      await rejects(
        () => db.insertList([
          {'name': 'two'},
        ]),
        accepts: (e) => e is StateError,
      );
      await rejects(
        () => db.insertJsons([
          {'name': 'three'},
        ]),
        accepts: (e) => e is StateError,
      );
      equal(await db.getCount(), 0, 'No silent successful writes');
      await rejects(
        () => db.insertList([], batchSize: 0),
        accepts: (e) => e is ArgumentError,
      );
      await rejects(
        () => db.insertList([], transactionSize: -1),
        accepts: (e) => e is ArgumentError,
      );
    },
    crucial: true,
  ),
  LabCase(
    'safety-repeated-keys',
    'Safety regressions',
    'Repeated keys in batch and JSON upserts keep the final value',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await db.insertList([item(1, name: 'first'), item(1, name: 'last')]);
      equal((await db.fetch()).single['name'], 'last', 'Batch last value');
      await db.insertJsons([
        item(1, name: 'json first'),
        item(1, name: 'json last'),
      ]);
      equal((await db.fetch()).single['name'], 'json last', 'JSON last value');
    },
    crucial: true,
  ),
  LabCase(
    'safety-conflicts',
    'Safety regressions',
    'Default upsert preserves child rows; explicit conflict policies are honored',
    (f) async {
      await f.open([itemTable]);
      await f.raw.execute('PRAGMA foreign_keys=ON');
      await f.raw.execute(
        'CREATE TABLE child(id INTEGER REFERENCES items(id) ON DELETE CASCADE)',
      );
      final db = RowDB(itemTable);
      await db.insert(item(1, name: 'first'));
      await f.raw.insert('child', {'id': 1});
      await db.insert(item(1, name: 'upsert'));
      equal(
        (await f.raw.query('child')).length,
        1,
        'Upsert must not delete/reinsert a parent',
      );
      await db.insert(
        item(1, name: 'ignored'),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      equal((await db.fetch()).single['name'], 'upsert', 'Explicit ignore');
      await rejects(
        () => db.insert(item(1), conflictAlgorithm: ConflictAlgorithm.abort),
      );
      equal(
        (await f.raw.query('child')).length,
        1,
        'Failed insert retains children',
      );
    },
    crucial: true,
  ),
  LabCase(
    'safety-search-literals',
    'Safety regressions',
    'Search handles quotes, backslashes, wildcards and case-sensitive literals',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      const value = "O'Brien 100%_\\[x]";
      await db.insertList([
        item(1, name: value),
        item(2, name: value.toLowerCase()),
        item(3, name: 'other'),
      ]);
      equal(
        (await db.fetch(
          filters: [
            const DBSearchFilter(
              fieldName: 'name',
              searchValue: value,
              ignoreSpaces: false,
            ),
          ],
        )).length,
        2,
        'Default ASCII case folding and literal wildcards',
      );
      equal(
        (await db.fetch(
          filters: [
            const DBSearchFilter(
              fieldName: 'name',
              searchValue: value,
              caseSensitive: true,
              ignoreSpaces: false,
            ),
          ],
        )).single['id'],
        1,
        'Case-sensitive literal search',
      );
      // Compatibility SQL from getQuery must also escape values safely.
      equal(
        (await f.raw.rawQuery(
          'SELECT id FROM items WHERE ${const DBFilter(fieldName: 'name', matched: value).getQuery()}',
        )).single['id'],
        1,
        'Legacy getQuery remains safe',
      );
    },
    crucial: true,
  ),
  LabCase(
    'safety-join-bindings',
    'Safety regressions',
    'All join builders bind quoted filters and keep table filter groups scoped',
    (f) async {
      await f.open([itemTable, groupTable]);
      final db = RowDB(itemTable);
      await RowDB(groupTable).insertList([
        {'groupID': 1, 'label': "O'Brien"},
        {'groupID': 2, 'label': 'other'},
      ]);
      await db.insertList([
        item(1, group: 2, name: "O'Brien"),
        item(2, group: 1),
        item(3, group: 2),
      ]);
      final records = await db.fetchWithTables(
        tableRecords: [
          DBInnerJoinTable(
            key: 'groupID',
            table: groupTable,
            matchedTable: itemTable,
          ),
        ],
        filters: [
          (
            filter: const DBFilter(fieldName: 'label', matched: "O'Brien"),
            matchedTable: groupTable,
          ),
        ],
      );
      equal(records.single['items_id'], 2, 'Table-record filter binding');
      final left = await db.fetchWithLeftJoins(
        leftJoins: [
          DBLeftJoin(
            joinedTable: groupTable,
            mainTableName: 'items',
            joinedTableForeignKey: 'groupID',
            mainTablePrimaryKey: 'groupID',
          ),
        ],
        filters: [
          const DBFilter(fieldName: 'groups.label', matched: "O'Brien"),
        ],
      );
      equal(left.single['id'], 2, 'Left-join filter binding');
      final joined = await TunaiJoinedDB().fetch(
        mainTable: const JoinedDB(
          table: itemTable,
          tag: 'i',
          filterJoinType: DBFilterJoinType.or,
          filters: [
            DBFilter(fieldName: 'name', matched: "O'Brien"),
            DBFilter(fieldName: 'id', matched: 2),
          ],
        ),
        joinedTables: [
          const LeftJoinedDB(
            table: groupTable,
            tag: 'g',
            onClause: LeftJoinOnClause(
              field1: 'i.groupID',
              field2: 'g.groupID',
            ),
            filters: [DBFilter(fieldName: 'label', matched: "O'Brien")],
          ),
          const LeftJoinedDB(
            table: groupTable,
            tag: 'h',
            onClause: LeftJoinOnClause(
              field1: 'i.groupID',
              field2: 'h.groupID',
            ),
          ),
        ],
      );
      equal(
        joined.single['i_id'],
        2,
        'OR main filter cannot bypass a joined-table filter',
      );
    },
    crucial: true,
  ),
  LabCase(
    'safety-pagination-aggregate',
    'Safety regressions',
    'Offset-only and empty pages work; integer SUM returns a double',
    (f) async {
      await f.open([itemTable, groupTable]);
      final db = RowDB(itemTable);
      await db.insertList([item(1), item(2), item(3)]);
      equal((await db.fetch(offset: 1)).length, 2, 'Offset-only base read');
      equal(
        (await db.fetchWithLeftJoins(offset: 1)).length,
        2,
        'Offset-only optional joins',
      );
      final tables = [
        DBInnerJoinTable(
          key: 'groupID',
          table: groupTable,
          matchedTable: itemTable,
        ),
      ];
      equal(
        (await db.fetchWithTables(tableRecords: tables, offset: 1)).length,
        2,
        'Offset-only table records',
      );
      equal(
        (await db.fetchWithTables(tableRecords: tables, limit: 0)).length,
        0,
        'Zero limit',
      );
      equal(
        (await TunaiJoinedDB().fetch(
          mainTable: const JoinedDB(table: itemTable),
          joinedTables: [],
          offset: 1,
        )).length,
        2,
        'Offset-only standalone joins',
      );
      equal(await db.getSum('id'), 6.0, 'Integer SUM normalized to double');
    },
  ),
];
