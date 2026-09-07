# Automatic schema updates

`DBTable` and `DBField` describe the schema. Register tables and triggers, then
await `TunaiDBInitializer().initDatabase(outletKey, updateDB: true)` before
starting application queries or background workers. `true` remains the default.
Developers do not write numbered migrations for ordinary schema changes.

The updater compares the physical SQLite schema with registered declarations
every time it runs. This supports skipped app versions and existing databases;
there is no migration version counter to keep in sync. An unchanged schema is a
no-op for tables and indexes. `updateTables(database, tables)` runs the same
engine for an already-open database and a selected set of tables.

## Supported changes

| Declaration change | Automatic behavior |
| --- | --- |
| New table | Create it and its declared indexes. |
| New ordinary column | Add it, filling existing rows from its declared default or NULL. |
| Existing column default | Rebuild the table with the new default, preserving all existing values, including NULLs. |
| Nullability | Rebuild; tightening succeeds only when existing values satisfy NOT NULL. A default does not replace existing NULLs. |
| Declared type | Rebuild only if copying to the new affinity preserves stored values. No casts or guessed conversions. |
| New index | Create it. An existing index with that name must belong to the correct table and column. |
| Registered trigger body | Replace atomically, after tables exist. SQL string literals remain case-sensitive. |
| Unregistered table, column, index or trigger | Retain it, including its data and constraints. |

For a new NOT NULL column on a populated table, provide a meaningful non-null
`defaultValue`. An empty table can receive a required column without a default.
String defaults are actual escaped string literals, including nonempty values;
finite numbers and booleans are supported. Arbitrary SQL expressions are not a
`DBField.defaultValue` API.

## How existing tables are rebuilt

The updater rewrites only changed type/default/nullability attributes in the
existing CREATE TABLE statement. Other column and table constraints, extra
columns, generated expressions, and STRICT/WITHOUT ROWID options are retained.
It creates a collision-free temporary table, copies explicitly named columns,
checks row counts and existing values, replaces the original, and restores its
indexes and triggers. Generated columns are recomputed and verified; hidden
rowids and AUTOINCREMENT high-water marks are retained. Existing views and
foreign-key references continue to name the original table.

All selected tables and registered triggers are reconciled in one SQLite
transaction. Copy errors, incompatible data, schema verification failures,
index conflicts, and integrity failures roll the transaction back. A retry
starts from the original schema; temporary rebuild tables do not survive a
failed transaction. No INSERT OR REPLACE/IGNORE, COALESCE, or database reset is
used to make bad data fit.

Following SQLite's [table rebuild procedure](https://www.sqlite.org/lang_altertable.html#making_other_kinds_of_table_schema_changes),
foreign-key enforcement is temporarily disabled before the transaction and its
original setting restored afterward. When originally enabled, foreign_key_check
must pass before commit. Existing violations also prevent commit. When originally
disabled, this updater does not impose a new foreign-key policy on legacy data.
legacy_alter_table is temporarily enabled during replacement to preserve views
and external trigger references, then restored. The connection's schema-update
PRAGMAs must not be changed by other work during this operation.

## Boundaries: information the schema cannot supply

The updater never guesses column renames, new row identities, foreign-key
mappings, or lossy value conversions. Changes to existing primary keys,
AUTOINCREMENT, or foreign-key targets, and new key columns, report a specific
error and preserve the database. Model changes to generated columns also stop.
A rowid table that shadows all three SQLite rowid aliases cannot be safely
rebuilt automatically. Resolve the model/data incompatibility deliberately;
do not recover by wiping customer data or swallowing the error.

Removing a declaration is not permission to delete persisted data. It can mean
an older app build is using a newer database. Intentional destructive cleanup
or semantic transformations remain explicitly owned operations, separate from
normal `updateDB`. No application-level migration is needed for the appointment
color default bug or supported ordinary changes above.

## Concurrency and lifecycle

Await initialization before exposing the connection to writers. Do not call
updateTables/synchronizeTriggers inside a caller-owned transaction: they own
their transaction and connection PRAGMAs. A package lock serializes updater calls
within an isolate; SQLite serializes transactions across handles and processes.
This does not make the initializer singleton safe for overlapping outlet
switches or permit arbitrary writes on the same connection during initialization.
The caller must serialize outlet initialization and coordinate worker startup.

`updateDB: false` opens without table or trigger reconciliation; fresh databases
still receive the registered tables through onCreate. This is useful for a
caller that explicitly owns initialization. It is not the normal login setting.
`resetDB: true` remains an explicit destructive operation, never automatic repair.
Calling synchronizeTriggers explicitly also preserves unregistered triggers.

## Regression coverage

Tests exercise legacy defaults, missing columns, fresh installs, actual
initDatabase true/false behavior, idempotency, quoted defaults, NULL preservation,
rollback and retry, lossy conversion rejection, constraints, custom indexes and
triggers, views, foreign-key cascades, generated columns, table options,
AUTOINCREMENT, rowids, and concurrent handles. Run `flutter test` and
`flutter analyze`; full analysis currently also reports legacy query/example
lint findings outside the updater.

## Branch transition

Historically Tunaipos pinned the production branch. Main contained an older API.
This change incorporates production's existing API into main, then fixes its
updater. Consumers must pin the tested main commit, not a moving branch.
The production branch itself is not advanced by this change.
