import 'db_field_type.dart';
import 'db_reference.dart';

class DBField {
  final String fieldName;
  final DBFieldType fieldType;
  final dynamic defaultValue;
  final bool isPrimaryKey;
  final bool isAutoIncrement;
  final bool isNotNull;
  final DBReference? reference;
  final bool indexing;
  const DBField({
    required this.fieldName,
    required this.fieldType,
    this.isPrimaryKey = false,
    this.isAutoIncrement = false,
    this.isNotNull = true,
    this.defaultValue,
    this.reference,
    this.indexing = false,
  });

  String get fieldQuery {
    String definition = '$fieldName ${fieldType.query}';
    if (isPrimaryKey) {
      definition += ' PRIMARY KEY';
    }
    if (isAutoIncrement) {
      definition += ' AUTOINCREMENT';
    }
    if (isNotNull) {
      definition += ' NOT NULL';
    }
    if (defaultValue != null) {
      definition += ' DEFAULT $defaultSql';
    }

    return definition;
  }

  /// SQL literal shared by creation and automatic schema reconciliation.
  String? get defaultSql {
    final value = defaultValue;
    if (value == null) return null;
    if (value is String) return "'${value.replaceAll("'", "''")}'";
    if (value is bool) return value ? '1' : '0';
    if (value is num && value.isFinite) return value.toString();
    throw ArgumentError.value(
      value,
      'defaultValue',
      'Expected a finite number, bool or String',
    );
  }
}
