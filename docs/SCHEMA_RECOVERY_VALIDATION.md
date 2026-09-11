# Schema recovery validation — 11 September 2026

This revision broadens last-resort recovery beyond individually recognized
incompatibilities to unsupported legacy parser/SQL shapes. Target replacement
must validate in the same transaction before original contents are discarded.
No consuming-app dependency pins, customer databases or remote branches changed.

## Behavior verified

- Compatible populated updates preserve rows and unknown schema.
- Incompatible nullability/key changes produce verified empty registered schema.
- Valid single-quoted legacy column declarations outside parser support recover.
- A legacy view occupying a registered table name recovers to a writable table.
- New writes survive reopening without triggering another rebuild.
- Failed target replacement preserves the complete original database.
- Partial-table repair, invalid declarations, read-only and database-full errors
  do not discard data; initialization invalidates failed/closed handles.

## Package checks

- `flutter test --reporter expanded`: **69 passed** (58 existing + 11 recovery).
- Focused analysis of changed schema code, recovery tests, integration suite and
  driver: **no issues**.
- Whole-package analysis: **92 findings in untouched files**, not a clean result.
- The earlier example host run passed 73 tests (68 database scenarios and five
  runner/UI tests). The revised combined native suite reruns all 68 database
  scenarios plus the expanded recovery/reopen test on every listed target.

## Native test method

`example/integration_test/database_integration_test.dart` combines the existing
68-scenario lab suite with the recovery integration test. The latter exercises
populated upgrade, preservation, fallback, subsequent writes/reopening, unsupported
legacy SQL and the table/view conflict. Tests use actual platform plugins,
SQLite backends and on-device files, with no host database/path-provider override.

The complete available simulator inventory was captured before testing. iOS
runs use temporary devices matching each original device type and runtime;
only those temporary devices are deleted afterward. An initial run and driver
validation also used the already-running iPad mini. Android runs use both
installed AVDs, started and stopped by this task. All fixtures are synthetic.

The first iOS configuration ran through `flutter test`; subsequent configurations
reuse a single compiled integration-test app through `flutter drive` and
`test_driver/database_driver.dart`. Every configuration executes both test groups;
reusing the binary does not reuse test results. Native macOS also passed both
expanded test groups.

The iOS/macOS/Android example harnesses resolve sqflite 2.4.3,
sqflite_common_ffi 2.4.2+1 and sqlite3 3.5.2. The root host harness resolves
sqflite 2.4.4 and sqflite_common_ffi 2.4.3 with sqlite3 3.5.2. Android uses the
package's FFI backend/Application Support path; iOS/macOS use native SQLite and
Library storage. The isolated Android copy was byte-compared against all 32
implementation and integration entrypoint source files used by the iOS worktree.

## Limits

This verifies installed simulator configurations, not every historical OS release
or physical device. No crash-kill/power-loss testing, arbitrary concurrent app
writer testing, TunaiPro login integration, or signed TestFlight consumer testing
was performed. Callers must quiesce database users before initialization.
Storage failure and corruption are not automatically treated as schema errors.
One temporary simulator printed an OS data-migration warning during boot, but
subsequently executed and passed both test groups. Android emitted an existing
Kotlin build-migration warning; both APK builds and test runs succeeded.

## Platform results

**All 27 iOS configurations, both Android AVDs and native macOS passed.**

| Platform/runtime | Configurations | Result |
| --- | --- | --- |
| iOS 26.2 | 8 | All passed |
| iOS 26.4 | 9 | All passed |
| iOS 26.5 | 10 | All passed |
| Android API 36 / Pixel_6a | 1 | Passed |
| Android API 36.1 image / Medium_Phone_API_36.1 | 1 | Passed |
| macOS 26.4.1 | 1 | Passed |

See [the per-configuration matrix](SCHEMA_RECOVERY_SIMULATOR_RESULTS.json).
The source remained unchanged during the matrix; SHA-256 comparison confirmed
it still matches the implementation used for the Android copy and iOS binary.
Generated platform build changes were removed from the final source diff.
`git diff --check` passed. These checks preceded branch publication; no consumer was updated.
