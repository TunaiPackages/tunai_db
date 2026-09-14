import 'package:integration_test/integration_test.dart';

import '../../test/version_zero_initialization_test.dart' as scenarios;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  scenarios.runVersionZeroTests(native: true);
}
