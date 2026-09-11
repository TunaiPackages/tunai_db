#!/usr/bin/env python3
"""Run real TunaiDB tests against upstream SQLite engines in disposable copies.

No application dependency or local Flutter session is changed. Requires Flutter,
a C compiler, and network access to sqlite.org. Logs/artifacts remain in --output.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request
import zipfile

RELEASES = {
    '3.8.10.2': (2015, '3081002'),
    '3.9.2': (2015, '3090200'),
    '3.18.0': (2017, '3180000'),
    '3.22.0': (2018, '3220000'),
    '3.24.0': (2018, '3240000'),
    '3.25.3': (2018, '3250300'),
    '3.28.0': (2019, '3280000'),
    '3.32.2': (2020, '3320200'),
    '3.39.4': (2022, '3390400'),
}
ROOT = Path(__file__).resolve().parents[1]


def run(version, output):
    year, number = RELEASES[version]
    folder = output / version
    folder.mkdir(parents=True, exist_ok=True)
    archive = folder / 'sqlite.zip'
    url = f'https://sqlite.org/{year}/sqlite-amalgamation-{number}.zip'
    if not archive.exists():
        with urllib.request.urlopen(url, timeout=60) as response:
            archive.write_bytes(response.read())
    with zipfile.ZipFile(archive) as source:
        for name in ['sqlite3.c', 'sqlite3.h']:
            (folder / name).write_bytes(source.read(f'sqlite-amalgamation-{number}/{name}'))
    project = folder / 'package'
    project.mkdir(exist_ok=True)
    for name in ['lib', 'test']:
        shutil.copytree(ROOT / name, project / name, dirs_exist_ok=True)
    for name in ['pubspec.lock', 'analysis_options.yaml']:
        if (ROOT / name).exists():
            shutil.copy2(ROOT / name, project / name)
    pubspec = (ROOT / 'pubspec.yaml').read_text()
    pubspec += '\nhooks:\n  user_defines:\n    sqlite3:\n      source: source\n'
    pubspec += f'      path: {json.dumps(str(folder / "sqlite3.c"))}\n'
    pubspec += '      defines:\n        default_options: false\n        defines:\n          - SQLITE_THREADSAFE=1\n          - SQLITE_ENABLE_COLUMN_METADATA\n'
    (project / 'pubspec.yaml').write_text(pubspec)
    (project / 'test/engine_version_test.dart').write_text(f'''import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
void main() {{
  test('actual SQLite engine is {version}', () async {{
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    try {{
      expect((await db.rawQuery('SELECT sqlite_version()')).single.values.single, '{version}');
    }} finally {{ await db.close(); }}
  }});
}}
''')
    log = folder / 'test.log'
    with log.open('w') as stream:
        resolved = subprocess.run(['flutter', 'pub', 'get'], cwd=project, stdout=stream, stderr=subprocess.STDOUT)
        result = resolved
        if resolved.returncode == 0:
            result = subprocess.run(['flutter', 'test', 'test/engine_version_test.dart',
                'test/column_conversion_test.dart', 'test/field_type_matrix_test.dart',
                'test/foreign_key_matrix_test.dart', 'test/write_fallback_test.dart',
                'test/schema_reconciliation_test.dart', 'test/schema_recovery_test.dart',
                *(['--name', '^(?!.*preserves hidden rowids, generated columns and STRICT table options).*$']
                  if tuple(map(int, version.split('.'))) < (3, 37, 0) else [])],
                cwd=project, stdout=stream, stderr=subprocess.STDOUT)
    evidence = {'version': version, 'source': url,
        'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
        'exit_code': result.returncode, 'log': str(log)}
    (folder / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence), flush=True)
    return result.returncode


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('versions', nargs='*', default=list(RELEASES), choices=list(RELEASES))
    args = parser.parse_args()
    codes = [run(version, args.output.resolve()) for version in args.versions]
    raise SystemExit(1 if any(codes) else 0)
