import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:example/lab/lab_case.dart';
import 'package:example/lab/lab_runner.dart';
import 'package:example/lab/lab_suite.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const includeKnown = bool.fromEnvironment(
    'LAB_INCLUDE_KNOWN_ISSUES',
    defaultValue: true,
  );
  testWidgets(
    'TunaiDB native backend scenarios',
    (tester) async {
      final suite = createLabSuite();
      final runner = LabRunner(suite);
      try {
        // Real platform plugins and actual database files; no mocked DB factory.
        await runner.run(
          suite.where((c) => includeKnown || c.knownIssue == null).toList(),
        );
        binding.reportData = runner.report();
        final failures = runner.results.where(
          (r) => r.status == LabStatus.failed,
        );
        expect(
          failures,
          isEmpty,
          reason: const JsonEncoder.withIndent(
            '  ',
          ).convert(failures.map((r) => r.toJson()).toList()),
        );
      } finally {
        runner.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
