# TunaiDB maintenance

- `main` contains the supported API; consumers pin an exact tested commit.
- Read `docs/AUTOMATIC_SCHEMA_UPDATES.md` before changing initialization or schema
  handling. DBTable/DBField declarations drive automatic updates; ordinary
  schema changes must not require handwritten application migrations.
- Preserve existing values and unregistered tables, columns, indexes, triggers,
  and constraints. Never swallow schema mutation failures or reset a database
  as automatic recovery. Unsafe conversions must roll back.
- Keep schema reconciliation centralized in `lib/src/schema/`. Initialization
  and explicit `updateTables` must share the same behavior.
- Add focused, populated-database regression tests for persistence changes.
  Run `flutter test` and `flutter analyze`; report legacy lint findings honestly.
- Preserve unrelated work and generated Flutter/plugin churn. Commits use
  Conventional Commits and `Co-Authored-By: Codex <noreply@openai.com>` when Codex
  assists; other agents should identify themselves accurately.

- For CRUD/query changes, also run `flutter test test/lab` from `example/`.
  Keep every fixed regression enabled. Use its native integration suite for
  platform-sensitive persistence changes; see `example/TEST_LAB.md`.
