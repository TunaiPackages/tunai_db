import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:example/lab/lab_case.dart';
import 'package:example/lab/lab_runner.dart';
import 'package:example/lab/lab_suite.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getLibraryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final suite = createLabSuite();
  final results = <LabResult>[];
  late Directory root;
  final originalPaths = PathProviderPlatform.instance;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('tunai_db_lab_');
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDownAll(() async {
    final report = File('build/test_lab_results.json');
    await report.parent.create(recursive: true);
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'suite': 'TunaiDB Test Lab',
        'backend': 'sqflite_common_ffi',
        'platform': Platform.operatingSystem,
        'registered': suite.length,
        'executed': results.length,
        'results': results.map((r) => r.toJson()).toList(),
      }),
    );
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });
  for (final scenario in suite) {
    test(
      '${scenario.id}: ${scenario.title}',
      () async {
        final result = await executeCase(scenario);
        results.add(result);
        expect(result.status, LabStatus.passed, reason: result.detail);
      },
      tags: scenario.knownIssue == null ? [] : ['known-issue'],
    );
  }
}
