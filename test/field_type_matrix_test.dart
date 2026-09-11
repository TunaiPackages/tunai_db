import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/field_type_matrix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform original;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('tunai-field-matrix-');
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = original;
    await directory.delete(recursive: true);
  });
  registerFieldTypeMatrix((name, body) => test(name, body));
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getLibraryPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
