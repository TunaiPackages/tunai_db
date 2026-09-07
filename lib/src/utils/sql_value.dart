import 'dart:typed_data';

/// Normalize the supported SQLite value types without stringifying NULL.
Object? sqliteValue(Object? value) {
  if (value is String && value.contains('\u0000')) {
    throw ArgumentError(
        'SQLite text cannot contain NUL; use a blob for binary data');
  }
  if (value == null || value is String || value is int || value is Uint8List) {
    return value;
  }
  if (value is bool) return value ? 1 : 0;
  if (value is double && value.isFinite) return value;
  throw ArgumentError.value(value, 'value', 'Expected a SQLite scalar or blob');
}

/// Compatibility SQL for callers of getQuery; execution uses bound arguments.
String sqlLiteral(Object? value) {
  final normalized = sqliteValue(value);
  if (normalized == null) return 'NULL';
  if (normalized is String) return "'${normalized.replaceAll("'", "''")}'";
  if (normalized is Uint8List) {
    return "X'${normalized.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'";
  }
  // Retain the historical SQL spelling for boolean diagnostic queries.
  if (value is bool) return value.toString();
  return normalized.toString();
}

String quoteSqlIdentifier(String value) => '"${value.replaceAll('"', '""')}"';
