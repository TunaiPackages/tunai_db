# Interruption and large-database testing

Run the opt-in suite from the package root:

```sh
python3 tool/test_persistence_stress.py --output /tmp/tunai-persistence-new-run
```

The output directory must be empty. The runner copies the package and worker
into an isolated build directory to prevent concurrent Flutter builds from
changing its native-asset manifests. Use `--only interruptions` or `--only large`
to select a phase; `--interrupt-rows` defaults to 50,000 and `--large-rows` to
100,000 and 1,000,000. Keep at least several GB free for the default suite.
Requires Flutter and a POSIX host with `ps` (validated on macOS).

## Interruption method

The Python controller starts a real Flutter test worker using sqflite FFI. A
thin method-call observer delegates every SQL operation to the real driver. It
only provides checkpoints; it runs the real package migration SQL and SQLite
without substituting a fake database or changing SQL semantics.
The worker publishes its own PID, then pauses. The controller sends that worker
SIGKILL, preventing Dart cleanup, explicit rollback or database close. A separate
new worker reopens the resulting database and checks it before retrying migration.

Checkpoints cover table creation, copied batches, before/after dropping the old
table, before/after COMMIT, and last-resort replacement after dropping data and
after commit. Additional timed kills release a checkpoint and kill during active
copying or near commit. These timed races allow either complete old or complete
new state, never a mixture. A pre-commit checkpoint must reopen old state;
a post-commit checkpoint must reopen new state.

Both WAL and DELETE rollback journals use synchronous=NORMAL and a 2,000-page
cache. The 50,000-row fixture exceeds that cache. The controller verifies that
journal data was actually written in the late-copy/drop/pre-commit cases; this
is not exclusively an in-memory rollback test.

Every reopen checks SQLite integrity, foreign keys, absence of temporary rebuild
tables, row count, complete legacy schema where applicable, and every row's
identity, converted values, untouched payload, parent reference and added/removed
column contents. Retrying a normal migration must finish without rebuilding the
database. Last-resort replacement must restore old data when killed before
commit, or expose the complete empty registered schema after commit.

## Large fixture and measurements

The fixture has an integer primary key, a text-to-integer conversion with default
fallback, a text-to-real conversion with NULL fallback, integer-to-text conversion,
a retained 256-character payload plus a row-specific prefix, an unchanged foreign
key, a removed column, a new defaulted column, and an index replacement. One tenth
of integer inputs and one seventh of real inputs need substitution.

The large tests verify every row without loading the whole result set into Dart,
then close and reopen in another process and verify again. Reported migration time
covers `SchemaReconciler.update`; worker startup, compilation and verification are
outside that timer. RSS includes the Flutter test runtime and SQLite, not just
migration allocations. Peak logical file sizes include the database, journal/WAL
and shared-memory sidecar, sampled roughly every 50 ms. Very short peaks may be
missed; these are observations, not hard resource bounds. The final database file
may retain free pages after a table copy rather than shrinking automatically.

## Limits

SIGKILL tests application-process interruption, not physical power loss, kernel
failure, torn disk writes or a filesystem that violates SQLite's locking/fsync
assumptions. This suite runs on a macOS host; timings and memory measurements do
not predict performance on a low-memory Android handset. It is not a concurrent
multi-process writer stress test. Database files are disposable test fixtures;
no customer or app database is opened.

## Large-copy improvement

The original row-at-a-time INSERT path did not finish the million-row migration
within 193 seconds and was deliberately stopped. A native CPU sample showed
SQLite spending most of its time in statement-journal cleanup (`memjrnlTruncate`).
This was a performance finding, not a failed integrity check or a completed
million-row timing.

Converted rows are now inserted in groups using a VALUES CTE joined to their
source identities. Unchanged fields still stay inside SQLite, text binding stays
byte-safe, and the outer transaction/savepoint remains atomic. Each statement
uses at most 256 rows and respects the older 999-parameter limit for ordinary
model widths. The variable budget counts the source identity as well as every
changed field, so three converted fields use at most 249 rows per statement.
The existing six-column native/old-engine matrix also exercises this limit.

## Validated results (2026-09-11)

The final grouped-copy implementation passed all **30 forced-kill cases**,
15 each in WAL and DELETE mode, using 50,000 rows. Every reopen passed integrity,
foreign-key and row/schema checks; ordinary retries returned `ready`, with no
whole-database rebuild. Explicit recovery checkpoints obeyed the old-before-commit
and empty-new-after-commit contract. Initial smaller smoke runs also passed.

Measured on this macOS host using SQLite 3.53.4 (decimal MB):

| Rows | Migration | Starting DB | Final DB | Peak files | Peak worker RSS |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100,000 | 0.718 s | 33.0 MB | 63.2 MB | 96.2 MB | 166.3 MB |
| 1,000,000 | 12.134 s | 330.5 MB | 631.8 MB | 962.3 MB | 221.0 MB |

Both sizes passed complete data verification and a separate-process reopen.
The million-row run completed normally with `ready`. Allow disk headroom: the
observed peak is about three times the starting file, and the file remains
larger afterward because SQLite retains reusable free pages. No automatic
VACUUM or database reset was introduced.

Related checks after the grouped-copy change: all **500 package tests**;
**424 native cases each on iOS, macOS and Android 9 / SQLite 3.22.0**;
the historical-engine matrix passed **463 cases on each of eight engines**
and **464 on SQLite 3.39.4**. This includes the older 999-parameter bound,
embedded NUL text, multiple converted columns, and WITHOUT ROWID identities.
Full analysis retains 92 pre-existing findings; changed Dart files are clean.

The deliberately stopped original million-row copy was also reopened after the
fix. All 1,000,000 original rows and the legacy schema were intact. Retrying the
grouped migration returned `ready` and passed full verification; no database
rebuild was needed. This provides an additional interruption/retry check at the
larger size, beyond the 30 controlled 50,000-row cases.
