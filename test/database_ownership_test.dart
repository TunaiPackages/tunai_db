import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tunai_db/tunai_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late TunaiDBOwnership ownership;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('owned_db_');
    ownership = TunaiDBOwnership(name: directory.path);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<Database> open(DatabaseFactory factory) => factory.openDatabase(
        '${directory.path}/test.db',
        options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) =>
                db.execute('CREATE TABLE probe (id INTEGER PRIMARY KEY)')),
      );

  test('foreground reservation rejects background even without an open DB',
      () async {
    await ownership.claimForeground();
    expect(await ownership.tryBackground(), isNull);
    await ownership.claimForeground();
    expect(await ownership.tryBackground(), isNull);
  });

  test('background release preserves commits and allows a later worker',
      () async {
    final lease = (await ownership.tryBackground())!;
    expect(await ownership.tryBackground(), isNull);
    final db = await open(lease.factory);
    await db.insert('probe', {'id': 1});
    await lease.close();
    await lease.close();
    final later = (await ownership.tryBackground())!;
    final reopened = await open(later.factory);
    expect(await reopened.query('probe'), [
      {'id': 1}
    ]);
    await later.close();
  });

  test('takeover during initial schema creation leaves a recoverable file',
      () async {
    final lease = (await ownership.tryBackground())!;
    final started = Completer<void>();
    final resume = Completer<void>();
    final opening = lease.factory.openDatabase('${directory.path}/test.db',
        options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) async {
              await db.execute('CREATE TABLE interrupted (id INTEGER)');
              started.complete();
              await resume.future;
            }));
    final rejected =
        expectLater(opening, throwsA(isA<DatabaseOwnershipRevoked>()));
    await started.future;
    await ownership.claimForeground().timeout(const Duration(seconds: 5));
    resume.complete();
    await rejected;
    final foreground = await open(databaseFactoryFfi);
    await foreground.insert('probe', {'id': 1});
    expect(
        await foreground.query('sqlite_master',
            where: 'name = ?', whereArgs: ['interrupted']),
        isEmpty);
    await foreground.close();
    await lease.close();
  });

  test(
      'takeover rolls back pending write and rejects stale and queued requests',
      () async {
    final lease = (await ownership.tryBackground())!;
    final db = await open(lease.factory);
    await db.insert('probe', {'id': 1});
    final started = Completer<void>();
    final resume = Completer<void>();
    final transaction = db.transaction((tx) async {
      await tx.insert('probe', {'id': 2});
      started.complete();
      await resume.future;
    });
    // Attach error handling before triggering revocation.
    final transactionFailed =
        expectLater(transaction, throwsA(isA<DatabaseOwnershipRevoked>()));
    await started.future;
    final queued = db.insert('probe', {'id': 3});
    final queuedFailed =
        expectLater(queued, throwsA(isA<DatabaseOwnershipRevoked>()));
    await ownership.claimForeground().timeout(const Duration(seconds: 5));
    resume.complete();
    await transactionFailed;
    await queuedFailed;
    expect(lease.isRevoked, isTrue);
    await expectLater(
        db.query('probe'), throwsA(isA<DatabaseOwnershipRevoked>()));
    final foreground = await open(databaseFactoryFfi);
    expect(await foreground.query('probe'), [
      {'id': 1}
    ]);
    await foreground.insert('probe', {'id': 4});
    expect(
        (await foreground.rawQuery('PRAGMA integrity_check'))
            .single
            .values
            .single,
        'ok');
    await foreground.close();
    await lease.close();
  });
}
