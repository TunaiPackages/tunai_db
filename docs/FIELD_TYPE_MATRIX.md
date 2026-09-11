# Field-type and default regression matrix

The matrix covers every current `DBFieldType`: `integer`, `real`, and `text`.
Tests are generated from `DBFieldType.values`; adding an enum member requires
adding its value samples and default expectations.

## 345 independent database cases

| Group | Cases | Coverage |
| --- | ---: | --- |
| Empty transitions | 36 | All nine type pairs, nullable/required targets, with/without defaults |
| Repeated type cycles | 6 | Every ordering of the three types, returning to the original type |
| Populated transitions | 228 | All nine type pairs over 38 source-specific value samples and both target nullability settings |
| Default lifecycle | 60 | Ten default values across all three types, nullable and required |
| Invalid defaults | 15 | NaN, positive/negative infinity, list and map defaults on all types |

Each populated transition creates a real file with no default, inserts rows,
adds a default, verifies existing values (including NULL) remain unchanged, and
checks a subsequent omitted-value insert. It then changes type, default,
nullability and indexing together, verifies the result, inserts again and reopens.

For an incompatible transformation, the test first disables fallback and verifies
that the failed attempt rolls back both schema and rows. It then uses normal full
initialization and checks the explicit `rebuilt` result and empty registered tables.
A separate populated sentinel table distinguishes data preservation from a
whole-database rebuild. Compatible updates must return `ready` and retain it.

Default lifecycle cases add, replace and remove defaults. Old rows must retain
their values; new omitted-value inserts must follow the current default and
nullability. Invalid default declarations must fail and preserve the old database.

Verification includes column type, nullability, SQL default, indexes, row counts
and values, SQLite storage classes, quick_check, foreign_key_check, durable
reopening and unchanged schema_version on an unchanged reopen. Defaults include
booleans, numbers, numeric strings, empty strings, apostrophes, Unicode and a
SQL-looking string that must remain literal data.

Value samples include signed 64-bit integer limits, the double-precision integer
boundary and nearby inexact values, negative zero, subnormal and largest finite
REAL values, fractions, NULL, empty/NUL-containing/Unicode text, numeric strings
with leading zeros, whitespace and exponents, overflowing integer strings, and
nonnumeric strings stored in numeric-affinity columns.

## Interpretation

SQLite column types specify affinity. A nonnumeric string can remain TEXT in an
INTEGER/REAL column, and a fractional REAL can remain REAL in an INTEGER column.
The updater preserves these values; it does not force a cast. Numeric text that
would become a number, numbers that would become text, precision-losing numeric
changes, and existing NULLs under a new NOT NULL constraint require recovery.
Changing a default never backfills an existing NULL.

## Running

Host, with a temporary directory and real SQLite FFI databases:

```sh
flutter test test/field_type_matrix_test.dart --reporter expanded
```

Native, with the same assertions and the package's actual backend and paths:

```sh
cd example
flutter test integration_test/field_type_matrix_integration_test.dart -d macos
flutter test integration_test/field_type_matrix_integration_test.dart -d <device-id>
```

Every case uses a unique synthetic database and deletes only its own file. The
matrix is a separate native entrypoint so the ordinary interactive lab remains
focused. The host matrix runs automatically with the package's full test suite.

This is broad deterministic coverage, not every possible SQLite value, historical
OS version, concurrent writer schedule or power-loss scenario.

## Validation — 11 September 2026

- Full package suite: **421 passed**, including all 345 matrix cases.
- iOS 26.4, iPad mini (A17 Pro): **345 passed**.
- macOS 26.4.1: **345 passed**.
- Android API 36, Pixel 6a emulator: **345 passed**.
- Focused matrix analysis: **no issues**.
- Full package analysis: **92 existing findings in untouched files**.

All 345 cases passed on each of the four environments above. No production-code
changes were needed. These runs used one iOS simulator and one Android emulator;
they did not repeat the earlier complete simulator-device matrix. Native tests
exercise native SQLite on iOS/macOS and the package's SQLite FFI backend on Android.
