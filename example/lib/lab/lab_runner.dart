import 'dart:io';

import 'package:flutter/foundation.dart';

import 'lab_case.dart';
import 'lab_database.dart';

Future<LabResult> executeCase(LabCase test) async {
  final watch = Stopwatch()..start();
  final database = LabDatabase(test.id);
  String? error;
  try {
    await test.run(database);
  } catch (failure, stack) {
    error = '$failure\n$stack';
  } finally {
    try {
      await database.dispose();
    } catch (failure, stack) {
      error =
          '${error == null ? '' : '$error\n'}Cleanup failed: $failure\n$stack';
    }
  }
  return LabResult(
    test,
    error == null ? LabStatus.passed : LabStatus.failed,
    elapsed: watch.elapsed,
    detail: error ?? 'Assertions passed; isolated database cleaned up.',
  );
}

class LabRunner extends ChangeNotifier {
  LabRunner(this.cases, {this.execute = executeCase});
  final List<LabCase> cases;
  final Future<LabResult> Function(LabCase) execute;
  final Map<String, LabResult> _results = {};
  bool _disposed = false;
  bool running = false;
  bool stopRequested = false;
  DateTime? startedAt;
  List<LabResult> get results => cases
      .map((c) => _results[c.id] ?? LabResult(c, LabStatus.pending))
      .toList();

  Future<void> run(List<LabCase> selected) async {
    if (running || selected.isEmpty) return;
    running = true;
    stopRequested = false;
    startedAt = DateTime.now();
    _results.clear();
    _emit();
    try {
      for (final test in selected) {
        if (stopRequested) break;
        _results[test.id] = LabResult(test, LabStatus.running);
        _emit();
        try {
          _results[test.id] = await execute(test);
        } catch (error, stack) {
          _results[test.id] = LabResult(
            test,
            LabStatus.failed,
            detail: '$error\n$stack',
          );
        }
        _emit();
      }
    } finally {
      running = false;
      _emit();
    }
  }

  void stopAfterCurrent() {
    stopRequested = true;
    _emit();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    stopRequested = true;
    _disposed = true;
    super.dispose();
  }

  Map<String, Object?> report() => {
    'suite': 'TunaiDB Test Lab',
    'platform': Platform.operatingSystem,
    'dart': Platform.version,
    'startedAt': startedAt?.toIso8601String(),
    'running': running,
    'stopped': stopRequested,
    'results': results.map((r) => r.toJson()).toList(),
  };
}
