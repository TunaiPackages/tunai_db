// Opt-in subprocess worker; run with tool/test_persistence_stress.py.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi/src/database_factory_ffi_io.dart';
import 'package:sqflite_common_ffi/src/sqflite_import.dart';
import 'package:tunai_db/src/schema/schema_reconciler.dart';
import 'package:tunai_db/tunai_db.dart';

final _env = Platform.environment;
final _payload = 'x' * 256;
const _id = DBField(
    fieldName: 'id', fieldType: DBFieldType.integer, isPrimaryKey: true);
const _parents = DBTable(tableName: 'parents', fields: [
  _id,
  DBField(fieldName: 'tag', fieldType: DBFieldType.text),
]);
DBTable _model({bool recovery = false}) => DBTable(tableName: 'items', fields: [
      DBField(
          fieldName: 'id',
          fieldType: DBFieldType.integer,
          isPrimaryKey: !recovery),
      const DBField(
          fieldName: 'value',
          fieldType: DBFieldType.integer,
          defaultValue: -1,
          indexing: true),
      const DBField(
          fieldName: 'score', fieldType: DBFieldType.real, isNotNull: false),
      DBField(
          fieldName: 'label',
          fieldType: DBFieldType.text,
          isPrimaryKey: recovery),
      const DBField(fieldName: 'payload', fieldType: DBFieldType.text),
      const DBField(
          fieldName: 'parentId',
          fieldType: DBFieldType.integer,
          reference: DBReference(table: _parents, fieldName: 'id')),
      const DBField(
          fieldName: 'added',
          fieldType: DBFieldType.text,
          defaultValue: 'fresh'),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('persistence subprocess', () async {
    final mode = _env['TUNAI_STRESS_MODE']!;
    File(_env['TUNAI_STRESS_PID']!).writeAsStringSync('$pid');
    final path = _env['TUNAI_STRESS_DB']!;
    final rows = int.parse(_env['TUNAI_STRESS_ROWS']!);
    final journal = _env['TUNAI_STRESS_JOURNAL']!;
    final recovery = _env['TUNAI_STRESS_RECOVERY'] == '1';
    final phase = _env['TUNAI_STRESS_PHASE'] ?? '';
    var active = false;
    var batches = 0;
    var reached = false;
    Future<void> checkpoint(String point) async {
      if (!active || reached || point != phase) return;
      reached = true;
      File(_env['TUNAI_STRESS_MARKER']!).writeAsStringSync(
          jsonEncode({
            'pid': pid,
            'phase': point,
            'batches': batches,
          }),
          flush: true);
      // The controller owns the kill. No finally/close/rollback can run here.
      if (point.startsWith('active_')) {
        while (!File('${_env['TUNAI_STRESS_MARKER']}.go').existsSync()) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      } else {
        await Completer<void>().future;
      }
    }

    sqfliteFfiInit();
    final factory = buildDatabaseFactory(
        tag: 'stress',
        invokeMethod: (method, [arguments]) async {
          final args = arguments is Map ? arguments : const {};
          final sql = (args['sql'] as String? ?? '').toUpperCase();
          final copying = method == 'batch' ||
              (method == 'insert' &&
                  sql.startsWith('WITH ') &&
                  sql.contains('__TUNAI_UPDATE'));
          if (active && method == 'execute' && sql == 'COMMIT') {
            await checkpoint('before_commit');
            await checkpoint('active_commit');
          }
          if (active && copying) await checkpoint('active_copy');
          if (active && sql.startsWith('DROP TABLE "ITEMS"')) {
            await checkpoint('before_drop');
          }
          final result = await ffiMethodCallhandleInIsolate(
              FfiMethodCall(method, arguments));
          if (active) {
            if (copying) {
              batches++;
              if (batches == 1) await checkpoint('copy_1');
              if (batches == 20) await checkpoint('copy_20');
            }
            if (sql.startsWith('CREATE TABLE "ITEMS__TUNAI_UPDATE"')) {
              await checkpoint('created');
            }
            if (sql.startsWith('DROP TABLE "ITEMS"')) {
              await checkpoint('after_drop');
            }
            if (sql.startsWith('DROP TABLE IF EXISTS "ITEMS"')) {
              await checkpoint('recovery_drop');
            }
            if (method == 'execute' && sql == 'COMMIT') {
              await checkpoint('after_commit');
            }
          }
          return result;
        });
    final db = await factory.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      expect(
          (await db.rawQuery('PRAGMA journal_mode=$journal'))
              .single
              .values
              .single
              .toString()
              .toUpperCase(),
          journal);
      await db.execute('PRAGMA synchronous=NORMAL');
      await db.execute('PRAGMA cache_size=2000');
      if (mode == 'seed') {
        await db.execute(_parents.createTableQuery);
        await db.execute("INSERT INTO parents VALUES(99,'preserved')");
        await db.execute(
            'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value TEXT NOT NULL, score TEXT, label INTEGER NOT NULL, payload TEXT NOT NULL, parentId INTEGER NOT NULL REFERENCES parents(id), obsolete TEXT)');
        await db.execute(
            "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$rows) INSERT INTO items SELECT i, CASE WHEN i%10=0 THEN 'bad' ELSE CAST(i AS TEXT) END, CASE WHEN i%7=0 THEN 'bad' ELSE '1.25' END, i*2, 'payload:'||i||':$_payload', 99, 'discard' FROM n");
        await db.execute('CREATE INDEX old_value ON items(value)');
        final schema = await db.query('sqlite_master', orderBy: 'name');
        File('$path.schema.json').writeAsStringSync(jsonEncode(schema));
        await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      } else if (mode == 'verify') {
        final fields = await db.rawQuery('PRAGMA table_info(items)');
        final migrated = fields.any((f) => f['name'] == 'added');
        final expected = _env['TUNAI_STRESS_EXPECT']!;
        if (expected != 'either') expect(migrated, expected == 'new');
        if (!migrated) {
          expect(await db.query('sqlite_master', orderBy: 'name'),
              jsonDecode(File('$path.schema.json').readAsStringSync()));
        }
        await _verify(db, rows, migrated, recovery && migrated);
        final watch = Stopwatch()..start();
        final outcome = await SchemaReconciler.update(
            db, [_parents, _model(recovery: recovery)],
            completeRegistry: true, recoverIncompatibleSchema: true);
        expect(
            outcome,
            recovery && !migrated
                ? DBInitializationResult.rebuilt
                : DBInitializationResult.ready);
        await _verify(db, rows, true, recovery);
        await _report({
          'opened': migrated ? 'new' : 'old',
          'retry_ms': watch.elapsedMilliseconds,
          'outcome': outcome.name
        });
      } else {
        active = true;
        final watch = Stopwatch()..start();
        final outcome = await SchemaReconciler.update(
            db, [_parents, _model(recovery: recovery)],
            completeRegistry: true, recoverIncompatibleSchema: true);
        final elapsed = watch.elapsedMilliseconds;
        expect(
            outcome,
            recovery
                ? DBInitializationResult.rebuilt
                : DBInitializationResult.ready);
        active = false;
        await _verify(db, rows, true, recovery);
        await _report({
          'migration_ms': elapsed,
          'outcome': outcome.name,
          'batches': batches,
          'sqlite': (await db.rawQuery('SELECT sqlite_version()'))
              .single
              .values
              .single
        });
      }
    } finally {
      await db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}

Future<void> _report(Map<String, Object?> data) async {
  File(_env['TUNAI_STRESS_RESULT']!)
      .writeAsStringSync(jsonEncode(data), flush: true);
}

Future<void> _verify(Database db, int rows, bool migrated, bool empty) async {
  expect(
      (await db.rawQuery('PRAGMA integrity_check')).single.values.single, 'ok');
  expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  expect(await db.query('sqlite_master', where: "name LIKE '%__tunai_update%'"),
      isEmpty);
  final count = empty ? 0 : rows;
  expect((await db.rawQuery('SELECT count(*) AS n FROM items')).single['n'],
      count);
  expect(
      await db.query('parents'),
      empty
          ? []
          : [
              {'id': 99, 'tag': 'preserved'}
            ]);
  if (!empty) {
    final value = migrated
        ? "CASE WHEN id%10=0 THEN -1 ELSE id END"
        : "CASE WHEN id%10=0 THEN 'bad' ELSE CAST(id AS TEXT) END";
    final score = migrated
        ? 'CASE WHEN id%7=0 THEN NULL ELSE 1.25 END'
        : "CASE WHEN id%7=0 THEN 'bad' ELSE '1.25' END";
    final label = migrated ? 'CAST(id*2 AS TEXT)' : 'id*2';
    final extra =
        migrated ? "OR added IS NOT 'fresh'" : "OR obsolete IS NOT 'discard'";
    final invalid = await db.rawQuery(
        "SELECT count(*) AS n FROM items WHERE id<1 OR id>$rows OR value IS NOT ($value) OR score IS NOT ($score) OR label IS NOT ($label) OR payload IS NOT ('payload:'||id||':$_payload') OR parentId IS NOT 99 $extra");
    expect(invalid.single['n'], 0);
  }
  if (migrated) {
    final info = await db.rawQuery('PRAGMA table_info(items)');
    expect(info.map((c) => c['name']),
        ['id', 'value', 'score', 'label', 'payload', 'parentId', 'added']);
    expect(info.map((c) => c['type']),
        ['INTEGER', 'INTEGER', 'REAL', 'TEXT', 'TEXT', 'INTEGER', 'TEXT']);
    expect(
        (await db.rawQuery('PRAGMA index_list(items)'))
            .any((i) => i['name'] == 'items_value_index'),
        isTrue);
  }
}
