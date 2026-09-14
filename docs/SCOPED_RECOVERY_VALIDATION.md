# Scoped recovery validation

This change replaces the previous full-database-only fallback with table-scoped
recovery. Affected tables and their transitive old/target FK dependents may be
emptied; unrelated rows and parents remain. Empty primary-key changes require no
recovery. Whole-database replacement remains the final fallback.

## Completed checks

- 508 current-engine package tests passed.
- 26 focused recovery/observability tests passed after final metadata assertions.
- Nine SQLite engines, 3.8.10.2 through 3.39.4, passed compatibility and focused
  scoped recovery tests (eight new regressions per engine).
- 30 actual worker-process interruption cases passed with 50,000 rows, across
  WAL and DELETE journals, including scoped recovery before/after commit.
  Preserved parent rows are explicitly checked after recovery and reopening.
- Standalone Tunaipro declarations: 47 schema/storage cases passed.
- Historical v160, v173, prod v184 and prod v185: 21 cases each on FFI SQLite
  3.53.4 and native macOS SQLite 3.51.0, 42 cases total. Every retained value,
  physical schema, integrity/FK check, fresh write and reopen was verified.
- Package analysis reports 92 pre-existing findings, none in changed code.

## Historical outcomes

| Source | Populated upgrade recovery | Unrelated data |
| --- | --- | --- |
| v160 | delivery, shift, staff_shift | Preserved |
| v173 | None | Preserved |
| v184 | member_upload | Preserved |
| v185 | member_upload | Preserved |

V160 with affected tables empty now returns ready, rather than resetting the
whole database. Its large fixture preserves 52,250 rows in retained tables.
Removed declarations still intentionally remove their data; they are distinct
from recovery. No historical test required a full database reset.

## Evidence and reproduction

`validation/scoped_recovery/` contains package logs, engine provenance and the
interruption report in this local worktree. The standalone lab's
`validation/scoped_recovery/RESULTS.md` records per-version counts, exact source
provenance, implementation hashes, fixture paths, engine results and commands.
The lab uses a local dependency override for this working tree. Production POS
pins are unchanged; no customer DB or backend was used.

Run `flutter test`, `flutter analyze --no-pub`, the real-engine runner described
in SQLITE_COMPATIBILITY.md, and `tool/test_persistence_stress.py --only
interruptions --output <new-directory>` to repeat package validation. The
interruption measurement tool now tolerates non-UTF-8 diagnostics from `ps`;
this fixed a measurement-only interruption and all incomplete cases were rerun
from fresh seed copies.

A subsequent mobile retest passed 63 scenarios on iOS 26.4 (native SQLite
3.51.0) and 63 on Android 16/API 36 (the configured FFI SQLite 3.53.4).
Android runner transport issues required directly launching the test entry
point; all 63 per-case assertion files and the device success log were saved.
The disconnected host-driver exit is not counted as a passing check. The app-owned SQLite 3.22 UPSERT
trigger issue remains deferred. Cleared tables can still contain unsynced data;
TunaiDB does not decide whether app records are safe to re-download.

## Deployment assessment (11 September 2026)

Engineering confidence: 90/100 for the library behavior, 80/100 for immediate
POS deployment readiness. These are subjective assessments, not statistical
failure probabilities. Suitable for a controlled integration build; full POS
production readiness has not been established.

The tests include INTEGER/REAL/TEXT conversions in all six directions; default
addition/change/removal; NULL, invalid storage and numeric precision boundaries;
multiple simultaneous column changes; indexes, PK identity and auto-increment;
FK add/remove/retarget, orphans, cycles and old/target dependent closure; trigger
updates; complete-model matching; failed replacement rollback; read-only and
real database-full failures. Query/write regression tests are included in 508.
The 26 focused tests and cross-platform scenarios overlap other suites and must
not be added as unique coverage.

Latest large fixtures reach 82,750 rows; process-kill tests use 50,000 rows.
These do not establish weak-device performance, physical power-loss durability,
flash-error recovery, or cross-isolate application lifecycle correctness.
Historical fixtures use exact old declarations/library versions and fake data,
not customer files or every accumulated production schema drift.

No historical scenario required full-database fallback. Its existence does not
mean every possible fallback path has been fault-injected. Only declared FK
edges determine dependent groups; semantic relationships need app validation.
The new tablesRebuilt enum case may require exhaustive consumer switches to
change. Consumers must await initialization and handle empty affected tables.

The POS pin remains a504c5fe71da46a4d5a1157b7f20add2ffdf4aa3. Before adoption,
pin the published candidate consistently, resolve its lockfile, and validate
both apps plus startup/resync/offline/pending-upload behavior. Populated v184 and
v185 member_upload recovery loses those local queue rows; no claim is made that
unsynced data can be downloaded again. No app-owned upload policy is implemented.
Earlier POS broad tests failed/interrupted and are not a regression sign-off.

## Initialization logging follow-up

Initialization now adds attempt/stage/elapsed time and lifecycle/engine/outcome
messages using the existing logger contract. The POS adapter maps these to info,
error and fatal, including background isolates. This changes diagnostics, not
schema SQL or recovery decisions. The preceding mobile source hashes describe
the pre-logging candidate; no new mobile run is claimed for this follow-up.

Validation: 511 package tests passed, including 29 focused initialization/recovery
tests (overlapping the full suite). New cases assert scoped recovery and reopen
logs, terminal failure without a completed event, omitted paths/DDL, and survival
of a throwing diagnostic sink. Package analysis retains 92 existing findings,
none in changed files. POS severity routing has a passing focused test.
