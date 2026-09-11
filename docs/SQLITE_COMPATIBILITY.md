# SQLite engine compatibility

TunaiDB must preserve data during ordinary migrations on older engines rather
than treating an unavailable inspection PRAGMA as a broken schema.

## Compatibility fix

SQLite added `PRAGMA table_xinfo` in [3.26.0](https://sqlite.org/releaselog/3_26_0.html).
Older versions return no rows for that unknown PRAGMA. The previous updater then
failed to find declared columns, even when creating a fresh database. Reproduced
against the actual 3.8.10.2 engine before applying the fix.

All three column-inspection paths now share a helper: use `table_xinfo` when it
returns rows, otherwise use `table_info` and mark ordinary columns `hidden=0`.
Modern engines keep generated/hidden-column inspection. This applies to full
initialization, partial schema repair and final schema verification. No data
reset is needed to compensate for an unavailable PRAGMA.

## Real-engine matrix

`tool/test_sqlite_versions.py` downloads upstream SQLite amalgamations over HTTPS
and runs the package's actual Dart reconciliation code against each engine,
using the existing sqflite FFI adapter and sqlite3 native build hook. It does not
mock SQL, downgrade Dart dependencies, patch SQLite, or modify the app checkout.
Each run uses a disposable package copy and asserts `SELECT sqlite_version()`.
The output records the source archive URL, SHA-256, exit code and test log.

```sh
python3 tool/test_sqlite_versions.py --output /tmp/tunai-sqlite-compat
# Or select particular engines:
python3 tool/test_sqlite_versions.py --output /tmp/tunai-sqlite-compat 3.8.10.2 3.22.0
```

Requires Flutter, a C compiler and network access. The output directory retains
sources, build artifacts and logs for inspection. Build options
are upstream defaults with threads and column metadata enabled; no schema or
foreign-key behavior is overridden.

The matrix includes column conversions, all field-type/default combinations,
600-row simultaneous changes, NULL/default fallback, foreign keys, pre-UPSERT
writes, partial schema repair, trigger preservation, rollback, full recovery,
reopening, storage-full refusal, indexes and AUTOINCREMENT state. The single test
that creates a generated-column `STRICT` table is excluded below 3.37, where its
input schema is unsupported; all ordinary schema cases still run.

## Foreign-key engine differences

Mixed parent/child types are not equally portable across SQLite releases.
The tests found these upstream differences, independently of migrations:

- A whole REAL child compared against a TEXT parent can stringify differently.
  Relationship probes use a fractional value to avoid that ambiguity.
- 3.32.2 and 3.39.4 rejected insertion into a REAL child referencing an INTEGER
  primary key, even with a matching integer value. The same SQL failed on a
  fresh schema without TunaiDB. Tests compare migrated behavior against a fresh
  baseline on the same engine; orphan insertion must still fail. No constraint
  is disabled or weakened to make a test pass.

For portable relationships, declare matching parent/child types. Ordinary-column
conversion does not guess key mappings or override an engine's constraints.

## What these checks establish

The historical matrix uses real SQLite engines compiled and exercised on macOS.
A separate Android 9 emulator run verifies SQLite 3.22.0 through the native
Android driver. Together they verify SQL and migration compatibility,
not an old device's filesystem, vendor patches, memory limits, Android driver,
or the minimum Android version supported by Flutter and plugins.

[Android's version table](https://developer.android.com/reference/android/database/sqlite/package-summary)
places SQLite 3.8 in API 21, 3.9 in API 24, 3.18 in API 26, 3.22 in API 28,
3.28 in API 30 and 3.32 in API 31–33. These are release families, not guarantees
of a device's exact patch level; vendors can supply different SQLite versions.
The oldest engine tested here is 3.8.10.2, not every earlier 3.8 patch.

## Validation on 2026-09-11

| SQLite engine | Passed tests |
| --- | ---: |
| 3.8.10.2 | 463 |
| 3.9.2 | 463 |
| 3.18.0 | 463 |
| 3.22.0 | 463 |
| 3.24.0 | 463 |
| 3.25.3 | 463 |
| 3.28.0 | 463 |
| 3.32.2 | 463 |
| 3.39.4 | 464 |

Also passed: all 500 current-engine package tests and 424 native cases on an
Android 16 / API 36 emulator. Full analysis reports the same 92 existing
findings; none are in changed files.

The older Android 9 / API 28 ARM64 emulator also passed all **424 native cases**.
Its system `sqlite3 --version` reported **3.22.0**, source ID
`2018-12-19 01:30:22 c255889bd95bd5430dc7ced3317011ae2abb483d6c9af883af3dc7d6c2c2alt2`.
This exercises the pre-table_xinfo fallback through Android's native SQLite driver.
No physical old handset or every vendor patch was tested.
