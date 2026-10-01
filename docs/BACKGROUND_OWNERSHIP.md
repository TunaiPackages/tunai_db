# Optional background database ownership

`TunaiDBOwnership` coordinates engines in one Flutter process. Claim foreground
before opening a foreground database and retain it for that process, including
minimized/logout states. `tryBackground()` returns null while foreground or
another worker owns access. Give an admitted worker's `lease.factory` to
`TunaiDBInitializer.initDatabase(factory: ...)` and close the initializer and
lease in `finally`. Never fall back to another factory after revocation.

The independent coordinator isolate performs background FFI SQLite calls itself.
It tracks handles, rejects further requests on takeover, closes native handles,
and only then acknowledges foreground. Closure rolls back unfinished
transactions. A root-isolate exit listener keyed by stable isolate identity also cleans up after Flutter engine
cancellation, which need not run Dart finally blocks. Normal explicit release
allows another background worker until foreground has claimed ownership.

No TTL or cancellation notification is treated as proof of native cleanup.
Cleanup failure retains ownership and fails the foreground claim. Foreground
uses its existing native/FFI backend; this optional API does not change default
initializer behavior. A synchronous SQLite statement can finish before takeover
is handled. This API does not coordinate separate OS processes or arbitrary
connections opened outside its factory.

The adapter uses exact sqflite_common 2.5.11 / sqflite_common_ffi 2.4.2+1 transport
internals. Revalidate lifecycle semantics before upgrading either dependency.

Validation: the existing 518 package tests and 5 ownership regression tests pass.
The ownership tests check process-lifetime priority, normal release/commits,
initial schema interruption, rollback, queued/stale request rejection, and
subsequent foreground writes. Android WorkManager engine tests additionally
verify cancellation without Dart finally and a new background claim after
cleanup; committed rows and integrity survive process restart. App integration
keeps its own platform/runtime evidence and limitations.

Repeated/rejected claims in one isolate retain its exit registration. Lease
release only disposes lease-local notifications; it cannot remove cleanup for
another accepted lease. A regression kills an isolate after a rejected duplicate
claim and verifies a new background lease, rollback and integrity without
foreground takeover.
