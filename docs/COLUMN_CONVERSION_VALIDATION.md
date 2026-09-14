# Best-effort ordinary-column migration

When an ordinary column changes type during full initialization, each stored value
is explicitly converted. Unconvertible values use a valid declared default, or
NULL if there is no default and the target is nullable. Other columns, row
identities and unrelated registered tables are preserved. Without a usable
fallback, the transaction rolls back and normal last-resort recovery applies.
An unusable declared default is an invalid-model error and does not reset data.

Primary keys and existing/target foreign-key columns remain strict. Default-only
updates do not rewrite old values. Selected-table repairs remain strict.

## Conversion rules

- INTEGER: whole signed-64-bit numbers and valid decimal/scientific numeric strings.
  Fractions, overflow, hexadecimal text and numeric prefixes followed by junk are
  unconvertible; they are never silently truncated, wrapped or treated as zero.
- REAL: finite numeric values and decimal strings; whole-integer precision loss,
  overflow and nonzero underflow use fallback.
- TEXT: preserve existing strings and stringify finite numbers.
- NULL and unsupported values: use the target default or nullable NULL.

## Copy and verification

Rows are copied in groups of up to 256 under one transaction, limited by the
older 999-parameter budget. Each group uses one INSERT statement. Unchanged values stay
inside SQLite rather than being decoded and re-encoded through the platform
adapter. Changed text is read and written as bytes with explicit SQLite TEXT casts,
avoiding the native adapter's embedded-NUL truncation. Text primary-key cursors are also transported as bytes. The updater
checks retained values, row counts, identity and database/relationship integrity.
Committed logs report conversion/default/NULL counts without row contents.

The new storage regressions cover mixed conversions over 600 rows, two changed
columns together, untouched NULL/text/blob data, default and NULL fallback,
rollback after earlier copy batches, failed initialization without a fallback,
unusable defaults, extreme numeric exponents, embedded NULs, and text identities
on a legacy WITHOUT ROWID table.

The existing 345-case type/default matrix now expects the authorized ordinary
column substitutions. The 70-case populated foreign-key matrix remains strict.

## Running related tests

```sh
flutter test
cd example
flutter test integration_test/column_conversion_integration_test.dart -d <device-id>
```

The combined native entrypoint runs nine storage regressions plus the type
and foreign-key matrices: 424 cases. Each uses its own disposable database; no
customer data or consuming application is involved.

## Validation (2026-09-11)

- Package suite: 498 passed.
- Existing example lab suite: 74 passed.
- iOS simulator (iPad mini A17 Pro, iOS 26.4): 422 passed.
- macOS native: 422 passed.
- Android emulator (Pixel 6a): 422 passed.
- Focused analysis of changed schema/test code: no issues.
- Full package analysis: 92 pre-existing findings in untouched code.

The Apple runs exposed embedded-NUL truncation on both native TEXT reads and
String bindings. The final regression seeds real embedded NULs inside SQLite and
compares hexadecimal bytes after migration, so adapter truncation cannot make the
assertion pass accidentally. The unchanged-column copy stays inside SQLite.

## Simultaneous column-change regressions

Two additional populated cases exercise 600 rows each:

- All six directed INTEGER/TEXT/REAL conversions in one update, with different
  defaults and NULL fallbacks per column. The same update tightens nullability,
  reverses field declaration order, adds and removes columns, switches indexes,
  and changes a default on an otherwise unchanged column. Assertions compare
  every retained row, actual column types/nullability/indexes, old versus new-row
  defaults, unrelated table contents, and close/reopen behavior.
- A failure in the second changed column on row 599 after earlier batches copied.
  The first changed column has already used default substitutions. The test
  verifies exact data/schema rollback and no successful-migration log, then
  supplies a fallback and retries successfully without a database reset.

These supplement the existing cases that change two columns together.

Follow-up validation (2026-09-11): package suite **500 passed**; the two new
multi-column cases passed on each of the iOS simulator, Android emulator and
macOS native runtime using `--plain-name multi-column`. The prior 422-case native
run remains recorded above; this follow-up ran the two additions, not the whole
424-case native entrypoint. Full analysis remains at 92 existing findings, with
none in the changed test file. No production code changed in this follow-up.
