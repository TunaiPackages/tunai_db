import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../test/support/field_type_matrix.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerFieldTypeMatrix((name, body) => testWidgets(name, (_) => body()));
}
