# Query and write correctness

TunaiDB binds values for built-in filters and writes. Text—including quotes,
Unicode and SQL-looking input—is data, not a fragment of SQL. This applies
to fetch/count, update/delete, joined reads and deprecated field-value reads.

Identifiers, sorter expressions, join ON expressions, `rawQuery` text and custom
filter `getQuery` implementations remain developer-owned SQL. Do not populate
them from untrusted input. Existing custom filters and subclasses retain their
`getQuery` behavior. Built-in `getQuery` compatibility output escapes literals;
normal package execution uses placeholders and arguments.

## Writes

- `insert`, `insertList` and `insertJsons` default to primary-key upserts, updating
  supplied fields without deleting and reinserting existing rows. Omitted fields
  remain unchanged on conflict. A primary-key-only conflict is a no-op.
- A modeled table needs exactly one primary key. Invalid declarations throw
  `StateError`; conversion, validation and SQLite failures reject the Future.
  Empty input lists are no-ops. Batch and transaction sizes must be positive.
- NULL stays SQL NULL. Strings and numbers retain their types; booleans normalize
  to 0/1. Blobs use `Uint8List`. Unsupported values and non-finite doubles reject
  before the corresponding write instead of being stringified. Strings containing
  NUL reject on every backend because native Darwin SQLite reads truncate them;
  use a blob for binary data. No platform silently stores truncated text.
- `insertList` remains transactional **per `transactionSize` chunk**, not per
  entire list. An error rolls back all batches in the failing chunk; earlier
  committed chunks remain. Callers must await and handle failure. Retrying
  idempotent upserts is safe when their application-level effects are idempotent.
- The pre-UPSERT fallback executes rows in order, sees repeated new keys, and
  throws on constraints rather than ignoring them. It preserves the same chunk
  boundaries as modern SQLite.
- Default `ConflictAlgorithm.replace` retains TunaiDB's historical upsert
  meaning. Explicit `ignore`, `abort`, `fail` or `rollback` uses SQLite INSERT
  semantics. Only an explicitly requested `ignore` can intentionally skip a
  conflicting row. The old modern implementation ignored this parameter.
- The historical `insertList(filters: ...)` argument is still unused. It is not
  a write-scope guard. Use explicit `update`/`delete` filters for scoped changes.

The fix does not reinterpret existing `"null"` text as NULL: a stored string may
be intentional. It changes future writes and does not add an application
migration or reset.

## Reads and filters

- Empty IN lists match no rows. Empty composite/grouped filters reject; an empty
  top-level filter list keeps the established unfiltered-operation behavior.
- Composite filters are parenthesized. OR groups cannot escape a surrounding
  AND condition; standalone joined-table filters also retain group boundaries.
- `DBSearchFilter` treats `%`, `_` and backslash literally. `caseSensitive: true`
  uses literal substring matching rather than SQLite's normally insensitive
  LIKE. Default case folding follows SQLite LOWER (ASCII by default), not full
  Unicode linguistic matching. Existing whitespace normalization is retained.
- `DBFilterType.like` still accepts caller-supplied LIKE patterns; use
  `DBSearchFilter` for literal user searches.
- Joined SQL orders clauses as WHERE, ORDER BY, LIMIT, OFFSET. An offset without
  a limit supplies SQLite's `LIMIT -1`. An empty optional left-join list reads
  the base table without generating a trailing comma.
- `getSum` returns a double for both INTEGER and REAL aggregates, and 0.0 when
  the aggregate is NULL (no rows or only NULL values).

## Verification

Run `flutter test` from the package root and `flutter test test/lab` from
`example/`. Run `flutter test integration_test/lab_integration_test.dart -d macos`
for the complete native-plugin suite. No known-issue exclusions are required.
The [Test Lab](../example/TEST_LAB.md) contains the original 11 regressions plus
checks for mutation scope, rollback, NULL/scalar preservation, joins, conflict
policies and repeated keys. Package tests additionally exercise the pre-UPSERT
fallback on a real SQLite handle.
