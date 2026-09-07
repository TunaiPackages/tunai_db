import 'dart:convert';

import 'lab_database.dart';

enum LabStatus { pending, running, passed, failed }

class LabCase {
  const LabCase(
    this.id,
    this.category,
    this.title,
    this.run, {
    this.crucial = false,
    this.knownIssue,
  });
  final String id;
  final String category;
  final String title;
  final Future<void> Function(LabDatabase db) run;
  final bool crucial;
  final String? knownIssue;
}

class LabResult {
  const LabResult(
    this.test,
    this.status, {
    this.elapsed = Duration.zero,
    this.detail = '',
  });
  final LabCase test;
  final LabStatus status;
  final Duration elapsed;
  final String detail;
  Map<String, Object?> toJson() => {
    'id': test.id,
    'category': test.category,
    'title': test.title,
    'crucial': test.crucial,
    'status': status.name,
    'milliseconds': elapsed.inMilliseconds,
    'detail': detail,
    if (test.knownIssue != null) 'knownIssue': test.knownIssue,
  };
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void equal(Object? actual, Object? expected, String message) {
  if (jsonEncode(actual) != jsonEncode(expected)) {
    throw StateError(
      '$message\nExpected: ${jsonEncode(expected)}\nActual: ${jsonEncode(actual)}',
    );
  }
}

Future<void> rejects(
  Future<void> Function() action, {
  bool Function(Object)? accepts,
}) async {
  try {
    await action();
  } catch (error) {
    if (accepts != null && !accepts(error)) rethrow;
    return;
  }
  throw StateError(
    'Expected the operation to reject invalid data, but it succeeded.',
  );
}
