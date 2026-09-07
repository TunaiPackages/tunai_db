import 'package:tunai_db/tunai_db.dart';

import '../lab_case.dart';
import '../lab_database.dart';

List<LabCase> lifecycleCases() => [
  LabCase(
    'lifecycle-readonly',
    'Lifecycle',
    'Read-only opens allow reads and reject mutations',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await db.insert(item(1));
      await f.reopen([itemTable], update: false, readOnly: true);
      equal(await db.getCount(), 1, 'Read-only persisted rows');
      await rejects(() => db.insert(item(2)));
      await f.reopen([itemTable]);
      equal(await db.getCount(), 1, 'Rejected write cannot persist');
    },
    crucial: true,
  ),
  LabCase(
    'lifecycle-existing',
    'Lifecycle',
    'An externally opened database supports TunaiDB operations',
    (f) async {
      await f.open([itemTable]);
      await RowDB(itemTable).insert(item(1));
      await f.attachExisting();
      final db = RowDB(itemTable);
      equal(await db.getCount(), 1, 'Attached handle retains rows');
      await db.insert(item(2));
      await f.reopen([itemTable]);
      equal(await db.getCount(), 2, 'Writes through attached handle persist');
    },
  ),
  LabCase(
    'lifecycle-reopen',
    'Lifecycle',
    'Committed rows survive a real database close and reopen',
    (f) async {
      await f.open([itemTable]);
      await RowDB(itemTable).insert(item(1, note: 'persist'));
      await f.reopen([itemTable]);
      equal(await RowDB(itemTable).fetch(), [
        item(1, note: 'persist'),
      ], 'Durable row after reopen');
    },
    crucial: true,
  ),
  LabCase(
    'lifecycle-outlets',
    'Lifecycle',
    'Sequential outlet switches keep each database isolated',
    (f) async {
      await f.open([itemTable]);
      await RowDB(itemTable).insert(item(1, name: 'First outlet'));
      await f.close();
      final other = LabDatabase('second_outlet');
      try {
        await other.open([itemTable]);
        equal(
          await RowDB(itemTable).getCount(),
          0,
          'Second outlet starts empty',
        );
        await RowDB(itemTable).insert(item(1, name: 'Second outlet'));
      } finally {
        await other.dispose();
      }
      await f.reopen([itemTable]);
      equal(
        (await RowDB(itemTable).fetch()).single['name'],
        'First outlet',
        'First outlet unchanged',
      );
    },
    crucial: true,
  ),
  LabCase(
    'lifecycle-update-flag',
    'Lifecycle',
    'updateDB false leaves an old schema; true reconciles it',
    (f) async {
      await f.open([]);
      await f.raw.execute(
        'CREATE TABLE groups(groupID INTEGER PRIMARY KEY NOT NULL,label TEXT NOT NULL)',
      );
      await f.reopen([groupTable], update: false);
      equal(
        (await f.raw.rawQuery('PRAGMA table_info(groups)')).last['dflt_value'],
        null,
        'False must not change defaults',
      );
      await f.reopen([groupTable]);
      equal(
        (await f.raw.rawQuery('PRAGMA table_info(groups)')).last['dflt_value'],
        "''",
        'True reconciles default',
      );
    },
    crucial: true,
  ),
  LabCase(
    'lifecycle-reset',
    'Lifecycle',
    'Explicit reset clears only this uniquely owned lab database',
    (f) async {
      await f.open([itemTable]);
      await RowDB(itemTable).insert(item(1));
      await f.close();
      // Deliberate destructive test, only with a fixture-owned unique key.
      await f.resetOwnedDatabase();
      await f.reopen([itemTable]);
      equal(
        await RowDB(itemTable).getCount(),
        0,
        'Explicit reset removes test rows',
      );
    },
  ),
  LabCase(
    'lifecycle-triggers',
    'Lifecycle',
    'Startup creates triggers after tables and reports synchronization',
    (f) async {
      const audit = DBTable(
        tableName: 'audit',
        fields: [
          DBField(
            fieldName: 'id',
            fieldType: DBFieldType.integer,
            isPrimaryKey: true,
          ),
        ],
      );
      const trigger = DBTrigger(
        name: 'items_insert',
        table: 'items',
        timing: TriggerTiming.after,
        event: TriggerEvent.insert,
        body: 'INSERT INTO audit(id) VALUES(NEW.id);',
      );
      await f.open([itemTable, audit], triggers: [trigger]);
      await RowDB(itemTable).insert(item(1));
      equal(await f.raw.query('audit'), [
        {'id': 1},
      ], 'Trigger fired');
      check(
        (await f.initializer.getCurrentTriggers()).length == 1,
        'Trigger is visible',
      );
      equal(
        (await f.initializer.getTriggerSyncStatus())['isSynchronized'],
        true,
        'Trigger status is current',
      );
    },
    crucial: true,
  ),
  LabCase(
    'lifecycle-trigger-replace',
    'Lifecycle',
    'Trigger replacement is atomic and preserves unknown triggers',
    (f) async {
      await f.open([itemTable]);
      await f.raw.execute('CREATE TABLE audit(value TEXT)');
      await f.raw.execute(
        "CREATE TRIGGER registered AFTER INSERT ON items BEGIN INSERT INTO audit VALUES('Old'); END",
      );
      await f.raw.execute(
        'CREATE TRIGGER unknown AFTER INSERT ON items BEGIN SELECT 1; END',
      );
      f.initializer.setTriggers([
        const DBTrigger(
          name: 'registered',
          table: 'items',
          timing: TriggerTiming.after,
          event: TriggerEvent.insert,
          body: "INSERT INTO audit VALUES('old');",
        ),
      ]);
      await f.initializer.synchronizeTriggers();
      await RowDB(itemTable).insert(item(1));
      equal(await f.raw.query('audit'), [
        {'value': 'old'},
      ], 'Literal case in updated body');
      f.initializer.setTriggers([
        const DBTrigger(
          name: 'registered',
          table: 'items',
          timing: TriggerTiming.after,
          event: TriggerEvent.insert,
          body: 'INVALID SQL;',
        ),
      ]);
      await rejects(() => f.initializer.synchronizeTriggers());
      await RowDB(itemTable).insert(item(2));
      equal(await f.raw.query('audit'), [
        {'value': 'old'},
        {'value': 'old'},
      ], 'Previous valid trigger survives rollback');
      check(
        (await f.raw.query(
              'sqlite_master',
              where: 'name = ?',
              whereArgs: ['unknown'],
            )).length ==
            1,
        'Unknown trigger remains',
      );
    },
    crucial: true,
  ),
  LabCase(
    'lifecycle-delete-table',
    'Lifecycle',
    'Initializer deleteTable clears rows, not the physical table',
    (f) async {
      await f.open([itemTable]);
      final db = RowDB(itemTable);
      await db.insert(item(1));
      equal(await f.initializer.deleteTable(db), 1, 'Deleted row count');
      await db.insert(item(2));
      equal(await db.getCount(), 1, 'Table remains usable');
    },
  ),
];
