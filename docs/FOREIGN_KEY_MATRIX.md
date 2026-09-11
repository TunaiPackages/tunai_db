# Populated foreign-key schema changes

The shared host/native suite contains **35 scenarios, each tested with foreign-key
enforcement OFF and ON: 70 cases**. Every case starts with persisted rows, not an
empty database. A populated sentinel table detects unintended whole-database resets.

## Scenarios

- Add a foreign key to existing valid, orphaned or NULL values.
- Retarget a foreign key to another table whose keys do or do not match existing rows.
- Remove a foreign key while retaining its column.
- Remove the constraint and its parent table together; remove the FK column; drop
  the child table while keeping parent rows.
- Reject dropping a still-referenced parent, a missing referenced column, or a
  reference to a non-primary/nonunique column without losing the original data.
- Add a foreign-key column with NULL, a valid default, an orphan default, or a
  required field without a default.
- Tighten FK nullability over valid rows or existing NULLs; change an FK default
  without rewriting existing values.
- Replace legacy ON DELETE CASCADE with the model's NO ACTION behavior without
  firing cascades or deleting children during schema reconstruction.
- Change the referenced primary-key column and verify explicit last-resort recovery.
- Add self-references with valid or orphaned rows.
- Add a cyclic relationship with the tables registered in reverse order.
- Add references in multiple child tables, with all valid rows or an orphan in
  one child table; verify the whole migration is atomic.

- All nine INTEGER/REAL/TEXT parent-key and child-key target-type combinations,
  starting from populated integer relationships.
- TEXT-parent/REAL-child comparison: a parent key `"9001"` rejects child `9001.0`;
  the matching parent text `"9001.0"` accepts it. FK comparison follows the parent
  column's affinity. The test explicitly checks both cases.

## Assertions

Compatible migrations must return `ready`, preserve expected parent/child values
and retain the sentinel. Incompatible populated schemas first run without recovery:
that attempt must fail and restore the complete schema and all rows. Recovery is
then allowed and must report `rebuilt`, leaving all registered tables empty.
Invalid declarations must throw, invalidate initialization and retain the original
database, rather than discard it.

The tests inspect foreign_key_list, quick_check and foreign_key_check, compare
persisted rows, restore the connection's FK enforcement setting, and reopen the
file to verify durable schema/data. After migration they exercise actual writes:
valid parent/child inserts succeed, orphan inserts fail with enforcement enabled,
and referenced parent deletion/key mutation is rejected. Removing a foreign key
must allow the previously constrained value. Write probes roll back afterward.

## Runtime enforcement boundary

Full schema initialization validates foreign-key relationships even when
`PRAGMA foreign_keys` is OFF. The initializer does not explicitly enable runtime
FK enforcement on each new connection. This suite does not change that policy:
OFF cases exercise public full initialization; ON cases additionally exercise
setting restoration in the shared reconciler. Write-enforcement probes explicitly
enable FK enforcement after reopening. Changing the runtime policy would be a
separate behavior change for application writes.

## Running

```sh
flutter test test/foreign_key_matrix_test.dart --reporter expanded
cd example
flutter test integration_test/foreign_key_matrix_integration_test.dart -d <device-id>
```

The same assertions use temporary files with host SQLite FFI, and actual package
backends/storage paths on native devices. Every fixture is uniquely named and only
its own database is deleted. No consuming app or customer data is used.

## Validation — 11 September 2026

- Host SQLite FFI: **70 passed**.
- iOS 26.4 / iPad mini (A17 Pro): **70 passed**.
- macOS 26.4.1: **70 passed**.
- Android API 36 / Pixel 6a emulator: **70 passed**.
- Full package test suite: **491 passed**.
- Changed test files have no analysis findings; full package analysis retains
  **92 existing findings in untouched files**.

The initial type-pair probe incorrectly assumed TEXT `"9001"` equalled REAL
`9001.0` under foreign-key comparison. The corrected regression now verifies the
rejection and a matching key on every platform. No production-code change was
needed. These runs cover one iOS simulator, one Android emulator and native macOS,
not the earlier exhaustive simulator inventory or physical devices.
