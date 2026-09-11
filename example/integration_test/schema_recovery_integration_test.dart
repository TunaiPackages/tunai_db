import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:tunai_db/tunai_db.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native populated upgrade, last-resort recovery and durable reopen',
    (tester) async {
      final name =
          'tunai_recovery_integration_${DateTime.now().microsecondsSinceEpoch}';
      String? path;
      final initializer = TunaiDBInitializer()..setDBName(name);
      const id = DBField(
        fieldName: 'id',
        fieldType: DBFieldType.integer,
        isPrimaryKey: true,
      );
      DBTable target(bool required) => DBTable(
        tableName: 'items',
        fields: [
          id,
          DBField(
            fieldName: 'value',
            fieldType: DBFieldType.integer,
            defaultValue: 0,
            isNotNull: required,
            indexing: true,
          ),
        ],
      );
      try {
        initializer
          ..setTables([])
          ..setTriggers([]);
        await initializer.initDatabase('test', updateDB: false);
        final seed = initializer.database;
        path = seed.path;
        await seed.execute(
          'CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, value INTEGER)',
        );
        await seed.execute('INSERT INTO items VALUES(1,NULL)');
        await seed.execute('CREATE TABLE extra(value TEXT)');
        await seed.execute("INSERT INTO extra VALUES('retained')");
        await initializer.close();
        initializer
          ..setTables([target(false)])
          ..setTriggers([]);
        expect(
          await initializer.initDatabase('test'),
          DBInitializationResult.ready,
        );
        expect(
          (await initializer.database.query('items')).single['value'],
          isNull,
        );
        expect(await initializer.database.query('extra'), hasLength(1));
        await initializer.close();
        initializer.setTables([target(true)]);
        expect(
          await initializer.initDatabase('test'),
          DBInitializationResult.rebuilt,
        );
        expect(await initializer.database.query('items'), isEmpty);
        await initializer.database.insert('items', {'id': 2});
        await initializer.close();
        expect(
          await initializer.initDatabase('test'),
          DBInitializationResult.ready,
        );
        expect((await initializer.database.query('items')).single['value'], 0);
        for (final legacySQL in [
          "CREATE TABLE items(id INTEGER PRIMARY KEY NOT NULL, 'value' INTEGER)",
          'CREATE VIEW items AS SELECT 1 AS id, 7 AS value',
        ]) {
          await initializer.database.execute('DROP TABLE items');
          await initializer.database.execute(legacySQL);
          await initializer.close();
          expect(
            await initializer.initDatabase('test'),
            DBInitializationResult.rebuilt,
          );
          expect(await initializer.database.query('items'), isEmpty);
          await initializer.database.insert('items', {'id': 3});
        }
      } finally {
        await initializer.close();
        initializer
          ..setDBName('tunaiDB')
          ..setTables([])
          ..setTriggers([]);
        // Only the uniquely named synthetic fixture created by this test.
        if (path != null) await deleteDatabase(path);
      }
    },
  );
}
