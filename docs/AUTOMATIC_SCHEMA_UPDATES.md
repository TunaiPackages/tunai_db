# Automatic schema updates

## Goal and recovery contract

TunaiDB owns reliable local storage and schema updates. Its priority is to keep
stored data usable across updates and preserve existing data wherever it can.
It is independent of any consuming app's business rules, login, upload queues,
network synchronization, or source of truth. The app decides how to populate an
empty database; TunaiDB does not download or reconstruct business data.

The agreed recovery order is:

1. Reconcile the registered schema while preserving existing data. Supported
   ordinary updates should succeed without application-written migrations.
2. Roll back a failed update before deciding recovery. Use supported,
   row-preserving reconciliation and the explicit ordinary-column conversion
   policy below; never guess key mappings or silently truncate numeric values.
3. Only when a schema incompatibility cannot be reconciled safely, rebuild the
   affected database from its complete registered schema as a last resort. This
   replaces its contents with an empty database; other databases are unaffected.
4. Verify the new tables, indexes and triggers before reporting success. Log the
   original failure, the fallback decision and its outcome, and explicitly report
   that the database was rebuilt. The app then handles the empty data itself.

Rebuilding is exceptional, undesirable recovery—not the normal upgrade path or
a substitute for improving reconciliation. Every rebuild should be diagnosable
and investigated for an updater improvement, with a populated regression case
when applicable. Removing a declaration is an intentional schema deletion, handled without a
whole-database rebuild whenever possible. Retained rows and column values survive.

A data-preserving **table rebuild** described below copies existing rows into an
updated table. A last-resort **database rebuild** discards the affected database's
contents and recreates the registered schema. These are different operations.

Do not turn every exception into a database rebuild. Disk exhaustion, permission
errors, unavailable storage, lock contention and invalid target declarations
are not fixed by discarding data. Report those failures rather than repeatedly
resetting. If last-resort rebuilding itself fails, report failure and never
expose a partially initialized database. Coordinate active handles before
replacement; a point-of-use update of selected tables is not a complete registry
from which to recreate a database.

Recovery must be observable through both logging and an explicit initialization
outcome distinguishing normal initialization from successful rebuilding. Log
schema/error categories and recovery stages without stored row values, secrets,
or application credentials. Initialization returns `DBInitializationResult.ready`,
`.rebuilt`, or `.reset`
(for an explicit caller-requested reset). A thrown error means initialization
did not complete; `hasInit` is false and the initializer exposes no handle.

### Implemented recovery boundary

`initDatabase(updateDB: true)` enables last-resort recovery for a nonempty complete
registry on a writable connection. `updateDB: false`, read-only opens and
selected-table `updateTables`/trigger synchronization never initiate a database
rebuild. Callers must quiesce all users of the affected database before calling
initialization; package locks do not stop arbitrary queries in another isolate.
Initialization calls on this singleton are serialized, and its handle is withheld
until preparation finishes. Previously selected handles are closed on reinitialization.

Recovery includes changed/new keys or relationships, changed generated columns,
unavailable preservable row identity, conflicting index definitions, value-changing
copies, constraints violated by copied legacy rows, and failed foreign-key
validation. It also handles legacy schema shapes outside the parser's support
and SQL conflicts such as a view occupying a registered table name.

During reconciliation only, StateError, FormatException, RangeError and
UnsupportedError can attempt replacement, as can SQLite ERROR (1), SCHEMA (17),
CONSTRAINT (19) and MISMATCH (20). Successful verification of a fresh replacement
is required before discarding the original data. Invalid declarations detected
up front fail without recovery; invalid target SQL discovered during replacement
rolls back the whole transaction. Unclassified driver errors, storage/locking
errors, integrity/corruption errors, opening/commit failures and PRAGMA cleanup
errors propagate. These are not schema-rebuild signals.

The updater uses a savepoint inside its exclusive update transaction. A recoverable
legacy schema failure rolls back that attempt, then removes user tables/views/triggers
and recreates the full registered schema in the same transaction. Indexes are
recreated from declarations. This is a logical database rebuild, not deletion of
the database file or its WAL sidecars. Undeclared objects/data are removed during full initialization;
successful last-resort rebuilding also clears the retained tables. Other database files remain untouched.

Replacement validation includes schema reconciliation, registered triggers,
`quick_check` and `foreign_key_check`. If replacement fails, the outer transaction
rolls back the original contents, and initialization closes/invalidates its
handle. There is one recovery attempt, never a reset loop. Logs distinguish the
reason, replacement commit and completed recovery without recording row values.
If connection cleanup fails after commit, initialization throws and closes the
handle; the commit log identifies that replacement already happened. Reopening
must validate again. Recovery does not promise success with broken storage.

```dart
final outcome = await initializer.initDatabase(databaseKey);
if (outcome == DBInitializationResult.rebuilt) {
  // The consuming app decides how to populate its now-empty database.
}
```

Existing callers may continue awaiting and ignoring the result, but applications
that need to react to recovery should inspect it. `resetDB: true` still requests
an explicit destructive reset and returns `.reset`; it is separate from fallback.

## Current initialization

`DBTable` and `DBField` describe the schema. Register tables and triggers, then
await `TunaiDBInitializer().initDatabase(outletKey, updateDB: true)` before
starting application queries or background workers. `true` remains the default.
Developers do not write numbered migrations for ordinary schema changes.

The updater compares the physical SQLite schema with registered declarations
every time it runs. This supports skipped app versions and existing databases;
there is no migration version counter to keep in sync. An unchanged schema is a
no-op for tables and indexes. `updateTables(database, tables)` runs the same
engine for an already-open database and a selected set of tables. It remains a
conservative repair: it does not infer deletions from an incomplete registry.
Use full initialization to apply model removals.

## Supported changes

| Declaration change | Automatic behavior |
| --- | --- |
| New table | Create it and its declared indexes. |
| New ordinary column | Add it, filling existing rows from its declared default or NULL. |
| Existing column default | Rebuild the table with the new default, preserving all existing values, including NULLs. |
| Nullability | Rebuild; tightening succeeds only when existing values satisfy NOT NULL. A default does not replace existing NULLs. |
| Declared type | For ordinary columns, convert each value, then use a valid declared default or nullable NULL. Preserve every other column and row. Keys remain strict. |
| Index enabled/disabled or conflicting definition | Create the declared nonunique index; drop obsolete/conflicting explicit indexes. |
| Registered trigger body | Replace atomically, after tables exist. SQL string literals remain case-sensitive. |
| Removed column | Copy retained values into the declared table, discarding the removed column. |
| Removed table | Drop it and its data. |
| Unregistered trigger or view | Drop it during full initialization. |
| Undeclared constraints/table options | Replace with the declared table definition, preserving compatible retained values. |

For a new NOT NULL column on a populated table, provide a meaningful non-null
`defaultValue`. An empty table can receive a required column without a default.
String defaults are actual escaped string literals, including nonempty values;
finite numbers and booleans are supported. Arbitrary SQL expressions are not a
`DBField.defaultValue` API.

## Best-effort ordinary-column conversion

During full initialization, an ordinary column whose declared type changes uses:

1. Explicit conversion into the new type.
2. Its declared default if conversion fails (including a stored NULL).
3. NULL if no default exists and the target allows NULL.
4. Failure/rollback if none is usable; the existing last-resort recovery policy applies.

INTEGER conversion accepts whole, signed-64-bit values and decimal/scientific
numeric strings. It does not truncate fractions or wrap overflow. REAL conversion
accepts finite numeric values and decimal strings, rejects precision loss for whole
integers, and rejects overflow/nonzero underflow. TEXT conversion uses numeric text
representations and preserves existing strings. Unsupported values such as blobs
use the fallback. Defaults are converted with the same rules; an unusable declared
default raises an invalid-model error and preserves the original database.

Only type-changed ordinary columns receive this treatment. A default-only change
still leaves existing values alone. Tightening nullability without a type change
still requires existing values to fit. Existing and target primary/foreign-key
columns, including referenced columns, are excluded from substitution. Partial
selected-table repair retains its strict, value-preserving behavior.

Copies use bounded batches in the same transaction. Other column values, row
identities, counts and relationships are validated before commit. Successful
conversion logs counts of converted/defaulted/nulled values after commit, without
logging row contents. Failed attempts never report successful substitution.

## How existing tables are rebuilt

Full initialization uses the model's CREATE TABLE definition as the target.
It creates a collision-free temporary table, copies common columns, checks row
counts and retained values, replaces the original, and restores declared indexes
and triggers. Removed columns and undeclared constraints are not copied. New
columns receive defaults or NULL. Row identity and AUTOINCREMENT high-water marks
are preserved when compatible. Unchanged schemas are a no-op.

Selected-table repair keeps its conservative legacy behavior: it rewrites only
changed type/default/nullability attributes, retaining extra objects and constraints.
It cannot interpret its selection as a complete database model.

All selected tables and registered triggers are reconciled in one SQLite
transaction. Copy errors, incompatible data, schema verification failures,
index conflicts, and integrity failures roll the transaction back. A retry
starts from the original schema; temporary rebuild tables do not survive a
failed transaction. No INSERT OR REPLACE/IGNORE is used to discard conflicting rows. Ordinary
column substitutions follow the explicit policy above. Full
initialization may then recover through the last-resort path described above.

Following SQLite's [table rebuild procedure](https://www.sqlite.org/lang_altertable.html#making_other_kinds_of_table_schema_changes),
foreign-key enforcement is temporarily disabled before the transaction and its
original setting restored afterward. Full initialization always requires foreign_key_check to pass before commit.
Partial repair checks it when enforcement was originally enabled.
legacy_alter_table is temporarily enabled during replacement to preserve views
and external trigger references, then restored. The connection's schema-update
PRAGMAs must not be changed by other work during this operation.

## Boundaries: information the schema cannot supply

The updater never guesses column renames, new row identities, foreign-key
mappings or key-value substitutions. Primary-key changes report a specific
incompatibility and roll back the data-preserving attempt. Full initialization
can update constraints and foreign keys when retained data validates; partial
repair continues to reject key/relationship and generated-column changes.
A rowid table that shadows all three SQLite rowid aliases cannot be safely
rebuilt automatically by the current reconciler. Selected-table repair propagates
these failures after rollback. Full
initialization can instead reach the logged last-resort database rebuild above;
it must never become a silent reset or swallowed error.

The complete registry is authoritative, including when opening a database created
by a newer app version. An empty registry deliberately removes all user objects.
Register every desired table and trigger before full initialization; SQLite's
internal objects are retained. Invalid references to undeclared parents fail
without committing deletions. Full initialization always validates foreign keys.

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
`resetDB: true` is an explicit destructive operation, separate from the
last-resort recovery contract above.
Calling synchronizeTriggers explicitly also preserves unregistered triggers.

## Regression coverage

`test/schema_recovery_test.dart` covers successful populated recovery, normal
preservation, failed replacement rollback, key changes, PRAGMA restoration,
partial-update exclusion, invalid declarations, read-only/database-full failures,
durable reopening, unsupported valid legacy SQL, and table/view conflicts.
Run the combined native regression and recovery suite using uniquely named
synthetic fixture (no customer database):

```sh
cd example
flutter test integration_test/database_integration_test.dart -d <device-id>
```


The combined suite runs 69 database scenarios followed by recovery
and reopen checks. It selects the package's actual backend and storage path,
including FFI/Application Support on Android and native SQLite/Library on iOS.
To reuse a single compiled iOS simulator test binary across device configurations:

```sh
flutter build ios --simulator --debug -t integration_test/database_integration_test.dart
flutter drive --no-pub --use-application-binary=build/ios/iphonesimulator/Runner.app \
  --driver=test_driver/database_driver.dart -d <simulator-id>
```

Tests exercise legacy defaults, missing columns, fresh installs, actual
initDatabase true/false behavior, idempotency, quoted defaults, NULL preservation,
rollback and retry, lossy conversion rejection, constraints, custom indexes and
triggers, views, foreign-key cascades, generated columns, table options,
AUTOINCREMENT, rowids, and concurrent handles. Run `flutter test` and
`flutter analyze`; full analysis currently also reports legacy query/example
lint findings outside the updater.

The [field-type/default matrix](FIELD_TYPE_MATRIX.md) adds 345 shared host/native
cases covering all type pairs, default addition/change/removal, numeric and text
boundaries, rollback, recovery and reopening.

The [foreign-key matrix](FOREIGN_KEY_MATRIX.md) covers 70 populated relationship
changes with enforcement enabled and disabled, including post-upgrade writes.

See [conversion validation](COLUMN_CONVERSION_VALIDATION.md) for populated,
batched conversion, binary-safe copying and related native checks.

## Branch transition

Historically Tunaipos pinned the production branch. Main contained an older API.
This change incorporates production's existing API into main, then fixes its
updater. Consumers must pin the tested main commit, not a moving branch.
The production branch itself is not advanced by this change.

See [SQLite compatibility](SQLITE_COMPATIBILITY.md) for historical-engine tests,
column-inspection fallbacks and mixed-type foreign-key limitations.
