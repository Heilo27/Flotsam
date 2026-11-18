# ADR-0002: SQLite binding is GRDB

Status: Accepted (2026-11-16). Load-bearing: flagged to Friday.

## Context
FR-007-02 fixes the behaviour (one SQLite database, WAL, `synchronous=NORMAL`, `foreign_keys=ON`, `secure_delete=ON`, `busy_timeout` 5 s, exactly one serial writer, any number of concurrent readers, no main-thread reads) and delegates the binding to this ADR. FR-007-17 requires `PRAGMA user_version` migrations with a pre-migration file copy; FR-007-13 requires `quick_check` and move-aside recovery; FR-007-18 may need FTS5.

## Decision
Use **GRDB.swift** (MIT) with a `DatabasePool` on the system SQLite (`import GRDB`, no SQLCipher, no custom SQLite build). Pin the exact version in `Package.swift` and commit `Package.resolved`. Only the `Storage` target imports it.

- `DatabasePool` gives the FR-007-02 topology by construction: one serialised writer, a pool of WAL readers, async APIs that never run on the caller's thread. A sync read API is not exposed from Storage, which makes "no main-thread reads" a compile-visible fact.
- Migrations run through our own ~40-line runner over GRDB's write transactions, because FR-007-17 makes `PRAGMA user_version` the version and requires the pre-migration copy. GRDB's `DatabaseMigrator` (its own bookkeeping table) is not used; `meta.schemaVersion` mirrors `user_version`.
- GRDB errors are caught inside Storage and mapped to `STO-DB-00x` / `STO-IO-00x` codes; no GRDB type appears in a Storage signature (FR-000-02).

## Alternatives rejected
- **SQLite3 C API directly.** No dependency, but roughly 500 to 800 lines of binding code (statement lifetime, blob and text bridging, reader-pool, busy handling, transaction wrapping) that we would write, test and own, with memory-safety risk in the module that holds the user's data. Writing it is the "not invented here" cost with no truth served.
- **SwiftData / Core Data.** Cannot express `secure_delete`, `incremental_vacuum`, `quick_check`, pre-migration file copy, `wal_checkpoint(TRUNCATE)` (FR-007-11, -13, -17) without reaching beneath the framework; no FTS5; the SQLite file format is framework-owned, which complicates the move-aside recovery; its reader and writer concurrency is the framework's, not ours to tune. It would also put a framework model type across the Storage API, violating FR-000-02.
- **SQLite.swift / other wrappers.** No pool abstraction, so the reader/writer split would be ours to build.

## Consequences
- One runtime dependency (ADR-0010). GRDB is MIT, has no networking code, and is actively maintained (latest tag seen 2026-11-16: v7.12.0).
- Available SQLite features follow the OS: the system library on the minimum macOS (26) is the one the development machine runs. This matters for FTS5 trigram only (ADR-0003); everything else in FR-007 uses long-standing SQLite features (WAL, `secure_delete`, `incremental_vacuum`, `quick_check`, `user_version`); the skeleton test confirms them on the build machine and S-1 repeats the check on the build machine only (macOS 14 and 15 are unsupported).
- The skeleton test `StorageOpenTests` asserts the pragmas (WAL, foreign keys, secure_delete, user_version) on a real file, so a GRDB or SQLite change that breaks FR-007-02 fails a test.

## Reversibility
Medium. The binding is hidden behind Storage's API, so replacing GRDB touches only that target; the on-disk database is plain SQLite and survives the swap.
