# TunaiDB maintenance

- `main` contains the supported API; consumers pin an exact tested commit.
- Read `docs/AUTOMATIC_SCHEMA_UPDATES.md` before changing initialization or schema
  handling. DBTable/DBField declarations drive automatic updates; ordinary
  schema changes must not require handwritten application migrations.
- Full initialization must match the complete registered model: remove undeclared
  tables, columns, indexes, triggers and views, preserving retained values.
  Type-changed ordinary columns use explicit conversion, then a valid declared
  default or nullable NULL; preserve other columns and all retained rows. Key
  columns remain strict. Partial repairs preserve objects outside their selection;
  unsupported conversions must roll back. Follow the goal and recovery contract in
  `docs/AUTOMATIC_SCHEMA_UPDATES.md`: a logged, explicitly reported reset of affected tables plus FK dependents
  precedes whole-database recovery, which is the final resort for irreconcilable schema incompatibility,
  never routine recovery or a catch-all for storage errors. Only full
  initialization with the complete registry may recover this way;
  selected-table repairs must never erase a database. Test both preservation
  and recovery, including failed replacement rollback.
- Keep storage/schema recovery independent of consuming-app business rules and
  synchronization. The app owns repopulating empty data. Treat each last-resort
  rebuild as an exceptional event to investigate and improve the updater.
- Keep schema reconciliation centralized in `lib/src/schema/`. Initialization
  and explicit `updateTables` must share the same behavior.
- For SQLite schema/introspection changes, consult `docs/SQLITE_COMPATIBILITY.md`
  and run the historical-engine matrix alongside current-engine tests.
- Add focused, populated-database regression tests for persistence changes.
  Run `flutter test` and `flutter analyze`; report legacy lint findings honestly.
- Preserve unrelated work and generated Flutter/plugin churn. Commits use
  Conventional Commits and `Co-Authored-By: Codex <noreply@openai.com>` when Codex
  assists; other agents should identify themselves accurately.

- For CRUD/query changes, also run `flutter test test/lab` from `example/`.
  Keep every fixed regression enabled. Use its native integration suite for
  platform-sensitive persistence changes; see `example/TEST_LAB.md`.
