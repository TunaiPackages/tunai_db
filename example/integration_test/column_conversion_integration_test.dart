import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../test/support/column_conversion_cases.dart';
import 'field_type_matrix_integration_test.dart' as types;
import 'foreign_key_matrix_integration_test.dart' as relationships;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerColumnConversionCases(
    (name, body) => testWidgets(name, (_) => body()),
  );
  types.main();
  relationships.main();
}
