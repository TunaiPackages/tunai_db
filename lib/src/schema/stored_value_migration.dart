import '../model/db_field.dart';
import '../model/db_field_type.dart';

/// Explicit conversions for type-changed, non-key columns only.
class StoredValueMigration {
  StoredValueMigration(this.fields);
  final Map<String, DBField> fields;
  int converted = 0;
  int defaulted = 0;
  int nulled = 0;

  void apply(Map<String, Object?> row) {
    for (final entry in fields.entries) {
      final original = row[entry.key];
      final field = entry.value;
      final value = convert(original, field.fieldType);
      if (value != null) {
        row[entry.key] = value;
        if (value != original || value.runtimeType != original.runtimeType) {
          converted++;
        }
      } else if (field.defaultValue != null) {
        final fallback = convert(field.defaultValue, field.fieldType);
        if (fallback == null) {
          throw ArgumentError('A migration default must fit its declared type');
        }
        row[entry.key] = fallback;
        defaulted++;
      } else if (!field.isNotNull) {
        row[entry.key] = null;
        if (original != null) nulled++;
      } else {
        throw StateError(
            'A changed column has no usable value, default or NULL');
      }
    }
  }

  static Object? convert(Object? value, DBFieldType type) {
    if (value is bool) value = value ? 1 : 0;
    if (value == null || (value is num && !value.isFinite)) return null;
    switch (type) {
      case DBFieldType.text:
        return value is String || value is num ? value.toString() : null;
      case DBFieldType.integer:
        if (value is int) return value;
        if (value is double) {
          if (value < -9223372036854775808.0 ||
              value >= 9223372036854775808.0 ||
              value.truncateToDouble() != value) {
            return null;
          }
          return value.toInt();
        }
        if (value is String) {
          final integer = _wholeDecimal(value);
          if (integer == null || integer < _min || integer > _max) return null;
          return integer.toInt();
        }
        return null;
      case DBFieldType.real:
        final double? real = value is num
            ? value.toDouble()
            : value is String && _decimal.hasMatch(value.trim())
                ? double.tryParse(value.trim())
                : null;
        if (real == null || !real.isFinite) return null;
        if (real == 0 && value is String) {
          final match = _decimal.firstMatch(value.trim())!;
          if ('${match[2] ?? ''}${match[3] ?? match[4] ?? ''}'
              .contains(RegExp('[1-9]'))) {
            return null;
          }
        }
        final whole = value is int
            ? BigInt.from(value)
            : value is String
                ? _wholeDecimal(value)
                : null;
        if (whole != null && BigInt.from(real) != whole) return null;
        return real;
    }
  }

  static final _min = BigInt.parse('-9223372036854775808');
  static final _max = BigInt.parse('9223372036854775807');
  static final _decimal =
      RegExp(r'^([+-]?)(?:(\d+)(?:\.(\d*))?|\.(\d+))(?:[eE]([+-]?\d+))?$');

  // Parse decimal/scientific integers without first rounding through double.
  static BigInt? _wholeDecimal(String value) {
    final match = _decimal.firstMatch(value.trim());
    if (match == null) return null;
    final fraction = match[3] ?? match[4] ?? '';
    var digits = '${match[2] ?? ''}$fraction'.replaceFirst(RegExp(r'^0+'), '');
    if (digits.isEmpty) return BigInt.zero;
    final exponent = int.tryParse(match[5] ?? '0');
    if (exponent == null || exponent < -1000 || exponent > 1000) return null;
    final scale = exponent - fraction.length;
    if (scale < 0) {
      if (-scale >= digits.length ||
          digits.substring(digits.length + scale).contains(RegExp('[1-9]'))) {
        return null;
      }
      digits = digits.substring(0, digits.length + scale);
    } else {
      // Larger whole values cannot be represented by a finite double or int64.
      if (digits.length + scale > 309) return null;
      digits += '0' * scale;
    }
    if (digits.length > 309) return null;
    return BigInt.parse('${match[1] == '-' ? '-' : ''}$digits');
  }
}
