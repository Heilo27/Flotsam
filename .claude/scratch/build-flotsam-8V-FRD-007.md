# Flotsam FRD-007 8V test validation (Data, independent auditor)

Head 637aeca, branch frd007. 111 tests green at start (`swift test --package-path Packages/FlotsamCore --filter FlotsamStorageTests`, 62 s cold). 49 mutants planted by me, one at a time, each: apply, full filter run, `git checkout -- <file>`, `git status --porcelain` empty (checked by script after every mutant; clean on all 49). Worf's 9 already-killed mutants (DiskGuard hard and image `<=`, bump `max` dropped, in-tx contentKey re-check off, text ceiling `>=`, d7 7->8 days, trigger NOCASE dropped, eviction 90->100%, stampLastSweep dropped) were skipped as instructed and are not in my counts.

## Verdict: FAIL
Survivors 21 of 49 (gate requires 0, no waiver). Killed 28. Raw data: .claude/oracle/frd-007-mutation.json. Root causes, in order of weight:
1. Both schedulers have zero tests (`git grep "RetentionScheduler|ReconcileScheduler" -- Tests` is empty): 8 survivors.
2. The 24 h grace is tested at the primitive (`deleteWhileEligible` called directly) but not at the call sites or at the exact boundary.
3. Clear History range boundaries and the scrub step are unobserved.
4. Four single-site gaps: dedupe newest-row choice, blob filename pattern, pre-migration copy recognition and checkpoint, thumbnail full-decode check.

## Survivors
| id | file:line | mutant | OC it should hit | root cause | fix (tests only unless noted) |
|----|-----------|--------|------------------|-----------|-------------------------------|
| M04 | Retention/ImageBudgetEnforcement.swift:63 | in-tx guard becomes `notExemptSQL` only (grace dropped) | OC-7071, OC-7059 | race tests call `deleteWhileEligible(guard: Exemption.autoDeletableGuard)` directly, so the budget call site's own guard is never exercised | budget run where an image is un-exempted between selection and delete (needs a hook between select and delete, or assert via a guard-capturing seam) |
| M05 | Retention/Exemption.swift:17 | `exemptReleasedAt < ?` to `<=` | OC-7071 | no test at exactly 24 h (race_graceBoundary uses 1 h and 25 h) | add released-exactly-24h row: kept at `<`, deleted one ms later |
| M10 | Retention/Exemption.swift:77 | `wasExempt` arg forced true | OC-7072, OC-7074 | no test edits an item that is already released or never exempt; only exempt to non-exempt transitions are checked | edit a never-exempt item (stamp stays null) and an already-released item (stamp not extended) |
| M13 | Retention/ClearHistory.swift:47 | `lastCopiedAt >= ?` to `>` | OC-7091 | no item at exactly now - lookback | item at exactly 1 h and exactly 24 h ago |
| M14 | Retention/ClearHistory.swift:46 | `lastCopiedAt <= ?` to `<` | OC-7091 | no item at exactly the clear start instant | item at exactly now |
| M16 | Retention/ClearHistory.swift:159 (scrubDatabaseFile, `incremental_vacuum` replaced by `SELECT 1`) | pages not returned to OS | none exists; FR-007-11 states it, OC-7095 only searches bytes and `secure_delete=1` already zeroes them | add OC (db file size shrinks after Clear History) and a test asserting `PRAGMA freelist_count == 0` or file size drop |
| M18 | Retention/ClearHistory.swift:136 | in-tx guard `1 = 1` | OC-7089, FR-007-15 | same as M04: `race_itemsExemptedAfterPreviewSurviveClearHistory` exempts before the run, so re-selection catches it, not the guard | race seam as M04 |
| M19 | Ingest/IngestActor.swift:111 | dedupe lookup `ORDER BY lastCopiedAt DESC` to `ASC` | OC-7028, OC-7015 | no test with two rows sharing a contentKey (OC-7015 permits edited duplicates) to show the newest is bumped | insert two same-key rows, copy again, assert the newer one's copyCount rises |
| M21 | Blobs/BlobStore.swift:31 | `Int(parts[1]) != nil` to true | OC-7113, OC-7114 | reconcile would delete a `<uuid>.<non-int>` file in a shard; oc7114 only uses foreign names that fail the UUID check | plant `<uuid>.bak` in a shard dir, assert it survives reconcile |
| M27 | Folder/DataFolder.swift:40 (isPreMigrationCopyFile) | `!digits.isEmpty` dropped, so `flotsam-v.sqlite` matches | OC-7137 | oc7137 foreign set lacks the empty-digits name | add `flotsam-v.sqlite` and `flotsam-v.sqlite-wal` to the foreign set |
| M30 | Database/FlotsamDatabase.swift:182 (preMigrationCopy) | wal_checkpoint(TRUNCATE) before copy removed | OC-7134 | fixture has no un-checkpointed WAL, so the copy equals H0 either way | fixture with committed rows still in the WAL; copy hash must include them |
| M32 | Images/ImagePipeline.swift:99 (isCompleteJPEG) | full-decode check dropped (EOI check kept) | OC-7044 | truncated fixture is killed by the EOI check; random-bytes case has no FF D9 either; no JPEG with intact markers and corrupt entropy data | add a damaged JPEG that keeps SOI and EOI but fails decode |
| M39 | Images/ImagePipeline.swift:25 (`storedJPEGQuality` 0.85 to 0.3) | known gap, confirmed | OC-7048 | tests assert type and dimensions, never quality | encode the same fixture at 0.85 in the test and compare bytes, or compare against a size band |
| M42 | Retention/RetentionScheduler.swift:9 (launchDelay 30 s to 60 s) | none | OC-7075 | scheduler untested | inject clock, assert first sweep at 30 s |
| M43 | Retention/RetentionScheduler.swift:10 (interval 3600 s to 7200 s) | none | OC-7075 | same | assert second sweep at +1 h |
| M44 | Retention/RetentionScheduler.swift:44 (`stop()` no cancel) | none | OC-7075 | same | start, stop, advance clock, assert no sweep |
| M45 | Retention/RetentionScheduler.swift:51 (`sweepNow` overlap guard dropped) | none | OC-7075 | same | two concurrent `sweepNow` calls, assert one sweep |
| M46 | Reliability/ReconcileScheduler.swift:9 (launchDelay 15 s to 30 s) | none | OC-7113 | scheduler untested | as M42 |
| M47 | Reliability/ReconcileScheduler.swift:10 (interval 7 d to 1 d) | none | OC-7113 | same; OC-7113's "orphan deleted after >7 days without relaunch" is untested | assert second pass at +7 d, not +1 d |
| M48 | Reliability/ReconcileScheduler.swift:36 (`stop()` no cancel) | none | OC-7113 | same | as M44 |
| M49 | Reliability/ReconcileScheduler.swift:43 (`reconcileNow` overlap guard dropped) | none | OC-7113 | same | as M45 |

Not equivalent: M16 checked against FlotsamDatabase.swift:144-151 (auto_vacuum=INCREMENTAL is set so the vacuum has real effect). Both schedulers call `clock.sleep(for:)` (RetentionScheduler.swift:32,35; ReconcileScheduler.swift:24,27) and expose `sweepNow()`/`reconcileNow()`, so the overlap guards are directly reachable; whether the clock is injectable from a test I did not verify.

## Killed (28)
M01-M03, M06-M09, M11, M12, M15, M17, M20, M22-M26, M28, M29, M31, M33-M38, M40, M41 (ids and killing tests in .claude/oracle/frd-007-mutation.json). Boundaries killed: grace halved and grace dropped from sweep, preview and budget candidate selection (oc7071, oc7072, graceProtectsOldestImageFromBudget); pinned, trigger and hotkey each dropped from the exemption (OC-7079, oc7059, oc7067, oc7057, oc7073); lastHour using the 24 h lookback and allTime gaining a lookback (oc7091, oc7089, oc7090); wal_checkpoint PASSIVE (oc7095); blob prefix(3), shard-name filter dropped, `parts.count >= 2`, orphan grace 1 min, `?? true` on a missing mtime, stat-failure flag (OC-7020, oc7114, oc7024, statFailure tests); `-shm` suffix and prune-any-file (oc7137); thumbnail EOI check and atomic replace of an existing file (OC-7044); byteSize including plain text (OC-7018); Efficient opaque to JPEG, alpha to PNG, TIFF to PNG, Efficient ceiling (OC-7052, OC-7051, OC-7042, OC-7048); schema version and meta mirror (OC-7019, existingDatabaseIsCopiedBeforePendingMigration).

## Banned-pattern findings (grep sweep over all 12 test files for count-only, `!isEmpty`, `!= nil`, positional; bodies read for each hit)
No B-finding blocks the gate by itself, but B1 explains M10.
- B3 RetentionSweepDestructiveTests.swift:145 `#expect(try s.exemptReleasedAt(1) != nil)`: existence check; OC-7072 says exemptReleasedAt = U. Rewrite: `== s.clock.millis` at the unpin instant.
- B3 RetentionSweepDestructiveTests.swift:292 `#expect(outcome.evictedCount >= 1)`: lower bound only. Rewrite: exact count from the 450 MiB target arithmetic (OC-7055).
- B3 IngestPipelineTests.swift:111 `#expect(imageBlobBytes > 0)`: sits beside an exact `byteSize == imageBlobBytes`, so the sum could be wrong in lockstep; benign. Rewrite: compare to the known stored size.
- B3 ThumbnailTests.swift:53 `#expect(served != nil)`: backed by following type/dimension asserts, benign. Rewrite: `try #require`.
- B5 RetentionSweepDestructiveTests.swift:324 positional `files[0..2]`: reads file contents A/B/C, order is the test's own; acceptable.
- Absence checks (`blobFiles().isEmpty`, `deletedBatches.isEmpty`, `none.isEmpty`) are intended assertions, not B-findings. ReconcileAndMigrationDestructiveTests.swift:215 `!before.isEmpty` is a precondition; acceptable.
- B1, B2, B4, B6, B7: none found.
- Tag hygiene: 87 distinct OC-7xxx ids appear in test text; several tests are named by behaviour only (StorageOpenTests, race_*, statFailure*). Add ids so mapping is mechanical.

## Contract mapping (152 assertions, 65 with no OC tag in the tests)
87 ids carry a tag. Of the 65 without, these are covered by behaviour and only need a tag: 7008 and 7009 (StorageOpenTests.opensRealFileWithRequiredPragmas: journal_mode, foreign_keys, secure_delete), 7010, 7150 (same ingest path as OC-7027/7028), 7001 (0700 folder only; 0600 on files and the exact listing are unchecked, so partial).

GAP-unit (unit-testable in FlotsamCore, to Worf):
- 7001 (partial: file modes 0600 and folder contents), 7002 (tmp/ emptied at open; DataFolder.swift:57 has the code, no test), 7003 (thumbs/ excluded from backup, DataFolder.swift:55)
- 7022 (blob never modified in place), 7023 (orphan after crash between rename and commit, then reconcile), 7025 (write failure leaves no new blob), 7031 (storage half: count N and blob count B0 after forced write failure), 7033 (retry after failure gives one item, copyCount 1), 7121 (SQLITE_FULL: no partial rows, STO-DB-001), 7035 (empty store totals)
- 7069 (age measured from lastCopiedAt, re-copy renews), 7070 (paste/open/edit do not renew), 7116 (migrate precedes quick_check; needs the log sink FRD-000 added), 7128 (deleting a bundle leaves F1..F3 untouched; oc7087 and oc7096 cover files items only)
- 7139, 7141, 7142, 7143, 7144, 7145, 7146, 7147, 7148: search token semantics, paging, sidebar counts, read failure and empty state, new id after retention delete. `Search/SearchIndex.swift` and `Query/LibraryQueries.swift` have no tests in FlotsamStorageTests and none elsewhere (`git grep` over Tests finds no reference to either).
- 7075 and 7113 (scheduler halves): see M42-M49.

GAP-journey / blocked (needs running app, UI, Instruments, Release build, other FRD layer):
- 7004, 7005, 7006, 7007, 7032, 7034, 7151, 7152 (relaunch, fs_usage, alert UI, Notice, Settings and Finder)
- 7011, 7047, 7098, 7115, 7130, 7131, 7132, 7133, 7140 (hang, memory and timing on 10,000-item Release libraries)
- 7041, 7065, 7085, 7088, 7108, 7109 (settings layout and popup contents)
- 7062, 7063, 7080, 7081 (confirmation alerts; the preview and apply halves are covered in RetentionPreviewTests and the sweep tests)
- 7102, 7103, 7104, 7105, 7106, 7107 (capture modes and pasteboard: Capture layer, not Storage)
- 7118 (Notice throttle is above Storage; the storage half is OC-7117, tested), 7126 (Shelf/Library visibility; cascade half is oc7122), 7127 (LIB-IO-001 HUD), 7149 (no network)

Known gaps carried from the brief: (1) the Notice text for STO-LIM-001/CAP-IO-001 is not in the package, so the text half of OC-7031/7057/7058 cannot be tested here; (2) JPEG quality 0.85 is untested, confirmed by M39. Thumbnail quality 0.8 is unmutated.

## Confidence
High on the 49 mutation results: each ran the full 111-test filter, each reverted, git status clean after each, and every survivor ran to completion (0 failures, not a compile error). Medium on the B audit (grep plus bodies of every hit, not every test read). Medium on the gap split: classified from contract text and test names, not by running probes. Not mutated: FlotsamDatabase open pragmas, SearchIndex, LibraryQueries (no tests exist to kill anything), DiskGuard beyond Worf's two, thumbnail quality.

## Required to flip to PASS
1. Scheduler tests (kills M42-M49): inject a test clock if the existing `clock` is not already reachable (production seam, goes to O'Brien), then cadence, cancellation and overlap tests.
2. Grace: boundary at exactly 24 h (M05), edit-of-never-exempt and already-released items with exact `exemptReleasedAt` values (M10, B1), call-site guard race for budget and Clear History (M04, M18; needs a seam between select and delete).
3. Clear History: exact lookback and start-instant boundaries (M13, M14); file-size or freelist assertion plus a new OC for FR-007-11 (M16).
4. Single-site: two same-key rows (M19), `<uuid>.<non-int>` in a shard (M21), `flotsam-v.sqlite` foreign name (M27), WAL-resident fixture for the pre-migration copy (M30), JPEG with valid markers and bad entropy (M32), JPEG quality 0.85 assertion (M39).
5. Worf: the GAP-unit ids above; journey ids to the journey phase.
