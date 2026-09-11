## Query and write correctness

- Bind built-in filter and write values; preserve NULL and scalar types.
- Reject invalid modeled keys and conversion failures, preserving transaction rollback.
- Correct literal search, empty/integer sums, join grouping and pagination.
- Add the runnable 68-scenario Flutter Test Lab and legacy-write fallback tests.
- Document compatibility and explicit conflict policies in `docs/QUERY_AND_WRITE_SAFETY.md`.

## Unreleased

- Recover incompatible full-registry updates by clearing only affected tables
  and their old/target foreign-key dependent closure before considering a full
  database reset. Preserve unrelated rows and atomically roll back failed repair.
- Add `DBInitializationResult.tablesRebuilt` and `initializer.rebuiltTables`.
  Callers with exhaustive result switches must handle the new enum case.
- Permit primary-key changes on empty tables without data-loss recovery.

- Bring the existing production API into main so consumers can pin main commits.
- Make updateDB automatically reconcile defaults, nullability and value-preserving
  type changes, with atomic rollback and no per-app migration scripts.
- Preserve unknown schema, constraints, rows, indexes, triggers, views, generated
  columns, rowids, table options and AUTOINCREMENT state during table rebuilds.
- Propagate schema/trigger failures; synchronize triggers after tables and retain
  unknown triggers. updateDB false now skips trigger reconciliation as well.
- Honor escaped, nonempty string defaults instead of always generating ''.
- Document automatic update behavior, concurrency and unsupported transformations.

## 0.0.1

* TODO: Describe initial release.

- Add correlated initialization lifecycle, engine, recovery and failure diagnostics; protect every initialization log call from sink failures.
