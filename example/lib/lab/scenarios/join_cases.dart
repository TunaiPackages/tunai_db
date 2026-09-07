import 'package:tunai_db/tunai_db.dart';

import '../lab_case.dart';
import '../lab_database.dart';

Future<RowDB> _seed(LabDatabase f) async {
  await f.open([itemTable, groupTable]);
  await RowDB(groupTable).insert({'groupID': 1, 'label': 'Members'});
  final db = RowDB(itemTable);
  await db.insertList([item(1), item(2, group: 99)]);
  return db;
}

DBLeftJoin _left() => DBLeftJoin(
  joinedTable: groupTable,
  mainTableName: 'items',
  joinedTableForeignKey: 'groupID',
  mainTablePrimaryKey: 'groupID',
  joinedTableAlias: 'g',
);
List<LabCase> joinCases() => [
  LabCase(
    'join-left',
    'Joins',
    'LEFT JOIN maps aliases and keeps unmatched rows',
    (f) async {
      final db = await _seed(f);
      final rows = await db.fetchWithLeftJoins(
        leftJoins: [_left()],
        sorter: const DBSorter(fieldName: 'id', sortType: DBSortType.asc),
      );
      check(rows.length == 2, 'LEFT JOIN must retain unmatched item');
      equal(rows[0]['g_label'], 'Members', 'Joined alias');
      equal(rows[1]['g_label'], null, 'Missing relation is NULL');
    },
    crucial: true,
  ),
  LabCase(
    'join-left-pagination',
    'Joins',
    'LEFT JOIN filters, sorting and pagination work together',
    (f) async {
      final db = await _seed(f);
      final rows = await db.fetchWithLeftJoins(
        leftJoins: [_left()],
        filters: [
          const DBFilter(
            fieldName: 'items.id',
            matched: 0,
            filterType: DBFilterType.greaterThan,
          ),
        ],
        sorter: const DBSorter(fieldName: 'items.id', sortType: DBSortType.asc),
        limit: 1,
        offset: 1,
      );
      equal(rows.single['id'], 2, 'Joined page selects second item');
    },
    crucial: true,
  ),
  LabCase(
    'join-table-records',
    'Joins',
    'fetchWithTables returns qualified aliases',
    (f) async {
      final db = await _seed(f);
      final rows = await db.fetchWithTables(
        tableRecords: [
          DBInnerJoinTable(
            key: 'groupID',
            table: groupTable,
            matchedTable: itemTable,
            outputKey: 'g',
          ),
        ],
      );
      check(rows.length == 2, 'Current table-record API uses LEFT JOIN');
      equal(rows.first['items_id'], 1, 'Main alias');
      equal(rows.first['g_label'], 'Members', 'Joined alias');
    },
  ),
  LabCase(
    'join-table-page',
    'Joins',
    'fetchWithTables supports offset plus limit',
    (f) async {
      final db = await _seed(f);
      final rows = await db.fetchWithTables(
        tableRecords: [
          DBInnerJoinTable(
            key: 'groupID',
            table: groupTable,
            matchedTable: itemTable,
          ),
        ],
        offset: 1,
        limit: 1,
      );
      check(rows.length == 1, 'A bounded joined page must execute');
    },
  ),
  LabCase(
    'join-standalone',
    'Joins',
    'TunaiJoinedDB returns matched and unmatched aliases',
    (f) async {
      await _seed(f);
      final rows = await TunaiJoinedDB().fetch(
        mainTable: const JoinedDB(table: itemTable, tag: 'i'),
        joinedTables: [
          const LeftJoinedDB(
            table: groupTable,
            tag: 'g',
            onClause: LeftJoinOnClause(
              field1: 'i.groupID',
              field2: 'g.groupID',
            ),
          ),
        ],
      );
      check(rows.length == 2, 'Standalone joined rows');
      equal(rows.first['g_label'], 'Members', 'Standalone alias');
    },
  ),
  LabCase(
    'join-standalone-page',
    'Joins',
    'TunaiJoinedDB supports sorted pagination',
    (f) async {
      await _seed(f);
      final rows = await TunaiJoinedDB().fetch(
        mainTable: const JoinedDB(table: itemTable, tag: 'i'),
        joinedTables: [
          const LeftJoinedDB(
            table: groupTable,
            tag: 'g',
            onClause: LeftJoinOnClause(
              field1: 'i.groupID',
              field2: 'g.groupID',
            ),
          ),
        ],
        sorter: const DBSorter(fieldName: 'i.id', sortType: DBSortType.desc),
        offset: 0,
        limit: 1,
      );
      equal(rows.single['i_id'], 2, 'Standalone joined page');
    },
  ),
  LabCase(
    'join-empty-list',
    'Joins',
    'fetchWithLeftJoins also works without optional joins',
    (f) async {
      final db = await _seed(f);
      equal(
        (await db.fetchWithLeftJoins()).length,
        2,
        'Empty join list is a normal base-table read',
      );
    },
  ),
];
