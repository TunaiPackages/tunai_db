import 'package:tunai_db/tunai_db.dart';

import '../lab_case.dart';
import '../lab_database.dart';

List<LabCase> compatibilityCases() => [
  LabCase(
    'compat-field-values',
    'Compatibility',
    'Legacy numeric field-value reads and custom conversion',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await db.insertList([item(1), item(2), item(3)]);
      // This lab deliberately exercises the public deprecated compatibility API.
      // ignore: deprecated_member_use
      final rows = await db.fetchByFieldValues(
        fieldName: 'id',
        values: [1, 3],
        sorter: const DBSorter(fieldName: 'id', sortType: DBSortType.desc),
        fromMap: (row) => {'selected': row['id']},
      );
      equal(rows, [
        {'selected': 3},
        {'selected': 1},
      ], 'Legacy numeric reads');
    },
  ),
  LabCase(
    'compat-reference-join',
    'Compatibility',
    'Legacy reference-driven join preserves unmatched rows',
    (f) async {
      const table = DBTable(
        tableName: 'entries',
        fields: [
          DBField(
            fieldName: 'id',
            fieldType: DBFieldType.integer,
            isPrimaryKey: true,
          ),
          DBField(
            fieldName: 'groupID',
            fieldType: DBFieldType.integer,
            reference: DBReference(table: groupTable, fieldName: 'groupID'),
          ),
        ],
      );
      await f.open([groupTable, table]);
      await RowDB(groupTable).insert({'groupID': 1, 'label': 'Members'});
      final db = RowDB(table);
      await db.insertList([
        {'id': 1, 'groupID': 1},
        {'id': 2, 'groupID': 99},
      ]);
      // ignore: deprecated_member_use
      final rows = await db.fetchWithInnerJoin();
      equal(rows.length, 2, 'Legacy API actually uses LEFT JOIN');
      equal(rows.first['groups_label'], 'Members', 'Referenced alias');
      equal(
        rows.last['groups_label'],
        null,
        'Reference metadata is not an SQL foreign-key constraint',
      );
    },
  ),
  LabCase(
    'compat-logger',
    'Compatibility',
    'Custom logger receives lifecycle, write and query events',
    (f) async {
      final original = TunaiDBInitializer.logger;
      final logger = _Recorder();
      TunaiDBInitializer.setLogger(logger);
      try {
        await f.open([itemTable]);
        final db = RowDB(itemTable);
        await db.insert(item(1));
        await db.fetch();
        await db.rawQuery('SELECT COUNT(*) FROM items');
        check(
          logger.kinds.containsAll({'init', 'action', 'fetch'}),
          'Public logger must receive diagnostic events',
        );
      } finally {
        TunaiDBInitializer.setLogger(original);
      }
    },
  ),
];

class _Recorder implements TunaiDBLogger {
  final kinds = <String>{};
  @override
  void logInit(String message) => kinds.add('init');
  @override
  void logAction(String message) => kinds.add('action');
  @override
  void logFetch(String message) => kinds.add('fetch');
  @override
  void logError(String message) => kinds.add('error');
  @override
  void logRaw(String message) => kinds.add('raw');
}
