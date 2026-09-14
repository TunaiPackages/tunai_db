# Version-zero initialization fix validation

Candidate branch: `fix/version-zero-initialization`, based on
`d5a6aadc0f5263710545386cfbd0caae86e0f8cf`. POS remains pinned to that base; this
report is not an adoption or deployment record.

## Change

An existing file with `user_version=0` previously entered eager CREATE TABLE and
failed on already-present tables before reaching migration/recovery. With
`updateDB: true`, onCreate now checks sqlite_master for user tables/views. If
present, it defers schema changes to the existing reconciler. This applies to
both driver branches. No recovery classifier, conversion rule, transaction or
whole-database replacement policy changed. Fresh creation and updateDB:false
retain their behavior.

The new `existing_schema_detected; creation_deferred=true` event is normal info,
not evidence of table loss. Schema completion reports ready/scoped/full recovery
as before. It uses existing logging and failure-isolation behavior.

## Tests

Seven shared scenarios, in `test/version_zero_initialization_test.dart`:

1. Matching populated schema retains rows, accepts new writes/defaults, and
   reopens as version1 without recovery.
2. Partial populated schema converts TEXT values to INTEGER and creates a
   missing table.
3. Incompatible primary-key identity triggers table-scoped recovery, preserves
   an unrelated table's row, and reopens without repeated recovery.
4. A view occupying a target table name reaches reconciliation/recovery and
   results in a writable table while unrelated rows survive.
5. An invalid target fails without adding the missing table or losing rows;
   correcting the target allows a successful retry even after metadata advanced.
6. updateDB:false does not silently enable migration/recovery; existing rows and
   version-zero metadata survive the failed legacy creation attempt.
7. An empty version-zero file creates a usable schema normally.

Healthy cases check quick_check, foreign_key_check and resulting user_version.
The native integration entry point reuses exactly these scenarios with native
macOS/iOS connections; Android selects FFI, matching the package. Tests use only
unique disposable fake databases, never customer files.

Current-engine package suite: **518 passed** (511 existing plus seven new).
Native macOS: **all seven passed** through the native plugin. Analysis: **92
existing findings**, none in the changed initializer or new regression file.
The initial old-engine run exposed only a harness assumption: old quick_check
returns an integrity_check column label. The assertion now validates the result
value `ok`, independent of column label. See matrix results below for final runs.

No fresh iOS/Android device run, process-kill test, production database, POS
startup/resync or store-build validation for this candidate. Existing recovery,
rollback and foreign-key tests were rerun; transaction code was not changed.
App checkpoint invalidation and accepted Member CSV queue behavior are separate
work and have not been modified.

Commands and local evidence:

- `flutter test`: `/tmp/version-zero-all-tests.log`
- `flutter analyze`: `/tmp/version-zero-analysis.log`
- From example: `flutter test integration_test/version_zero_initialization_integration_test.dart -d macos`:
  `/tmp/version-zero-native-macos.log`
- `python3 tool/test_sqlite_versions.py --output /tmp/version-zero-sqlite-matrix <versions>`:
  each version directory records source URL, archive SHA256, actual engine
  assertion, exit code and complete test log.

Initializer source SHA256: `8810ab272d99209e679eed5aa5ded878b1642101dbcbb6856b02e068e6211b63`.
Focused analysis of the changed initializer and regression file: no issues.

## Final historical engine results

All nine final runs passed, including all seven new regressions on each engine.
The 3.8.10.2 and 3.9.2 runs were repeated after correcting the result-column
assertion; no production code change was needed for that harness correction.

| SQLite | Passing tests |
|---|---:|
| 3.8.10.2 | 481 |
| 3.9.2 | 481 |
| 3.18.0 | 481 |
| 3.22.0 | 481 |
| 3.24.0 | 481 |
| 3.25.3 | 481 |
| 3.28.0 | 481 |
| 3.32.2 | 481 |
| 3.39.4 | 482 |

These are repeated engine executions of overlapping cases, not thousands of
unique scenarios. The pre-3.37 runs exclude the existing generated/STRICT-table
case unsupported by those engines. Engine provenance and source archive hashes
are in each result.json. No engine requires a version-zero-specific reset.
