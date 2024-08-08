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

  const DBField({
    required this.fieldName,
    required this.fieldType,
    this.isPrimaryKey = false,
    this.isAutoIncrement = false,
    this.isNotNull = true,
    this.defaultValue,
    this.reference,
  });

  String get fieldDefinition {
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
      definition +=
          ' DEFAULT ${defaultValue is String ? _getStringDefaultValue() : defaultValue}';
    }

    return definition;
  }

  String _getStringDefaultValue() {
    return "\'\'";
  }
}
