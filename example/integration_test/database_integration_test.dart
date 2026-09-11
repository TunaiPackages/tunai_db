import 'lab_integration_test.dart' as lab;
import 'schema_recovery_integration_test.dart' as recovery;

/// Run existing behavior and populated schema recovery on the same native target.
void main() {
  lab.main();
  recovery.main();
}
