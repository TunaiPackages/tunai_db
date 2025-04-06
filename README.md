<!--
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/guides/libraries/writing-package-pages).

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-library-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/developing-packages).
-->

TunaiDB is a type-safe SQLite wrapper for Flutter that simplifies database operations with a clean, intuitive API. It provides robust transaction management, efficient batch operations, and intelligent query capabilities while abstracting away the complexities of raw SQL. The package handles schema migrations, supports complex joins and filters, and automatically optimizes operations based on the underlying SQLite version. Perfect for developers who want the power of SQLite with the convenience of a modern, object-oriented interface.

## Features

Core Features
- Type-safe database operations with generic TunaiDB<T> implementation
- Automatic data conversion between Dart objects and database records
- Transaction management with queued operations for data consistency
- Comprehensive logging for debugging and performance monitoring
  
Query Capabilities
- Flexible filtering with support for complex conditions and join types
- Table joins with intuitive API for multi-table queries
- Custom sorting options for result ordering
- Raw query support for advanced use cases
  
Performance Optimizations
- Batch operations for efficient bulk inserts and updates
- Intelligent upsert handling with SQLite version detection
- Chunked processing for large datasets to manage memory usage
  

## Getting Started

1. Create your own database table class which extends TunaiDB 

```dart
class ExampleDB extends TunaiDB<Example> {
  static final DBTable dbTable = DBTable(tableName: 'example', fields: [
    DBField(
      fieldName: 'id',
      fieldType: DBFieldType.integer,
      isPrimaryKey: true,
    ),
    DBField(
      fieldName: 'name',
      fieldType: DBFieldType.text,
    ),
  ]);

  @override
  DBDataConverter<Example> get dbTableDataConverter => ExampleDBDataConverter();

  @override
  DBTable get table => dbTable;
}

class ExampleDBDataConverter extends DBDataConverter<Example> {
  @override
  Example fromMap(Map<String, Object?> map) {
    return Example(
      id: map['id'] as int,
      name: map['name'] as String,
    );
  }

  @override
  Map<String, Object?> toMap(Example data) {
    return {
      'id': data.id,
      'name': data.name,
    };
  }
}
```

2. Init the database connections in main

```dart
final dbInit = TunaiDBInitializer();

  dbInit
    ..setDBName('your_app_name')
    ..setTables([ExampleDB.dbTable);

  await dbInit.initDatabase(unique_key)
```

DBName and unique_key is to form the filename for database file

3. Fetch data by simple calling

```dart
final ExampleDB db = ExampleDB();

final List<Example> examples = await db.fetch();
```

With filter

```dart
final ExampleDB db = ExampleDB();

final List<Example> examples = await db.fetch(
  filters: [
      DBFilter(
        fieldName: 'id',
        matched: 0,
      ),
  ],
);
```

4. Insert 

```dart
 await db.insertList([
    Example(id: 0, name: 'test'),
    Example(id: 0, name: 'test'),
  ]);
```

It is actually upsert, which will update the data on conflict


