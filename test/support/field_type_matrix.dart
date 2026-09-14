import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:tunai_db/src/schema/schema_reconciler.dart';
import 'package:tunai_db/tunai_db.dart';

const _id = DBField(
  fieldName: 'id',
  fieldType: DBFieldType.integer,
  isPrimaryKey: true,
);
const _sentinel = DBTable(tableName: 'sentinel', fields: [_id]);
DBTable _table(DBFieldType type,
        {Object? value, bool required = false, bool indexed = false}) =>
    DBTable(tableName: 'items', fields: [
      _id,
      DBField(
          fieldName: 'value',
          fieldType: type,
          isNotNull: required,
          defaultValue: value,
          indexing: indexed),
    ]);

class _Sample {
  const _Sample(this.label, this.value,
      {this.numericText = false, this.losesRealPrecision = false});
  final String label;
  final Object? value;
  final bool numericText;
  final bool losesRealPrecision;
}

const _samples = {
  DBFieldType.integer: [
    _Sample('null', null),
    _Sample('zero', 0),
    _Sample('positive', 7),
    _Sample('negative', -7),
    _Sample('exact-double-boundary', 9007199254740992),
    _Sample('inexact-double-boundary', 9007199254740993,
        losesRealPrecision: true),
    _Sample('int64-max', 9223372036854775807, losesRealPrecision: true),
    _Sample('int64-min', -9223372036854775808),
    _Sample('negative-inexact-double', -9007199254740993,
        losesRealPrecision: true),
    _Sample('int64-min-plus-one', -9223372036854775807,
        losesRealPrecision: true),
    _Sample('non-numeric-storage', 'not a number'),
  ],
  DBFieldType.real: [
    _Sample('null', null),
    _Sample('zero', 0.0),
    _Sample('whole', 7.0),
    _Sample('fraction', -2.5),
    _Sample('negative-zero', -0.0),
    _Sample('smallest-subnormal', 5e-324),
    _Sample('largest-finite', 1.7976931348623157e308),
    _Sample('decimal', 0.1),
    _Sample('tiny', 1e-200),
    _Sample('large', 1e100),
    _Sample('exact-double-boundary', 9007199254740992.0),
    _Sample('non-numeric-storage', 'not a number'),
  ],
  DBFieldType.text: [
    _Sample('null', null),
    _Sample('empty', ''),
    _Sample('plain', 'hello'),
    _Sample('quotes-unicode', "O'Brien 中文 🚀"),
    _Sample('nul', 'before\u0000after'),
    _Sample('leading-zero', '007', numericText: true),
    _Sample('integer-text', '7', numericText: true),
    _Sample('fraction-text', '-2.5', numericText: true),
    _Sample('exponent-text', '1e3', numericText: true),
    _Sample('int64-text', '9223372036854775807', numericText: true),
    _Sample('whitespace-number', ' 7 ', numericText: true),
    _Sample('mixed-text', '7x'),
    _Sample('overflow-number-text', '9999999999999999999999999',
        numericText: true),
    _Sample('nan-text', 'NaN'),
    _Sample('infinity-text', 'Infinity'),
  ],
};
Object _normalDefault(DBFieldType type) => switch (type) {
      DBFieldType.integer => 13,
      DBFieldType.real => 13.5,
      DBFieldType.text => "new's 中文 🚀",
    };

class _Default {
  const _Default(this.name, this.value, this.numeric, this.text);
  final String name;
  final Object? value;
  final Object? numeric;
  final String? text;
  Object? stored(DBFieldType type) => type == DBFieldType.text ? text : numeric;
}

const _defaults = [
  _Default('zero', 0, 0, '0'),
  _Default('negative', -7, -7, '-7'),
  _Default('fraction', 2.5, 2.5, '2.5'),
  _Default('true', true, 1, '1'),
  _Default('false', false, 0, '0'),
  _Default('numeric-string', '007', 7, '007'),
  _Default('exponent-string', '1e3', 1000, '1e3'),
  _Default('empty-string', '', '', ''),
  _Default('quotes-unicode', "O'Brien 中文 🚀", "O'Brien 中文 🚀", "O'Brien 中文 🚀"),
  _Default('sql-looking-string', "'); DROP TABLE sentinel; --",
      "'); DROP TABLE sentinel; --", "'); DROP TABLE sentinel; --"),
];

/// Shared assertions run against real files on host and each native backend.
/// Each case owns a unique disposable database; no customer files are opened.
void registerFieldTypeMatrix(
  void Function(String, Future<void> Function()) register,
) {
  for (final source in DBFieldType.values) {
    for (final target in DBFieldType.values) {
      for (final required in [false, true]) {
        for (final withDefault in [false, true]) {
          register(
              'empty ${source.name} -> ${target.name}, required=$required, default=$withDefault',
              () => _withDatabase((init) async {
                    await _open(init, _table(source));
                    await init.database.insert('sentinel', {'id': 99});
                    final model = _table(target,
                        required: required,
                        value: withDefault ? _normalDefault(target) : null);
                    expect(
                        await _open(init, model), DBInitializationResult.ready);
                    expect(await init.database.query('sentinel'), [
                      {'id': 99}
                    ]);
                    await _verifySchema(init.database, model);
                    if (required && !withDefault) {
                      await expectLater(
                          init.database.insert('items', {'id': 1}),
                          throwsA(isA<DatabaseException>()));
                    } else {
                      await init.database.insert('items', {'id': 1});
                      expect(
                          (await init.database.query('items')).single['value'],
                          withDefault ? _normalDefault(target) : null);
                    }
                    await _verifyReopen(init, model);
                  }));
        }
      }
    }
  }
  for (final first in DBFieldType.values) {
    for (final second in DBFieldType.values.where((t) => t != first)) {
      final third =
          DBFieldType.values.singleWhere((t) => t != first && t != second);
      register(
          'populated type cycle ${first.name}/${second.name}/${third.name}/${first.name}',
          () => _withDatabase((init) async {
                await _open(init, _table(first));
                await init.database.insert('items', {'id': 1, 'value': 7});
                await init.database.insert('items', {'id': 2, 'value': null});
                var expected = <Object?>[
                  first == DBFieldType.text
                      ? '7'
                      : first == DBFieldType.real
                          ? 7.0
                          : 7,
                  null
                ];
                for (final type in [second, third, first]) {
                  expected = expected
                      .map((v) => type == DBFieldType.text
                          ? (v ?? 7).toString()
                          : type == DBFieldType.real
                              ? 7.0
                              : 7)
                      .toList();
                  final model = _table(type, value: 7, indexed: true);
                  expect(
                      await _open(init, model), DBInitializationResult.ready);
                  expect(await init.database.query('items', orderBy: 'id'), [
                    {'id': 1, 'value': expected[0]},
                    {'id': 2, 'value': expected[1]},
                  ]);
                  await _verifySchema(init.database, model);
                  await _verifyReopen(init, model);
                }
              }));
    }
  }
  for (final source in DBFieldType.values) {
    for (final target in DBFieldType.values) {
      for (final sample in _samples[source]!) {
        for (final required in [false, true]) {
          register(
              '${source.name} -> ${target.name}: ${sample.label}, required=$required',
              () => _withDatabase((init) async {
                    await _open(init, _table(source));
                    final db = init.database;
                    expect(
                        (await db.rawQuery('PRAGMA table_info(items)'))
                            .last['dflt_value'],
                        isNull);
                    await db.insert('items', {'id': 1, 'value': sample.value});
                    await db.insert('items', {'id': 2, 'value': sample.value});
                    await db.insert('sentinel', {'id': 99});
                    final before = await _rows(db);

                    // Add a default after populated creation; it never backfills NULL.
                    expect(
                        await _open(init,
                            _table(source, value: _normalDefault(source))),
                        DBInitializationResult.ready);
                    expect(await _rows(init.database), before);
                    await init.database.insert('items', {'id': 3});
                    expect(
                        (await init.database.query('items', where: 'id=3'))
                            .single['value'],
                        _normalDefault(source));
                    await init.database.delete('items', where: 'id=3');

                    final model = _table(target,
                        value: _normalDefault(target),
                        required: required,
                        indexed: true);
                    final losesValue =
                        source == target && sample.value == null && required;
                    final expectedValue = source == target
                        ? before.first['value']
                        : _convertedSample(sample, source, target);
                    if (losesValue) {
                      // Verify the failed preserving attempt is atomic BEFORE recovery.
                      final oldSql = await _schema(init.database);
                      await expectLater(
                          SchemaReconciler.update(
                              init.database, [model, _sentinel],
                              completeRegistry: true),
                          throwsA(anyOf(isA<SchemaIncompatibility>(),
                              isA<DatabaseException>())));
                      expect(await _rows(init.database), before);
                      expect(await _schema(init.database), oldSql);
                      expect(await init.database.query('sentinel'), [
                        {'id': 99}
                      ]);
                    }
                    expect(
                        await _open(init, model),
                        losesValue
                            ? DBInitializationResult.tablesRebuilt
                            : DBInitializationResult.ready);
                    if (losesValue) {
                      expect(await _rows(init.database), isEmpty);
                      expect(await init.database.query('sentinel'), [
                        {'id': 99}
                      ]);
                    } else {
                      // Numeric INTEGER/REAL storage may change only with exact value preservation.
                      expect(
                          await init.database.query('items', orderBy: 'id'),
                          before
                              .map((r) =>
                                  {'id': r['id'], 'value': expectedValue})
                              .toList());
                      expect(await init.database.query('sentinel'), [
                        {'id': 99}
                      ]);
                    }
                    await _verifySchema(init.database, model);
                    await init.database.insert('items', {'id': 10});
                    expect(
                        (await init.database.query('items', where: 'id=10'))
                            .single['value'],
                        _normalDefault(target));
                    await _verifyReopen(init, model);
                  }));
        }
      }
    }
    for (final value in _defaults) {
      for (final required in [false, true]) {
        register(
            '${source.name} default lifecycle: ${value.name}, required=$required',
            () => _withDatabase((init) async {
                  await _open(init, _table(source, required: required));
                  await init.database.insert(
                      'items', {'id': 1, 'value': _normalDefault(source)});
                  if (!required) {
                    await init.database
                        .insert('items', {'id': 2, 'value': null});
                  }
                  final before = await _rows(init.database);
                  await init.database.insert('sentinel', {'id': 99});
                  final model = _table(source,
                      value: value.value, required: required, indexed: true);
                  expect(
                      await _open(init, model), DBInitializationResult.ready);
                  expect(await _rows(init.database), before);
                  await _verifySchema(init.database, model);
                  await init.database.insert('items', {'id': 3});
                  expect(
                      (await init.database.query('items', where: 'id=3'))
                          .single['value'],
                      value.stored(source));
                  await _verifyReopen(init, model);
                  // Change the default again: existing values remain unchanged.
                  final rows = await _rows(init.database);
                  final changed = _table(source,
                      value: _normalDefault(source), required: required);
                  expect(
                      await _open(init, changed), DBInitializationResult.ready);
                  expect(await _rows(init.database), rows);
                  await init.database.insert('items', {'id': 4});
                  expect(
                      (await init.database.query('items', where: 'id=4'))
                          .single['value'],
                      _normalDefault(source));
                  // Remove the default; future omitted values follow nullability.
                  final removed = _table(source, required: required);
                  expect(
                      await _open(init, removed), DBInitializationResult.ready);
                  expect(
                      (await init.database.rawQuery('PRAGMA table_info(items)'))
                          .last['dflt_value'],
                      isNull);
                  if (required) {
                    await expectLater(init.database.insert('items', {'id': 5}),
                        throwsA(isA<DatabaseException>()));
                  } else {
                    await init.database.insert('items', {'id': 5});
                    expect(
                        (await init.database.query('items', where: 'id=5'))
                            .single['value'],
                        isNull);
                  }
                  expect(await init.database.query('sentinel'), [
                    {'id': 99}
                  ]);
                  await _verifyReopen(init, removed);
                }));
      }
    }
    for (final invalid in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      <int>[1],
      {'bad': 1}
    ]) {
      register(
          '${source.name} invalid default: $invalid',
          () => _withDatabase((init) async {
                final original = _table(source);
                await _open(init, original);
                await init.database.insert(
                    'items', {'id': 1, 'value': _normalDefault(source)});
                final rows = await _rows(init.database);
                final schema = await _schema(init.database);
                await expectLater(_open(init, _table(source, value: invalid)),
                    throwsArgumentError);
                expect(init.hasInit, isFalse);
                init.setTables([original, _sentinel]);
                await init.initDatabase('matrix', updateDB: false);
                expect(await _rows(init.database), rows);
                expect(await _schema(init.database), schema);
              }));
    }
  }
}

Future<void> _withDatabase(
    Future<void> Function(TunaiDBInitializer) body) async {
  final init = TunaiDBInitializer()
    ..setDBName('field_matrix_${DateTime.now().microsecondsSinceEpoch}')
    ..setTables([])
    ..setTriggers([]);
  String? path;
  try {
    await init.initDatabase('matrix', updateDB: false);
    path = init.database.path;
    await body(init);
  } finally {
    await init.close();
    init
      ..setTables([])
      ..setTriggers([])
      ..setDBName('tunaiDB');
    if (path != null) await deleteDatabase(path);
  }
}

Future<DBInitializationResult> _open(TunaiDBInitializer init, DBTable table) {
  init.setTables([table, _sentinel]);
  return init.initDatabase('matrix');
}

Future<List<Map<String, Object?>>> _rows(Database db) => db.rawQuery(
    'SELECT id, value, typeof(value) AS storage FROM items ORDER BY id');
Future<List<Map<String, Object?>>> _schema(Database db) =>
    db.query('sqlite_master',
        columns: ['type', 'name', 'sql'], orderBy: 'type,name');
Future<void> _verifySchema(Database db, DBTable model) async {
  final field = model.fields.last;
  final column = (await db.rawQuery('PRAGMA table_info(items)')).last;
  expect(column['type'], field.fieldType.query);
  expect(column['notnull'], field.isNotNull ? 1 : 0);
  expect(column['dflt_value'], field.defaultSql);
  expect(await db.rawQuery('PRAGMA index_list(items)'),
      hasLength(field.indexing ? 1 : 0));
  expect((await db.rawQuery('PRAGMA quick_check')).single.values.single, 'ok');
  expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
}

Future<void> _verifyReopen(TunaiDBInitializer init, DBTable model) async {
  final before = await _rows(init.database);
  final version = await init.database.rawQuery('PRAGMA schema_version');
  expect(await _open(init, model), DBInitializationResult.ready);
  expect(await _rows(init.database), before);
  expect(await init.database.rawQuery('PRAGMA schema_version'), version);
}

Object _convertedSample(
    _Sample sample, DBFieldType source, DBFieldType target) {
  final value = sample.value;
  if (value == null) return _normalDefault(target);
  if (target == DBFieldType.text) {
    return sample.label == 'negative-zero' ? '0.0' : value.toString();
  }
  if (value is String) {
    return switch (sample.label) {
      'leading-zero' || 'integer-text' || 'whitespace-number' => 7,
      'exponent-text' => 1000,
      'fraction-text' =>
        target == DBFieldType.real ? -2.5 : _normalDefault(target),
      'int64-text' => target == DBFieldType.integer
          ? 9223372036854775807
          : _normalDefault(target),
      _ => _normalDefault(target),
    };
  }
  if (target == DBFieldType.real) {
    return sample.losesRealPrecision
        ? _normalDefault(target)
        : (value as num).toDouble();
  }
  final number = value as num;
  if (number < -9223372036854775808.0 ||
      number >= 9223372036854775808.0 ||
      number.truncateToDouble() != number) {
    return _normalDefault(target);
  }
  return number.toInt();
}
