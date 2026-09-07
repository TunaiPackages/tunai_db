import 'package:sqflite/sqflite.dart';
import 'package:tunai_db/tunai_db.dart';

/// This fixture only creates and deletes its own uniquely named lab database.
/// It exercises initDatabase (including the platform's actual SQLite backend).
class LabDatabase {
  LabDatabase(String id)
    : key =
          '${DateTime.now().microsecondsSinceEpoch}_${id.replaceAll('-', '_')}';
  final String key;
  final initializer = TunaiDBInitializer();
  String? _ownedPath;
  bool _open = false;
  Database get raw => initializer.database;

  Future<void> open(
    List<DBTable> tables, {
    List<DBTrigger> triggers = const [],
  }) async {
    initializer
      ..setDBName('tunai_db_test_lab')
      ..setTables(tables)
      ..setTriggers(triggers);
    try {
      await initializer.initDatabase(key);
      _open = true;
      _ownedPath = raw.path;
    } catch (_) {
      // initDatabase can open successfully and then fail reconciliation.
      if (initializer.hasInit &&
          initializer.database.isOpen &&
          initializer.database.path.endsWith('tunai_db_test_lab_$key.db')) {
        _ownedPath = initializer.database.path;
        _open = true;
      }
      rethrow;
    }
  }

  Future<void> reconcile(List<DBTable> tables) =>
      initializer.updateTables(raw, tables);

  Future<void> reopen(
    List<DBTable> tables, {
    bool update = true,
    bool readOnly = false,
    List<DBTrigger> triggers = const [],
  }) async {
    await close();
    initializer
      ..setTables(tables)
      ..setTriggers(triggers);
    try {
      await initializer.initDatabase(key, updateDB: update, readOnly: readOnly);
    } finally {
      _open = initializer.database.isOpen;
    }
  }

  Future<void> attachExisting() async {
    final path = _ownedPath!;
    await close();
    final existing = await openDatabase(path);
    initializer.initExistingDatabase(existing);
    _open = true;
  }

  Future<void> resetOwnedDatabase() async {
    await close();
    await initializer.initDatabase(key, resetDB: true);
    _open = true;
  }

  Future<void> close() async {
    if (_open) {
      await initializer.close();
      _open = false;
    }
  }

  Future<void> dispose() async {
    await close();
    final path = _ownedPath;
    if (path != null) {
      if (!path.endsWith('tunai_db_test_lab_$key.db')) {
        throw StateError(
          'Refusing cleanup of a database not owned by this case.',
        );
      }
      await deleteDatabase(path);
    }
    initializer
      ..setTables([])
      ..setTriggers([]);
  }
}

class RowDB extends TunaiDB<Map<String, Object?>> {
  RowDB(this.table, {this.converter = const RowConverter()});
  @override
  final DBTable table;
  final DBDataConverter<Map<String, Object?>> converter;
  @override
  DBDataConverter<Map<String, Object?>> get dbTableDataConverter => converter;
}

class RowConverter extends DBDataConverter<Map<String, Object?>> {
  const RowConverter();
  @override
  Map<String, Object?> fromMap(Map<String, Object?> map) => Map.of(map);
  @override
  Map<String, Object?> toMap(Map<String, Object?> data) => Map.of(data);
}

const itemTable = DBTable(
  tableName: 'items',
  fields: [
    DBField(
      fieldName: 'id',
      fieldType: DBFieldType.integer,
      isPrimaryKey: true,
    ),
    DBField(
      fieldName: 'groupID',
      fieldType: DBFieldType.integer,
      defaultValue: 0,
      indexing: true,
    ),
    DBField(fieldName: 'name', fieldType: DBFieldType.text, defaultValue: ''),
    DBField(
      fieldName: 'amount',
      fieldType: DBFieldType.real,
      defaultValue: 0.0,
    ),
    DBField(fieldName: 'note', fieldType: DBFieldType.text, isNotNull: false),
  ],
);
const groupTable = DBTable(
  tableName: 'groups',
  fields: [
    DBField(
      fieldName: 'groupID',
      fieldType: DBFieldType.integer,
      isPrimaryKey: true,
    ),
    DBField(fieldName: 'label', fieldType: DBFieldType.text, defaultValue: ''),
  ],
);
Map<String, Object?> item(
  int id, {
  int group = 1,
  String? name,
  double? amount,
  String? note,
}) => {
  'id': id,
  'groupID': group,
  'name': name ?? 'Item $id',
  'amount': amount ?? id.toDouble(),
  'note': note,
};
