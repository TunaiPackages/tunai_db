import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:example/lab/lab_app.dart';
import 'package:example/lab/lab_case.dart';
import 'package:example/lab/lab_runner.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1280, 900)]) {
    testWidgets('run, report failures and filter results at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cases = [
        LabCase('pass', 'CRUD', 'Write and read', (_) async {}, crucial: true),
        LabCase(
          'fail',
          'Queries',
          'Quoted text',
          (_) async {},
          knownIssue: 'Quotes need binding',
        ),
      ];
      final runner = LabRunner(
        cases,
        execute: (test) async => LabResult(
          test,
          test.id == 'pass' ? LabStatus.passed : LabStatus.failed,
          detail: test.id == 'pass' ? 'Saved correctly' : 'Query did not match',
        ),
      );
      addTearDown(runner.dispose);
      await tester.pumpWidget(TunaiDBLabApp(runner: runner));
      await tester.tap(find.byKey(const Key('run-all')));
      await tester.pumpAndSettle();
      expect(
        find.text('1 passed  ·  1 failed  ·  0 not completed'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Failures only'));
      await tester.pumpAndSettle();
      expect(find.text('Write and read'), findsNothing);
      await tester.tap(find.text('Quoted text'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Query did not match'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
