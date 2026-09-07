## Unreleased

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
