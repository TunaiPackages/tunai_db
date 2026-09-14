import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../test/support/foreign_key_matrix.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerForeignKeyMatrix((name, body) => testWidgets(name, (_) => body()));
}
