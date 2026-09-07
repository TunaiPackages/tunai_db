import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:example/lab/lab_case.dart';
import 'package:example/lab/lab_runner.dart';

void main() {
  final first = LabCase('first', 'test', 'First', (_) async {});
  final second = LabCase(
    'second',
    'test',
    'Second',
    (_) async {},
    knownIssue: 'Recorded defect',
  );

  test(
    'stop waits for current cleanup and leaves remaining cases pending',
    () async {
      final completion = Completer<LabResult>();
      var calls = 0;
      final runner = LabRunner(
        [first, second],
        execute: (_) {
          calls++;
          return completion.future;
        },
      );
      final active = runner.run(runner.cases);
      await runner.run(runner.cases);
      expect(calls, 1);
      runner.stopAfterCurrent();
      expect(runner.running, isTrue);
      completion.complete(LabResult(first, LabStatus.passed));
      await active;
      expect(runner.running, isFalse);
      expect(runner.results.map((r) => r.status), [
        LabStatus.passed,
        LabStatus.pending,
      ]);
      expect(runner.report()['stopped'], isTrue);
      runner.dispose();
    },
  );

  test(
    'executor errors remain failures and do not prevent subsequent cases',
    () async {
      final runner = LabRunner(
        [first, second],
        execute: (test) async {
          if (test == first) throw StateError('unexpected runner error');
          return LabResult(test, LabStatus.failed, detail: 'Actual defect');
        },
      );
      await runner.run(runner.cases);
      expect(runner.results.every((r) => r.status == LabStatus.failed), isTrue);
      expect(runner.results.first.detail, contains('unexpected runner error'));
      final report = runner.report()['results'] as List;
      expect(report.last['knownIssue'], 'Recorded defect');
      expect(report.last['status'], 'failed');
      runner.dispose();
    },
  );

  test(
    'disposing during execution allows cleanup without stale notifications',
    () async {
      final completion = Completer<LabResult>();
      final runner = LabRunner([
        first,
        second,
      ], execute: (_) => completion.future);
      final active = runner.run(runner.cases);
      runner.dispose();
      completion.complete(LabResult(first, LabStatus.passed));
      await active;
      expect(runner.results.last.status, LabStatus.pending);
    },
  );
}
