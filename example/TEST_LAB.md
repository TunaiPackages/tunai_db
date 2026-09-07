# TunaiDB Test Lab

A runnable Flutter app for checking TunaiDB against **real SQLite databases**.
It shares 68 scenarios with automated tests. The existing example remains at
`lib/main.dart`; this lab starts at `lib/test_lab.dart`.

## Run the app

From this directory:

```sh
flutter pub get
flutter run -d macos -t lib/test_lab.dart
```

For iOS, Android or Windows, replace `macos` with a device ID from
`flutter devices`. These platforms have example scaffolds; only macOS was
verified for this change. Web is not supported by this `dart:io` package.

Select **Run all**, or choose a category / **Crucial only** and use **Run selected**.
Expand a result to see assertions, stack traces and any recorded defect.
**Failures only** filters the list. Stopping waits for the current case and its
cleanup; it does not interrupt a SQLite transaction. Copy or save a JSON report
using the app-bar buttons. Saved reports go into
`<application documents>/tunai_db_test_lab_reports/`.

Every run starts fresh results. Unselected or stopped cases stay `pending`, never
`passed`. A known-issue annotation is diagnostic: it does **not** alter the
assertions or turn a failure green.

## Crucial coverage

| Area | Scenarios and public behavior |
| --- | --- |
| Lifecycle (9) | Initialization, durable close/reopen, outlet isolation, read-only reads and rejected writes, attaching an existing handle, `updateDB` false/true, explicit reset, trigger startup/status/replacement/rollback, `deleteTable` row clearing |
| Writes (12) | `insert`, partial upsert, converters, Unicode/quotes/JSON, SQL NULL, `insertList` across 1,205 rows, `insertJsons`, scoped update/delete/deleteAll, 40 concurrent queued writes, constraint rollback, later-chunk failure, queue recovery, conversion failures, missing modeled primary key |
| Queries (11) | All six comparison operators, AND/OR grouping, numeric/string/empty IN, sorting/pagination/count/sum, whitespace search, LIKE, quotes, predicate injection, literal wildcard search, empty aggregates, diagnostic raw reads |
| Joins (7) | `fetchWithLeftJoins`, `fetchWithTables`, `TunaiJoinedDB`, aliases, matched/unmatched rows, filters, sorting/pagination, optional empty join list |
| Schema and integrity (15) | Historical appointment default drift, populated upgrades, new required columns, quoted/expression defaults, NULL preservation, safe and lossy type changes, full rollback, retained unknown schema objects, UNIQUE/CHECK constraints, indexes/triggers/views, idempotence, foreign keys/cascades/PRAGMA restoration, AUTOINCREMENT high-water mark, generated/STRICT columns and rowids, rejected key changes |
| Safety regressions (11) | Bound mutation scope, nested filters, scalar/blob round trips and NUL rejection, primary-key-only writes, converter rollback, invalid batch sizes, repeated keys, conflict policies and FK preservation, literal search, join bindings and offset-only pagination |
| Compatibility (3) | Deprecated numeric `fetchByFieldValues` including custom conversion, reference-driven `fetchWithInnerJoin`, custom logging |

Category counts group schema and integrity together. Several scenarios exercise
multiple APIs. Public `DBReference` metadata drives joins; it is not itself an
enforced SQLite foreign-key declaration. Integrity scenarios create historical
physical constraints explicitly to test their preservation.

## Automated checks

```sh
# Complete contract suite + runner and responsive UI tests.
# Runs every regression, including all previously failing cases.
flutter test test/lab

# Explicitly selected healthy subset (NOT a complete package certification).
flutter test test/lab --exclude-tags known-issue

# Native platform plugins, without the host-test FFI/path-provider override.
flutter test integration_test/lab_integration_test.dart -d macos

# Optional native healthy subset; excluded cases remain pending in its report.
flutter test integration_test/lab_integration_test.dart -d macos \
  --dart-define=LAB_INCLUDE_KNOWN_ISSUES=false

flutter analyze lib/lab lib/test_lab.dart test/lab integration_test

# Existing package regressions, from the package root:
cd ..
flutter test
```

The host suite writes `build/test_lab_results.json` even when assertions fail.
It records registered and executed counts so a filtered run cannot masquerade
as a complete run. Native integration attaches its JSON report to
`IntegrationTestWidgetsFlutterBinding.reportData` for integration drivers.
The UI and host suite use the same `executeCase` implementation and scenarios.
Five additional tests cover runner cancellation/error handling and the UI at
390×844 and 1280×900.

## Fixed baseline defects

Against package source based on
`a504c5fe71da46a4d5a1157b7f20add2ffdf4aa3`, the original host suite reported **46 passed,
11 failed**. All 11 defects below are now fixed, their annotations removed, and
the assertions retained. The expanded suite passes **68 of 68 scenarios**.

| Regression ID | Historical defect now fixed |
| --- | --- |
| `crud-null-write` | `insert` / `insertList` turn nullable TEXT into the string `"null"` |
| `crud-converter-write-error` | Batch converter errors are logged and skipped rather than thrown |
| `crud-missing-key` | Writes without a modeled primary key report success |
| `query-apostrophe` | Unbound quoted text breaks a filter query |
| `query-input-scope` | String interpolation lets filter text widen the SQL predicate |
| `query-in-strings` | String IN values are not safely bound |
| `query-search-wildcard` | Escaped wildcard searches lack the required SQL ESCAPE semantics |
| `query-empty-sum` | Empty SUM casts NULL directly to double |
| `join-table-page` | `fetchWithTables` emits OFFSET before LIMIT |
| `join-standalone-page` | `TunaiJoinedDB` orders SQL pagination clauses incorrectly |
| `join-empty-list` | A SELECT with no optional joins contains a trailing comma |

Validation commands above cover the complete host suite (68 database scenarios
plus five runner/UI tests), native platform integration, and the package's
58 regression tests. The original login-upgrade case and every schema/integrity
case remain in the suite. No scenarios are currently tagged `known-issue`.

These fixes preserve ordinary automatic schema reconciliation. Existing literal
`"null"` strings are not rewritten: the package cannot know which stored text
was intentional. See [query/write contracts](../docs/QUERY_AND_WRITE_SAFETY.md).

## Isolation and limits

Each case uses a unique `tunai_db_test_lab_<timestamp>_<case>.db` and cleans up
only the path it owns. No customer database, account or network service is used.
Tests run sequentially because TunaiDB owns a singleton connection. Do not embed
the lab in a production app or run two lab runners in the same isolate.
The reset scenario deliberately resets only its own test file. A forcibly
terminated process may leave a test file; it will not be reused by a later run.

Raw SQL is restricted to historical fixtures, constraint setup and assertions;
application-level writes and reads exercise TunaiDB. The host tests substitute
only filesystem locations and SQLite backend, not database behavior.

This is broad functional regression coverage, not an exhaustive proof of every
argument combination, SQLite version or failure mode. It does not simulate
power loss, filesystem corruption, disk exhaustion, production-size workloads,
multi-isolate access, a physical legacy SQLite release, or nested write-queue transactions. The
pre-UPSERT write path is separately exercised using an attached SQLite handle. Android/iOS/Windows execution remains to be verified on devices.
The package's 58 package tests provide additional schema/parser/trigger cases.

## Add a regression

Add a `LabCase` to the relevant `lib/lab/scenarios/*_cases.dart` file. Use `f.open`
to own the database, operate through `RowDB` / public APIs, and assert the final
stored state. Set `crucial: true` for data-loss, silent-success, login-upgrade or
scope-isolation risks. Never change an assertion to accept a demonstrated bug.
If a case uses a temporary second fixture, dispose it in `finally`. Do not add
unbounded waits or cancel a case before its database operations finish.
