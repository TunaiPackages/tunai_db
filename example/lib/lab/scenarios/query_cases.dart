import 'package:tunai_db/tunai_db.dart';

import '../lab_case.dart';
import '../lab_database.dart';

Future<RowDB> _seed(LabDatabase f) async {
  await f.open([itemTable]);
  final db = RowDB(itemTable);
  await db.insertList([
    item(1, group: 1, name: 'Alpha'),
    item(2, group: 1, name: 'Beta'),
    item(3, group: 2, name: 'Gamma'),
    item(4, group: 2, name: 'Delta'),
  ]);
  return db;
}

List<Object?> _ids(List<Map<String, Object?>> rows) =>
    rows.map((r) => r['id']).toList();
List<LabCase> queryCases() => [
  LabCase(
    'query-comparisons',
    'Queries',
    'All comparison operators and numeric IN filters',
    (f) async {
      final db = await _seed(f);
      final matrix = <DBFilterType, List<int>>{
        DBFilterType.equal: [2],
        DBFilterType.notEqual: [1, 3, 4],
        DBFilterType.greaterThan: [3, 4],
        DBFilterType.greaterThanOrEqual: [2, 3, 4],
        DBFilterType.lessThan: [1],
        DBFilterType.lessThanOrEqual: [1, 2],
      };
      for (final pair in matrix.entries) {
        equal(
          _ids(
            await db.fetch(
              filters: [
                DBFilter(fieldName: 'id', matched: 2, filterType: pair.key),
              ],
              sorter: const DBSorter(fieldName: 'id', sortType: DBSortType.asc),
            ),
          ),
          pair.value,
          'Comparison ${pair.key.name}',
        );
      }
      equal(
        _ids(
          await db.fetch(
            filters: [
              const DBFilterIn(fieldName: 'id', matched: [1, 4]),
            ],
          ),
        ),
        [1, 4],
        'Numeric IN',
      );
    },
    crucial: true,
  ),
  LabCase(
    'query-groups',
    'Queries',
    'Grouped AND/OR predicates preserve parentheses',
    (f) async {
      final db = await _seed(f);
      final rows = await db.fetch(
        filters: [const DBFilter(fieldName: 'groupID', matched: 1)],
        groupedFilters: [
          const GroupedDBFilter(
            filterJoinType: DBFilterJoinType.or,
            filters: [
              DBFilter(fieldName: 'id', matched: 2),
              DBFilter(fieldName: 'id', matched: 3),
            ],
          ),
        ],
      );
      equal(_ids(rows), [2], 'groupID=1 AND (id=2 OR id=3)');
    },
    crucial: true,
  ),
  LabCase(
    'query-empty-in',
    'Queries',
    'An empty IN selection must never become all rows',
    (f) async {
      final db = await _seed(f);
      equal(
        await db.fetch(
          filters: [const DBFilterIn(fieldName: 'id', matched: [])],
        ),
        [],
        'Empty selection',
      );
    },
    crucial: true,
  ),
  LabCase(
    'query-sort-page',
    'Queries',
    'Sort, offset and limit produce stable pages',
    (f) async {
      final db = await _seed(f);
      equal(
        _ids(
          await db.fetch(
            sorter: const DBSorter(fieldName: 'id', sortType: DBSortType.desc),
            offset: 1,
            limit: 2,
          ),
        ),
        [3, 2],
        'Descending second page',
      );
      equal(
        await db.getCount(
          filters: [const DBFilter(fieldName: 'groupID', matched: 2)],
        ),
        2,
        'Filtered count',
      );
      equal(await db.getSum('amount'), 10.0, 'Sum of REAL amounts');
    },
  ),
  LabCase(
    'query-search',
    'Queries',
    'Search finds text with the declared spacing policy',
    (f) async {
      final db = await _seed(f);
      equal(
        _ids(
          await db.fetch(
            filters: [
              const DBSearchFilter(
                fieldName: 'name',
                searchValue: 'al ph',
                ignoreSpaces: true,
              ),
            ],
          ),
        ),
        [1],
        'Space-normalized search',
      );
      equal(
        _ids(
          await db.fetch(
            filters: [
              const DBFilter(
                fieldName: 'name',
                matched: 'B%',
                filterType: DBFilterType.like,
              ),
            ],
          ),
        ),
        [2],
        'LIKE filter',
      );
    },
  ),
  LabCase(
    'query-apostrophe',
    'Queries',
    'Equality filters safely match apostrophes',
    (f) async {
      final db = await _seed(f);
      await db.insert(item(5, name: "O'Brien"));
      equal(
        _ids(
          await db.fetch(
            filters: [const DBFilter(fieldName: 'name', matched: "O'Brien")],
          ),
        ),
        [5],
        'Quoted string equality',
      );
    },
    crucial: true,
  ),
  LabCase(
    'query-input-scope',
    'Queries',
    'Untrusted text cannot broaden a filter to every row',
    (f) async {
      final db = await _seed(f);
      equal(
        await db.fetch(
          filters: [
            const DBFilter(fieldName: 'name', matched: "unknown' OR 1=1 --"),
          ],
        ),
        [],
        'Filter input must remain a literal',
      );
    },
    crucial: true,
  ),
  LabCase(
    'query-in-strings',
    'Queries',
    'String IN values preserve apostrophes',
    (f) async {
      final db = await _seed(f);
      await db.insert(item(5, name: "O'Brien"));
      equal(
        _ids(
          await db.fetch(
            filters: [
              const DBFilterIn(fieldName: 'name', matched: ["O'Brien", 'Beta']),
            ],
            sorter: const DBSorter(fieldName: 'id', sortType: DBSortType.asc),
          ),
        ),
        [2, 5],
        'Quoted IN strings',
      );
    },
    crucial: true,
  ),
  LabCase(
    'query-search-wildcard',
    'Queries',
    'Literal percent signs in search match actual text',
    (f) async {
      final db = await _seed(f);
      await db.insert(item(5, name: '100% complete'));
      equal(
        _ids(
          await db.fetch(
            filters: [
              const DBSearchFilter(
                fieldName: 'name',
                searchValue: '100%',
                ignoreSpaces: false,
              ),
            ],
          ),
        ),
        [5],
        'Literal wildcard search',
      );
    },
  ),
  LabCase(
    'query-empty-sum',
    'Queries',
    'An empty numeric aggregate returns zero',
    (f) async {
      await f.open([itemTable]);
      equal(await RowDB(itemTable).getSum('amount'), 0.0, 'Empty sum');
    },
  ),
  LabCase(
    'query-raw-read',
    'Queries',
    'Diagnostic rawQuery returns real stored results',
    (f) async {
      final db = await _seed(f);
      final rows = await db.rawQuery('SELECT COUNT(*) AS total FROM items');
      equal(rows.single['total'], 4, 'Raw result');
    },
  ),
];
