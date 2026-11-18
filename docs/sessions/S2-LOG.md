# S2 log

Session 2 (second Mac) reports here, newest last. Format and rules: `docs/PARALLEL-SESSIONS.md`.

Machine: macOS 26.7 (25G227), Xcode 26.3, Apple Swift 6.2.4 (swiftlang-6.2.4.1.4), 10 cores, 64 GB.

---

## 2026-11-17: A1 + A2 on `main` @ 3878487

**Commands** (clean clone, detached at 3878487):
- `bin/bootstrap.sh`: OK (GRDB 7.12.0 resolved).
- `bin/check-architecture.sh`: **pass**.
- `bin/build.sh`: **BUILD SUCCEEDED**.
- `swift test --package-path Packages/FlotsamCore` (no scratch path): **does not compile** (D1). With D1 patched locally (not committed): parallel run 515 tests in 78 suites, **failed**, 186 issues (9 known); `--no-parallel` run 515 tests, **36 tests failed**, 152 issues (9 known).

**A2 launch smoke** (Debug app from `bin/build.sh`):
- Launched; process alive at 8 s, 0.0 % CPU, RSS 78.6 MB (one sample, not an A4 measurement).
- Menu bar item present (System Events lists one menu-bar-2 item, `Flotsam`).
- `quit app "Flotsam"` exited cleanly. No `~/Library/Logs/DiagnosticReports/Flotsam*`.
- Copy checks (text, URL, image, file, concealed type) not run: FRD-001 is not on `main` yet.

### Defects

**D1 — Test target fails to compile on Swift 6.2.4.**
`Packages/FlotsamCore/Tests/FlotsamStorageTests/StorageEdgeTests.swift:218`
```
(0..<(bytes.count - 1)).first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA } ?? 0
error: the compiler is unable to type-check this expression in reasonable time
```
Repro: `swift test --package-path Packages/FlotsamCore` with Xcode 26.3 / Swift 6.2.4. The whole `swift test` run aborts (`error: fatalError`), so no tests run.
An explicitly typed closure parameter (`{ (i: Int) -> Bool in bytes[i] == 0xFF && bytes[i + 1] == 0xDA }`) compiles. I applied that only in the throwaway clone to get the counts above. It is not committed; the fix belongs to the test's owner.
If S1 is on a newer toolchain, this is a toolchain-floor question: which Swift does `swift test` have to pass on?

**D2 — String catalogue is not compiled under `swift test`, so every `FlotsamStrings` lookup returns nil (36 tests).**
Under SwiftPM CLI 6.2.4, `.process("Resources")` copies `Localizable.xcstrings` raw into `.build/arm64-apple-macosx/debug/FlotsamCore_FlotsamBase.bundle/` with no `en.lproj/Localizable.strings`. `Bundle.module.localizedString(forKey:value:table:)` cannot read a raw `.xcstrings`; I confirmed this with a standalone `Bundle(path:)` lookup of `error.SSP-IO-001`, which returned the fallback. `FlotsamStrings.text(forKey:)` (`Sources/FlotsamBase/Strings/FlotsamStrings.swift:7`) therefore returns nil, and `message(for:)` returns `""`, because the fallback text is missing too.
The app is **not** affected: `xcodebuild` compiles the catalogue to `FlotsamCore_FlotsamBase.bundle/Contents/Resources/en.lproj/Localizable.strings` in `Flotsam.app`.
Failing tests (all one cause): OC-0012, OC-0015 (x2), OC-0019 (x2), OC-0024, OC-0026, OC-0027, OC-0050, OC-0051, OC-0052, OC-0057 to OC-0065 (taxonomy, 9 tests), plus the FR-000-05/06/08 and TASK-347/348 adversarial and survivor tests in `Adversarial000Tests`, `StringsSurvivorTests` and `ErrorReporterTests`. Full list: 36 names, all failing as a nil or `""` catalogue lookup.
Repro: same command as D1, with D1 patched.
Question for S1: does `swift test` pass on the main Mac? If it does, the toolchains differ (SwiftPM xcstrings compilation), and the suite silently depends on that.

### Test noise (load, not defects)
In the **parallel** run only, these failed; each passed in isolation (`--filter`) and in the `--no-parallel` run:
- Thumbnails: OC-7045, OC-7129, OC-S5-02, OC-S5-03, TASK-387 (x2). `waitUntil` timed out waiting for the warm-up.
- Timing: OC-7098 (22.97 s against a 5 s limit), OC-7130 (580 ms against 300 ms), OC-7132 (6.38 s against 1 s; known flake), `SystemClock` "cancelling during a 10 s sleep wakes it early" (2.62 s against 1 s).
- OC-0041/0042 `LoggingMutationTests.swift:258`: 983 perf signpost events instead of 16. The capture sees other tests' signposts when suites run concurrently, so this is a test-isolation weakness, not a product bug.

Known: `KNOWN-TASK-368` (x2) and the "identifiers that contain a view or network name" known issue are recorded as expected (9 known issues total).
`LogContextCompileTests` ran (no scratch path) and passed.

---

## 2026-11-17: C1 FRD-002, part 1, on `s2/frd002` @ b983b9d (from `main` 3878487)

**Ready for review, not complete.** This is the foundation only. The watcher actor, the FSEvents adapter and the import step are not built yet.

**Spikes (FRD-002 §9, ADR-0008 S-8), macOS 26.7:**
- **(1) Verified:** `screencapture -x` writes `com.apple.metadata:kMDItemIsScreenCapture` (a binary-plist boolean, plus `ScreenCaptureType` and `GlobalRect`) on the file at save time, before any Spotlight indexing.
- **(2) Resolved:** the localised names come from `screencaptureui.app` `Localizable.loctable`, key `Screenshot`. There are 41 localisations and 34 distinct names, and every language's file-name format (`%@ %@ at %@` and its translations) starts with the name. Two quirks:
  - Dutch has a soft hyphen (U+00AD) inside the word.
  - The Arabic format starts with an RLM (U+200F).

  Both are ignored when matching.
- **(3) Not verified:** macOS falling back to Desktop when `location` is invalid.

**Deliberate spec changes (FRD-002 edited in the same commit; flagging them for S1):**
- FR-002-06: the prefix list now covers every system language, not just 9, taken from the system's own catalogue. A present-but-false attribute rejects the file whatever its name.
- FR-002-08: with no watermark yet (a new library), the reconcile scan imports nothing and only sets `lastScanAt`; older screenshots come from backfill. The FRD was silent on this, and without the rule a first launch would import the whole folder regardless of the onboarding checkbox.
- FR-002-01: symbolic links are resolved, and the target folder is watched. A listing refused for permission is `SSP-PRM-001`, not a Desktop fallback.
- FR-002-09: a volume with no birth date uses the modification date.

**Changes outside Screenshots (S1, please review these at merge):**
- Base `Ports.swift`: `FileInfo` gains `createdAt: Date?` and `kind: FileKind`, both defaulted, so the existing test doubles compile unchanged. New port `ScreenCapturePreferences`, with a CFPreferences adapter in `Adapters.swift`.
- Storage:
  - `IngestCandidate.countsAsCopy` (default true) and `IngestOutcome.unchanged(UUID)` implement the FR-001-15 backfill exception. `frd001` matches outcomes with `if case`, so the new case won't break it.
  - New `FlotsamDatabase.screenshotsLastScanAt()` and `setScreenshotsLastScanAt(_:)`.
  - `RetentionPreset.periodMillis` is now public.
- ADR-0008 status and ADR-0011 port table updated.

**Commands:** `swift build` clean (0 warnings in new files); `bin/check-architecture.sh` passes; `swift test --no-parallel` ran 541 tests (26 new), and the 36 failures are byte-for-byte the same names as A1 (all D2). Local D1 workaround applied unstaged and **not committed**. `bin/build.sh` was not re-run: the app target doesn't reference anything changed.

**Blocked on S1 (next part of C1):**
- `ContentKey.image` (FR-001-15) is on `frd001`.
- `SettingKeys.screenshotsEnabled` and `screenshotsFolderOverride` (`FolderOverride`) are on `frd008`.

The `ScreenshotWatcher` actor (enable/disable, the 30 s and activation re-resolution, retry list, 2-in-flight pacing, `SSP-PRM-001` retry) needs both, and I won't copy from builder branches. I'll rebase `s2/frd002` onto `main` once they merge. Until then the next S2 step is the `FolderEventSource` port with its FSEvents and polling adapters, which have no dependency on those branches.

---

## 2026-11-17: A3 on `frd003` @ 6fe1d6e (paste-back, marked ready by S1)

**Verdict: pass.** No new defects; nothing blocks the merge from S2's side.

- `bin/bootstrap.sh`: OK. `bin/check-architecture.sh`: **pass**.
- `bin/build.sh`: **BUILD SUCCEEDED**, 0 compiler warnings. This is the first app-target build of the new `App/Platform` adapters: AccessibilityPermissionProbe, CGEventKeyPoster, CarbonHotkeyRegistrar, LibraryHotkey, NSPasteboardAdapter and WorkspaceFrontmostAppProvider. The only build-log notice is the `appintentsmetadataprocessor` "no AppIntents dependency" line.
- `swift test --no-parallel` (local D1 workaround, uncommitted): 535 tests in 79 suites. The 36 failures are byte-identical to `main` A1 (all D2). `PasteServiceTests` and `PasteModuleInfoTests` pass.
- Launch smoke: launched, 0.0 % CPU, RSS 78.4 MB at 8 s; menu bar item `Flotsam` present; clean quit; no crash logs.
- Not exercised: paste-back itself. None of the adapters is referenced from `App/Flotsam` yet (no composition-root wiring), so the hotkey, the ⌘V post and the AX probe can't be driven from the running app. Re-run A2-style paste checks once the wiring lands (`frd003ui` or the merge).

---

## 2026-11-17: A1+A2 on main @ d7d11d9

**Verdict: pass. D1 and D2 are both fixed on Swift 6.2.4. No new defects. Capture, Library, Settings and the menu bar work in the Debug app. Paste-back was not tested.**

Machine: macOS 26.7, Xcode 26.3, Swift 6.2.4. Fresh clone, detached at d7d11d9. The machine had just booted and was heavily loaded (load averages 70–273 during the runs).

**Commands**
- `bin/bootstrap.sh`: OK (GRDB 7.12.0). `bin/check-architecture.sh`: **pass**.
- `swift test` (parallel, no scratch path, no workarounds): 632 tests in 92 suites, 16 failed. All 16 are load noise (below).
- `swift test --no-parallel`: **632/632 passed**, 9 known issues only. Plus the XCTest bundle: 6 tests, 0 failures. `LogContextCompileTests` ran and passed.
- `bin/build.sh`: **BUILD SUCCEEDED**, 0 compiler warnings in the app. The only `warning:` line is the AppIntents metadata skip.
- The test build has 14 warnings, all "no calls to throwing functions occur within 'try' expression". 8 are in `Tests/FlotsamStorageTests/DiskGuardIngestTests.swift` (lines 44, 75, 113–115, 145, 151, 157) and 6 come from `#expect` macro expansions. Cosmetic, but the zero-warnings rule covers tests too. Flagged for S1; not numbered as a defect.

**S1 fixes at c18cfac**
- **D1: fixed.** The test target compiles without a patch. `StorageEdgeTests.swift:218` now has an explicit closure type.
- **D2: fixed.** The 36 catalogue failures are gone. SwiftPM 6.2.4 still copies `Localizable.xcstrings` raw, and the raw-catalogue fallback in `FlotsamStrings.text(forKey:)` handles it.

**Load noise (parallel run only).** Every one passed in isolation (suite `--filter`) and in the `--no-parallel` run.
- Already on the known-noise list:
  - Thumbnail `waitUntil` timeouts: OC-7045, OC-7129, OC-S5-02, TASK-387 (x2).
  - Timing: OC-7098, OC-7130, OC-7132, and the `SystemClock` 10 s sleep-cancel test.
  - OC-0041/0042: 1017 signposts instead of 16.
- **New, same class. Suggest adding these to the known-noise list:**
  - `SchedulerTests` OC-7075 (x2) and OC-7113 (x2): `waitUntil { sleeps.count == 2 }` times out.
  - OC-7001 (`DataFolderLayoutTests.swift:63`).
  - OC-7018 (`IngestPipelineTests.swift:114`).
- The 9 known issues: KNOWN-TASK-368 (x2), the "identifiers that contain a view or network name" issue, and `Adversarial372ProbeCopyTests.swift:524` (zero-byte main with non-empty WAL).

**A2 launch smoke** (Debug app; database `~/Library/Application Support/Flotsam/flotsam.sqlite`, empty before the run, opened read-only)
- Launch: alive at 6 s, 0.0 % CPU, RSS 91 MB. Menu bar item "Flotsam, capturing" is present, with the full menu: Open Library, Save Clipboard, Toggle Shelf, Pause Capture, Notices, Settings…, Show Setup Guide…, Quit.
- Captures:
  - plain text → `text`
  - URL → `link`
  - image (64×48) → `image`, one `public.png` representation
  - file (Finder, and a raw `public.file-url`) → `file`
- Capture latency, from copy to the row appearing in SQLite: 0.12, 0.48 and 0.51 s. These are rough figures taken under load.
- A `ConcealedType` copy and a `TransientType` copy: item count unchanged (6 before, 6 after), and 0 hits for the secret strings in the database and the data folder. A plain copy afterwards was captured.
- Library panel opens from the menu: 10 items, sidebar counts correct, and no concealed or transient items. Settings opens with the title "Settings". The onboarding window (step 1 of 8) stayed open for the whole session.
- Quit was clean, with no `DiagnosticReports/Flotsam*`.
- **Paste-back not tested.** It needs Accessibility granted to the Flotsam binary, which isn't set up on this machine. Nothing is claimed either way.

**Defects:** none new. D1 and D2 are closed.

**Harness note (not a Flotsam defect):** `NSPasteboard.writeObjects([NSURL])` from a process that exits straight away leaves the pasteboard empty. Use `setString` on `public.file-url`, or Finder, instead.

---

## 2026-11-17: BLOCKER: Xcode 27.0 auto-update, licence not accepted (17:09)

`swift` and `/usr/bin/git` refuse to run until Ryan runs `sudo xcodebuild -license accept`. Command Line Tools git works for commits; nothing is built that way. **Every item below is written, never compiled, and never run. No results are claimed.**

### C1 FRD-002 part 2, on `s2/frd002` @ 31d11be (WIP, "NOT COMPILED")
Rebased onto `main` d7d11d9; part 1 is now a8c525e.

**Written**
- `FolderEventSource` port (Base).
- In Screenshots: the `ScreenshotWatcher` actor, `ScreenshotImporter`, `DatabaseWatermarkStore` and `PollingFolderSource`.
- `FSEventsFolderSource` (App/Platform).
- `AppContainer.startScreenshots`.
- FRs coded but unverified: FR-002-02, 03, 04, 05, 07, 08, 09, 12 (engine) and 13.

**Left**
- Watcher unit tests. These need a suspending stepped clock.
- FRD-002 edits:
  - "3 attempts" is read as 3 retries after the first skip.
  - Backfill is allowed when pickup is off or the mode isn't Active.
  - The string key is `ui.source.screenshot`.
- A possible FR-000-08 note for `ErrorReporter.clearNotices(code:)`.
- The GeneralPane import button and status line (overlaps FRD-008).
- `ModuleInfo`.
- The smoke test.

**Outside Screenshots (S1 review at merge)**
- `Ports/FolderEvents.swift`
- `ErrorReporter.clearNotices(code:)`
- The catalogue key `ui.source.screenshot`
- `FSEventsFolderSource.swift`
- `AppContainer.swift`
- The `Package.swift` test-target dependencies

**Open:** a 500-file backfill takes about 125 s (0.5 s stability wait, 2 in flight); this needs a spec ruling. Spike 3 is still unverified.

### B FRD-001 8T, part 1, on `s2/frd001-8t` @ 7d8a4d2 (WIP, "NOT COMPILED, NOT RUN")
- Harness `FRD001ContractHarness.swift`, plus 49 tests covering every reachable ID in OC-1002..1055. Ten of them (OC-1005, 1006, 1008..1010, 1030, 1042, 1044, 1045, 1055) test only the reachable half.
- Unreachable from the package:
  - OC-1001: CPU profile.
  - OC-1003: menu tracking.
  - OC-1022 and OC-1023: Secure Event Input.
  - OC-1033: system screenshot.
  - OC-1007: the panel half only.
- Next: compile and run with `--filter FRD001Contract`; OC-1056..1110 is the next lane.
- Lead L-A: the CAP-LIM-003 context count may be the 500 limit rather than the actual count. Unconfirmed.
- Lead L-B: CAP-LIM-001 carries `.byteSize`, but the message reads `.limitBytes`. Unconfirmed.

### B FRD-003 8T, part 1, on `s2/frd003-8t` @ f9ea349 (WIP, "NOT COMPILED, NOT RUN")
- OC-3008–3028 drafted (OC-3017 not written).
- Unreachable from the package: OC-3001–3007, 3014, 3016, 3021 and 3048 (AppKit, windows and geometry).
- Next ID: OC-3017.
- **Suspected defects, from reading the code only; to be confirmed by a run:**
  - **D3 (Major):** `LibraryViewModel.jump(toLast:)` (~line 292). ⌘↓ sets `visibleLimit = loadedRows.count` (one 200-row page) and never pages, so with 10k rows the selection lands on row 200, not the oldest item (OC-3015).
  - **D4 (Major):** `LibraryPresentation.relativeTime` (~line 47). `RelativeDateTimeFormatter` gives "yesterday" and "10 days ago". OC-3019 wants "Yesterday", and an absolute date after 7 days.
  - **D5 (Major):** `ItemRow` / `LibraryRowPresentation` have no missing-file state, so OC-3020's "Missing" badge can't be shown.
  - **D6 (Minor):** `LibraryPreview.memberLimit = 10`, but the FRD and OC-3060 say 20.

### C1 FRD-002 Screenshot Pickup on `s2/frd002` @ 54e69b6 (rebased onto main f190da8, compiles, green except one known flake)
- Commands:
  - `swift test --package-path Packages/FlotsamCore`: 1 failure in the full run, the timing flake OC-7132 (`Unmapped007TimingTests.swift:151`, `slowest < 1.0`). It is not FRD-002 code. A filtered rerun (`--filter Unmapped007TimingTests`) passed 5/5, with OC-7132 at 1.036 s.
  - FlotsamScreenshots: 55/55 pass (was 5 failing).
  - `bin/check-architecture.sh`: pass.
  - `bin/build.sh`: BUILD SUCCEEDED.
- Root-cause fixes (FRD-002 FR-002-07/09/12 and the SSP-IO-002 row updated in the same commit):
  - `/var` vs `/private/var` path forms made the reconcile scan and FSEvents miss each other's dedupe, so files were imported twice. `ScreenshotFolderScanner.scan` now gives each file one path form.
  - The watermark window re-queued files before their retry budget was spent, so they never ran out. The budget is now spent first, and an exhausted file is marked seen; only "Import recent screenshots" brings it back.
- FRs: FR-002-01..13 and FR-002-15 implemented. FR-002-14 (p95 time-to-queryable) has no measurement; only the in-flight=2 cap is enforced.
- Not run: the real `FSEventsFolderSource` has no automated test; the fakes cover the watcher.
- History note: e255eb4 ("WIP, NOT COMPILED") is still in the branch history. HEAD compiles.
- Watcher test files are now tracked. Two mechanical compile fixes; no expectation weakened.
- Still open from before: the 500-file backfill takes ~125 s and needs a spec ruling.

### C2 FRD-006 Shelf on `s2/frd006`: started from origin/main f190da8 (in progress)
- **C1 follow-up @ 578c5d0:** S1 ruled on the FR-002-12 backfill (see below). Live pickup was NOT already winning: the import queue was strict FIFO, so a fresh screenshot sat behind every queued backfill file.
  - Fix: live jobs now go ahead of queued backfill jobs. Each class stays FIFO.
  - FR-002-12 updated in the same commit.
  - New test "FR-002-12: live pickup goes ahead of a running backfill" fails 3/3 with the fix removed. A first unmutated-vs-mutant run passed spuriously, probably a stale build; reruns were consistent.
  - Results: the full `swift test` run is green (287 swift-testing tests, 8 known issues; 56 screenshot tests); check-architecture passes.
  - Ready for S1 review/merge.
- **C2 FRD-006:** the first agent hit its context cap after reconnaissance only, with nothing written. Restarted as C2a (package layer: model, reveal machine, layout, drop/drag logic, catalogue keys, LogEvent); C2b (App layer) follows. Spec drift so far:
  - `shelf.empty` should be `ui.shelf.empty`.
  - FR-006-18 needs a `LogEvent.shelf` extension.
  - The delete-confirm text is FRD-004's and has no key.

---

## 2026-11-17: A1+A2 on main @ 97b5a14

**Verdict: pass. A1 green (no failures, no load flake this time); A2 capture and concealed filter verified; paste-back untested (no AX grant). No new defects.**

Machine: macOS 27.3, Xcode 27.0, Swift 6.4. Fresh clone, detached at 97b5a14. Load average was 12 to 22 during the run (another build agent active).

**A1 commands**
- `bin/bootstrap.sh`: OK (GRDB 7.12.0).
- `swift test` (parallel, no scratch path, no workarounds), run in `Packages/FlotsamCore`: **0 failures, exit 0**. Swift Testing runs: 292 tests in 45 suites with 8 known issues (this matches the S1 figure exactly), 307 in 38 with 1 known issue, 94 in 8, 56 in 9, 21 in 2, 10 in 2, and four 1-test runs. That is 784 tests in total, 9 known issues. The XCTest bundle: 6 tests, 0 failures.
- OC-7132 (`Unmapped007TimingTests.swift:151`) **passed** in the full run, so no solo re-run was needed.
- `bin/check-architecture.sh`: **pass** ("architecture checks passed").
- `bin/build.sh`: **BUILD SUCCEEDED**. The only app `warning:` line is the AppIntents metadata skip.
- Test build: the same 14 "no calls to throwing functions occur within 'try' expression" warnings as before (8 in `Tests/FlotsamStorageTests/DiskGuardIngestTests.swift`, 6 from `#expect` expansions). Still open for S1.

**A2 launch smoke** (Debug app; database `~/Library/Application Support/Flotsam/flotsam.sqlite`, opened read-only; 10 items before the run)
- Launch: alive at 8 s, 0.0 % CPU, RSS 88 MB. Menu bar item "Flotsam, capturing" is present. Menu: Open Library, Save Clipboard, Toggle Shelf, Pause Capture, Notices, Settings…, Show Setup Guide…, Quit Flotsam.
- Captures, each stored exactly once (copyCount 1):
  - text → `text`
  - URL → `link`
  - image (71×48 PNG) → `image`, with one representation. Copying it three times gave one row with copyCount 3.
  - file (`public.file-url`) → `file`, one `bundleMember` row with the path. Copying it again gave copyCount 2, still one item.
- Re-copying the same text gave one row with copyCount 2.
- Concealed: a `org.nspasteboard.ConcealedType` copy left the item count unchanged (14 before, 14 after), and 0 hits for the secret string in the database and the data folder (grep of the whole data folder; SQL `LIKE` on `plainText` also 0).
- FRD-004 Library: opened from the menu bar, shows 17 items, search field, All / Pinned (0), the Types sidebar (Text, Rich Text, Links, Images, Files) and the Apps sidebar. Counts agree with the database (text 6, richText 1, link 2, image 4, file 4). Rows show kind icon, title, source and relative age ("26s ago", "1m ago"). The footer reads "17 items" and "Press ⌘V to paste". Concealed items absent. Not exercised: search, pin, delete, preview, the keyboard jump to the last item.
- Quit: clean (`quit` via Apple Events, process gone in under 4 s). `PRAGMA integrity_check` ok. No `DiagnosticReports/Flotsam*`.
- **Paste-back: untested (no AX grant** for the Flotsam binary).

**Observations (not defects)**
- On launch Flotsam captured whatever was already on the clipboard (a rich-text item). This is expected capture-on-start behaviour; noted because the data folder is shared with earlier runs.
- The source app for items written by my harness shows as "UserNotificationCenter" (the frontmost app at the time), not the writing process. This is expected for a headless pasteboard writer.
- Harness traps (not Flotsam): a pasteboard tool that crashes on a missing argument leaves the old clipboard in place and looks like a missed capture. Check the tool's exit status before blaming the app.

**Defects:** none.

Clipboard: the prior contents (one item, `public.rtf` and `public.utf8-plain-text`) were saved before the run and restored after the app quit; a byte comparison of the saved and restored types and data matched.

---

## 2026-11-17: filler: test-build warnings on `s2/test-warnings` @ 1f40ae0 (from `main` 97b5a14)

**Verdict: pass.** Tests-only change; no production code, no behaviour change.

- Cause: `IngestActor.ingest` returns `FlotsamResult<IngestResult>` and never throws (failures come back as `.failure`), so the `try` on `rig.ingest.ingest(...)` in `DiskGuardIngestTests.swift` did nothing. `Rig.create` (which calls `.get()`) does throw, and its `try` stays.
- Dropped the `try` at all 17 call sites: 8 statement sites (lines 44, 75, 113, 114, 115, 145, 151, 157) and 9 inside `#expect` (lines 171, 172, 177, 178, 179, 184, 197, 198, 203).
- **Count differs from the earlier logs:** the build reports 17 "no calls to throwing functions occur within 'try' expression" warnings here (8 + 9), not 14 (8 + 6). After the change: 0 of them, and 0 warnings of any kind in the rebuilt test targets.
- `swift test` (parallel, no scratch path), in `Packages/FlotsamCore`: exit 0, no failures. 292 tests in 45 suites with 8 known issues, the same as before. OC-7132 passed in the full run.
- `bin/check-architecture.sh`: **pass**.
- Test bugs found: none. No site was a test meant to exercise a throwing path; each asserts on the returned `FlotsamResult`.

---

## 2026-11-17: Lane A3 smoke, FRD-005 triggers/shortcuts @ a6c6ff0

**Verdict: pass with 2 defects (both minor, no data effect).**

- Clean clone at a6c6ff0, `bin/bootstrap.sh` ok. `swift test` (parallel, no scratch path), in `Packages/FlotsamCore`: **0 failures, exit 0**. Swift Testing runs include 287 tests in 44 suites with 8 known issues (matches S1), 270 in 36 with 1 known issue, 157 in 12, and a 25-test / 5-suite run with 2 known issues; 872 tests in total, 11 known issues. XCTest bundle: 6 tests, 0 failures.
- OC-7132 (`Unmapped007TimingTests.swift:151`) passed in the full run (3.3 s), so no solo re-run was needed. Other agents were running `swift test` on the same box.
- `bin/check-architecture.sh`: **pass**. `bin/build.sh`: **BUILD SUCCEEDED** (only warning: AppIntents metadata skip).

**Test data dir:** the app has none (`AppContainer.dataFolder` uses the Application Support directory unconditionally). The run was isolated by launching the Debug binary directly with `CFFIXED_USER_HOME` pointing at a scratch directory. This is an OS-level redirect, not an app feature. The real database was untouched (17 items before and after, 0 rows with the test marker). Clipboard saved before and restored after.

**A3 smoke (editor driven by real keystrokes via System Events)**
- Editor opens with Cmd+K ("Shortcut and Trigger"): Shortcut row ("Not set"), Record shortcut, Trigger field with help text, Cancel, Save. **pass**
- Assign trigger and save: stored as `;a3s2sig` (text item) and `;a3s2link` (link item). **pass**
- Assign shortcut and save: Ctrl+Opt+A and Ctrl+Opt+B stored as hotkeyCode / hotkeyModifiers. **pass**
- Persistence: after the editor closes, after reopening the editor, and after a full quit and relaunch, the DB (read-only) and the editor both show the saved shortcut and trigger. **pass**
- Trigger grammar (TRG-VAL-001): no symbol, a space, and a lone symbol are rejected with the catalogue copy; `;` plus 23 letters accepted, plus 24 rejected; `;sig`, `;x1-_` accepted. Empty shows the help text. **pass**
- Duplicate trigger (TRG-VAL-002), case-insensitive: inline copy shown, Save disabled. **pass**
- Shortcut rules (TRG-VAL-003): Shift+A, Opt+Shift+A, Opt+J, Cmd+C, Cmd+Q rejected with the catalogue copy, recording continues. Ctrl+Opt+A accepted. Cmd+Space and Ctrl+Space not tried (system-wide side effects). **pass (partial)**
- Duplicate shortcut (TRG-VAL-004) shows the catalogue copy. **pass**
- Image item (AC-005-08): no trigger field; only the shortcut, with the note that triggers expand text. **pass**
- Non-ASCII trigger via GUI: **untested** (the keystroke harness mangled the character); covered by the AC-005-07 unit tests.
- Unknown-variable warning (TRG-VAL-005): **FAIL**, see D1.
- Capture regression, each stored once: text (`text`), URL (`link`), image (`image`), file (`file`, one `bundleMember` row), rich text already on the clipboard at launch (`richText`). Re-copying text gives copyCount 2, still one item. Concealed (`org.nspasteboard.ConcealedType`) copy: item count unchanged, 0 hits for the secret string in the DB, data folder and Preferences (checked twice). **pass**
- Library opens, sidebar and footer render. Pin and delete (and the pinned delete-confirm): **not hosted yet**. The app wires only Cmd+K; pin, tags, note, edit, delete, sort and ungroup are FRD-004 and inert (comment in `AppContainer.swift`). Cmd+P and Cmd+Delete had no effect, as designed.
- Menu bar item and menu: **pass**. Clean quit via the menu, process gone, no DiagnosticReports entry, `PRAGMA integrity_check` ok (twice). **pass**
- Live trigger expansion: **not hosted yet**. Paste-back and anything needing Accessibility: **untested (no AX grant)**.

**Defects**
- **D1 (TRG-VAL-005 / FR-005-17):** with an item containing an unknown variable (copied text `... {foo} {date:@@}`), assigning a trigger shows the generic copy "Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings > About." instead of "An unknown variable was left as plain text." The save HUD shows the same wrong text. The save itself succeeds (trigger stored). Cause confirmed in code: `TemplateVariables.validate` attaches `.count` to the error, `FlotsamStrings.message(for:)` then passes one argument to a template with no placeholder, the arguments-versus-placeholders check fails and it falls back to SYS-INT-001. Repro: copy text containing `{foo}`, open it in the Library, Cmd+K, type `;x1`. Fixed on main by TASK-395 (checked in the 2990d01 entry below).
- **D2 (FR-005-04 / AC-005-02, minor UX):** in the shortcut recorder, after a rejected chord (reserved or duplicate), recording a valid chord is accepted and the shortcut shows, but the red inline error stays on screen. Save still works. No FRD text says it must clear, so this is stale state, not a spec break.

**Observations (not defects)**
- File capture was missed on the first attempt in a rapid sequence and stored on retry (harness timing not ruled out; see the 2990d01 entry).

Clipboard: restored after the run.

---

## 2026-11-17: Lanes A1+A2, TASK-396 triggers hosted @ 2990d01

**Verdict: pass. One known issue (TASK-399), no new defects.** Hands-on trigger checks (AX grant, live typing) skipped as briefed; those are done by hand separately.

- Same scratch clone, fetched and checked out at 2990d01. `swift test` (parallel, no scratch path), in `Packages/FlotsamCore`: **0 failures, exit 0**. Runs: 287 tests in 44 suites with 8 known issues (matches S1), 270 in 36 with 1 known issue, 167 in 13 with 1 known issue, 59 in 7, 53 in 6, 30 in 6, 27 in 3, and three 1-test runs. XCTest bundle: 6 tests, 0 failures. 10 known issues in total.
- **Known issue, not new:** `theDotStaysSetWhileLatchedEvenIfAPermissionIsRevoked` (TriggerHostingWorfTests.swift:202, `h.engine.showsWarningDot`) records a known issue. Its fix is TASK-399, in progress.
- `bin/check-architecture.sh`: **pass**. `bin/build.sh` (build directory removed first): **BUILD SUCCEEDED**, only the AppIntents metadata warning.

**A2 launch smoke** (Debug app, isolated test home via `CFFIXED_USER_HOME`; real database untouched at 17 items)
- Launch alive, menu bar item present. Menu: Open Library, Save Clipboard, Toggle Shelf, Pause Capture, Notices, Settings…, Show Setup Guide…, Quit Flotsam. **pass**
- Captures: text (`text`), URL (`link`), image (`image`), file (`file`, one `bundleMember` row per copied file), each stored once. **pass**
- Concealed copy: item count unchanged, 0 hits for the secret in the test data folder. **pass**
- Library opens from the menu bar, 9 items listed with Types and Apps sidebars, footer "9 items". **pass**
- Quit via the menu: process gone, `PRAGMA integrity_check` ok, no DiagnosticReports entry. **pass**
- Also checked, editor only (no live trigger): the unknown-variable warning now shows "An unknown variable was left as plain text." (D1 from the entry above is fixed at 2990d01).
- Live trigger expansion and paste-back: **not run** (skipped per brief; needs AX).

**Observations (not defects)**
- File capture is intermittent in my harness. At 2990d01 a copied file was missed three times in a row (5 to 8 s gaps) after an image or file capture, then stored when a different file was copied, and stored on a later retry of the first file once a text copy had come between. Cause not determined (harness pasteboard timing versus an app-side dedupe or skip); it also missed once on a6c6ff0 and stored on retry. Not reproducible on demand, so not filed as a defect; worth a look by whoever owns capture dedupe.
- The `pb image` harness tool needs a path argument; a call without one does not capture anything (harness trap, not the app).

**Defects:** none new.

Clipboard: restored after the run.

---

## 2026-11-17: FRD-006 Shelf slices 1-3 on `s2/frd006` @ 42367be (from `main` 97b5a14)

**Verdict: slices 1-3 pushed, suite green, architecture check passes. Four drift items open, one pre-existing flake surfaced.** The main merge (origin/main 86fc162) into `s2/frd006` was not done in this session; it is the next step.

**Slices**
- Slice 1, 77a9ffb: ShelfText and catalogue keys (FR-006-06).
- Slice 2, 142c8bd: ShelfPresentation, shared ItemSpeech and TextExcerpt (FR-006-07, FR-006-19). Merge of origin/main as 437e695.
- Slice 3, 42367be: ShelfModel, ShelfKeyMap, ShelfPorts (FR-006-06/08/09). 16 files, +1197/-25.
- Rule 9 extractions into FlotsamBase, with Library and Storage forwarding to them: `PinRule.pinsAll(states:)`, `DeleteConfirmation` (required, message, selection after delete), `KeyInput`/`KeyStroke` (Library keeps typealiases).
- FRD edits in the same commit: FR-006-08 (first card is selected on reveal, so Down, Down, Return pastes the third card; decided by Friday and confirmed by S1) and FR-006-07 (card text and Missing state come through Shelf ports; until wired a card shows the item's primary line and no Missing badge).

**Tests** (`swift test` in `Packages/FlotsamCore`, last full run before the commit): Shelf 90, Library 94, Core 307 with 1 known issue. OC-7132 did not flake. 42 mutants run over the OC tests; the first-card-selected mutant killed 17 tests. Two benign survivors: removing the `isOpen` guard in `handle` was killed once I added `aShelfThatIsNotOpenTakesNoKeys`; removing `unsubscribe?()` alone is equivalent (`storedItemsChanged` has its own `isOpen` guard), and the double mutant is killed by the OC-6043 "hidden shelf stops listening" test.

**Drift and gaps (surfaced, not fixed)**
- DESIGN.md:419-423 lists `shelf.*` keys but the catalogue uses `ui.shelf.*`.
- FR-003-07's Missing badge has no `ItemRow` flag on main. Per S1 this is an FRD-003 gap S1 owns. The Shelf has only the port seam (`details.memberPaths` plus `effects.fileExists`, inert default); no flag, no badge.
- Deferred storage queries: `cardTexts` and `memberPaths` are ports with inert defaults and no storage implementation yet.
- Deferred app-layer paste adapter: the Shelf has its own paste types and ports per ADR-0001; the app layer must adapt them.

**Pre-existing flake, not mine:** Library test `optionArrowsStepThroughSidebarFilters` (`LibraryViewModelTests.swift:303`, `h.source.queries.last?.filter == .all`) fails about 5% of runs on `s2/frd006` (4/80) and about 11% on baseline 437e695 (9/80).

**Assumptions, not written into the FRD (not deliberate decisions)**
- Return, Option-Return, Shift-Return and Cmd-C act only with exactly one card selected (mirrors the Library).
- Paste, Plain and Copy menu actions apply to the clicked card; Pin and Delete apply to the selection if it contains the clicked card, else to that card alone.
- Arrow movement clamps at the ends (no wrap). Cmd-C and Shift-Return both map to copyOnly. `fileExists` runs on the main actor.
- OC-6056 is an extra test beyond the assigned list; the OC-6062 test covers the selection half only.

## 2026-11-17: Merge origin/main into `s2/frd006` @ 4c1e70b (from `origin/main` 86fc162)
- Clean merge, no conflicts. `swift test` 295 tests in 46 suites passed (8 known issues, 0 failures); `bin/check-architecture.sh` pass.

## 2026-11-17: FRD-006 C2a slice 4, drag-out planner on `s2/frd006` @ 7b497ac (on top of 4c1e70b)

**Verdict: pushed, suite green (912 tests across all targets, 0 failures, no flake), architecture check passes.** Drag half of OC-6062 done; the AppKit drag source is C2b.

**What it is.** `ShelfDragPlanner` (pure, no AppKit): from the dragged cards and their loaded content it returns the drag-pasteboard items in on-screen order (text plus stored representations, an image payload for `NSImage`, one file URL per existing bundle member), the contributing cards for `pasteCount` accounting, and `LIB-DAT-001` when nothing is left to drag. `ShelfModel.covered(by:)` is now public and is the one rule for which cards an action covers (Pin, Delete, drag).

**OCs covered:** 6062 (drag half), 6067, 6068, 6069, 6072, 6073, 6075, 6076, 6078, 6079, 6080. Not covered here (app layer, C2b): 6070, 6071 (copy-only operation), 6074 (drag image badge; `cardCount` supplies the number), 6077 (drag threshold), 6081, 6082 (the `SHF-OS-001` HUD for an aborted session), and the changeCount and no-own-write checks (AC-006-10), which need a real pasteboard.

**Tests:** 19 new (15 planner, 4 selection), Shelf suite only; 19 mutants run over them, all killed.

**Rule 9 extractions (no behavior change; existing Paste tests are the guard)**
- Base: `ItemKind.isTextBearing`, `isFileBacked`, `isImage`, and `PasteboardUTI` (`plainText`, `fileURL`). Payload's `PasteboardTypes`, the diagnostics copy and Paste now point at it instead of repeating the strings.
- Storage: `ItemContent.storedRepresentations`, `plainTextRepresentation`, `fileURLRepresentation(for:)`, `existingMemberURLs(files:)`, `ItemMember.existingURL(files:)` (moved from `PastePayload`). `PastePayload` is a thin wrapper.
- Payload: `PasteboardTypes.imagePriority` is public so the Shelf picks the best image the way capture does.
- Left apart deliberately: `ItemKind.isTextEditable` has the same kind set as `isTextBearing` today but is a different rule (FR-004-07 versus FR-003-15); comments say so.

**FRD edits:** none.

**Assumptions (FRD silent, not written into it)**
- Dragging a card outside the selection drags that card alone and leaves the selection as it is; a card inside the selection drags the whole selection.
- In a multi-card drag, a card with nothing left (all members gone, or an image with no usable image data) is skipped; `LIB-DAT-001` only when no card contributes. FR-006-11 states the single-card case only.
- No cards at all is `SHF-OS-001` (a drag that cannot be created).
- A bundle counts once for `pasteCount` and the `shelf.dragOut` count; the count is cards, not pasteboard items.
- C2b owes: loading content, the copy-only operation, NSImage conversion, lazy provision, accounting on an accepted drop, hiding a transient Shelf, HUDs and the `shelf.dragOut` log line.

**Drift:** none new. The duplicated `public.utf8-plain-text` and `public.file-url` literals (Payload, Paste, diagnostics) are consolidated by the above.

## 2026-11-17: FRD-006 S1 rulings recorded, doc-only, on `s2/frd006` @ 635981f (on top of 7b497ac)

**Verdict: pushed, docs only; `bin/check-architecture.sh` passes. No docs lint exists under `bin/`.**

**Written into FRD-006:** Slice 3 rulings 1, 3, 4 into FR-006-08 (single-card gate for Return, ⌥Return, ⇧Return, ⌘C; arrows clamp; ⌘C and ⇧Return both copy-only); ruling 2 into FR-006-09 (Paste, Plain, Copy act on the clicked card; Pin, Delete, drag on the selection if it holds the clicked card, else the clicked card alone). Slice 4: ruling 1 into FR-006-10, rulings 2 to 5 into FR-006-11 (skip empty cards, `LIB-DAT-001` only if all are empty, an image with no usable data is empty, empty list is `SHF-OS-001`, `pasteCount` counts cards). The §6 error rows and AC-006-12 follow; new AC-006-22 (keyboard), -23 (menu scope), -24 (drag-out). Drop-in FRs and OCs untouched.

**DESIGN.md:** Shelf table keys now match the catalogue: `ui.shelf.empty` (one combined string, replacing `shelf.empty.title` and `.body`), `ui.shelf.drop`, `ui.shelf.sectionRecent`. `shelf.section.pinned` removed: the code reuses `ui.library.pinned`, noted under the table. No other stale `shelf.` keys in the file.

**Left alone:** `.claude/oracle/frd-006-contract.json` is a blind-generated oracle (`generated_blind`), so it was not synced. It still says `shelf.empty` in one assertion (line 400), which S1 may want fixed in a separate pass.

**Open point:** FR-006-18 says `shelf.dragOut` carries the "item count"; the code counts cards (bundle once). Not edited, since it was not in the rulings.

**Resolved (fe35d9a, s2/frd006):** per S1's rulings, FR-006-18 now says `shelf.dragOut` carries the card count (a bundle counts once), and contract OC-6040 says `ui.shelf.empty`, marked `"amended": "S1 ruling 2026-11-17"`. The architecture check passes and the JSON is valid.

## 2026-11-17: FRD-006 C2a slice 5, drop acceptance on `s2/frd006` @ fee890f (on top of merge a5c331e)

**Verdict: pushed, suite green (about 1001 tests across Swift Testing and XCTest, 0 failures, no flake fired), architecture check passes, mutation 55/55 killed.** The drop-in half of FR-006-12 to -14 and the log line of FR-006-18 are done as pure logic; the AppKit drop target is C2b. Main (448a15c) was merged first as a5c331e and the suite re-run on the merge.

**What it is.**
- `ShelfDropPlanner` (pure): `acceptance(types:originatesInShelf:)` returns `.accepted`, `.refused` or `.refusedSilently` (own drag). `plan(...)` returns the `IngestCandidate` plus one `SHF-IO-001` per skipped file, mapping capture's `CAP-VAL-001` to `SHF-VAL-001` and `CAP-DAT-001` to `SHF-IO-001`.
- `ShelfDropService`: `drop(...)` returns `.ignored`, `.failed` or `.stored(itemId:skippedFiles:)`. It reports skipped files (user-initiated) and ingest warnings (background) through `ErrorReporter`, writes the `shelf.dropIn` log line and calls `dropCompleted`. It goes through a new `ShelfIngesting` port, which `IngestActor` conforms to.
- Rule 9 extractions, no behavior change: `Classification` and `ClassifiedMember` moved from Payload into Base. `IngestCandidate.init(classification:source:origin:occurredAt:)` is now the one mapping, shared by `IngestWorker` (clipboard) and the Shelf drop. `PasteboardTypes.fileURL(from:)` is the one file-URL parse.
- Not touched, per S1: `ItemKind.isFileBacked` and the Storage `ItemMember` existence helpers (S1 folds those in with TASK-397).

**OCs covered:** 6083 to 6087, 6090 to 6095, 6097 to 6106, 6109, 6110, 6117, 6118. 6089 and 6108 are covered structurally (the module imports only Base, Storage, Payload and Foundation, and there is no AppKit in the planner or service). Deferred: 6020, 6096, 6114 (app layer or real pasteboard, C2b).

**Tests:** 50 net new for the slice. Shelf 42 (planner 21, service 21), Storage 4 (`IngestCandidateClassificationInitTests`, with the existing IngestWorker tests unedited), Payload 4 (`PasteboardFileURLTests`, fixtures use `/srv/example/...`). The repo is public, so no personal paths.
- Mutation: 55 mutants (compilable only) over the planner, service, shared init, classifier and file-URL parse. First run 49 killed; survivors P10, P11, P19, V04, U01, U02. I added 12 tests to close them (Storage 4, Payload 4, planner `nothingStorable`, `goneAtClassification` and `allUnreadableCountsFiles`, service `trimmedBundleIsNotPartial`); re-run 55/55 killed. No source file was left mutated (byte-identical restore checked with `cmp`).
- Caveat: those 12 are tests of my own code, written from the FRD to close mutation gaps, not the blind oracle. Worf should review them.

**FRD edits (same commit):** FR-006-12 and AC-006-13: a drag from the Shelf itself is refused silently (no highlight, no HUD). FR-006-14, AC-006-16 and the SHF-LIM-001 row in the error table: files and folders are held by reference and never size-checked, so `SHF-LIM-001` applies only to dropped text over 10 MiB and image data over 100 MiB; AC-006-16 now has one unreadable, one huge but readable and one readable file giving a 2-member bundle with one `SHF-IO-001` and no `SHF-LIM-001`.

**Contract edits (`.claude/oracle/frd-006-contract.json`), each marked `"amended": "S1 ruling 2026-11-17"`:** OC-6087 (own drag refused silently, no HUD) and OC-6099 (the 3-file case above).

**Assumptions (FRD silent, not written into it)**
- OC-6087's own drag is silent and writes no log line.
- Capture mode and ignored apps do not apply to drops, so OC-6090, 6093 and 6094 are stored regardless.
- Ingest warnings (for example `CAP-LIM-003` on a bundle trimmed to 500 members) do not count as a partial store; only skipped files do.
- All files unreadable produces one `SHF-IO-001`; a partial drop produces one `SHF-IO-001` per skipped file (throttling applies at the HUD).
- C2b owes: the NSDraggingDestination and hover highlight, reading the drag pasteboard, HUD display, and the 6020, 6096 and 6114 checks.

**Drift / observations (surfaced, not fixed):** the classifier's file `contentKey` depends on member order, so the same files dropped in a different order store a different item (dedupe miss). Left as is; S1 to decide whether it should sort.

**S1 ruling (2026-11-17) on the contentKey order:** keep pasteboard-order keys for MVP, no change on s2/frd006. FR-001-15 specifies "standardised paths in pasteboard order", and FR-006-13 says a drop dedupes exactly like capture, so sorting is a cross-FRD change. Post-MVP: TASK-406 (sort the paths for the key only, keep the stored member order, and edit FR-001-15 and FR-006-13 in the same commit). The four assumptions above stand.

**Worf on fee890f: pass with conditions (S1 rulings, 2026-11-17).** Worf's tests are on worf-s2-006 904b04f (S1 merges them). Queued for the next s2/frd006 commit, with the Shelf Missing-rule fix after the 397 merge:
- W-1: a bundle trimmed to the 500-member cap is not a partial store; CAP-LIM-003 tells the user. Keep the code and `trimmedBundleIsNotPartial`. Amend FR-006-14 ("unless some part was skipped") and FR-006-18 ("when not every item was stored") to say trimming to the cap is reported by CAP-LIM-003 and does not count as skipped.
- W-3: delete `acceptanceTakesTypesOnly` (tautological).
- W-4: `dropIgnoresCaptureMode` can't fail; the real gate (OC-6090/6093/6094) is C2b's to test.
- W-2 (undecodable image drop, no HUD): post-MVP ticket, untouched. W-5 to W-8: no action.

**Queued after 397 lands (S1 split):** S1 deletes `ItemMember.existingURL` and reroutes paste and drag-out itself. S2: route the ShelfModel Missing rule (ShelfModel.swift:208-210, `effects.fileExists`, the default at ShelfPorts.swift:82) through the shared rule per FR-003-07 (no FRD edit), with tests for a bundle with one gone member and an empty bundle; and change ShelfModel.swift:193 to `kind.referencesFiles`.

## 2026-11-17: FRD-006 Shelf Missing via the shared rule + Worf W-1/W-3 on `s2/frd006` @ 138da63 (merges 7221643, d57045d)

**Verdict: pushed, local equals origin (d57045d), full suite green on the merged tree (1085 tests in 10 runs, 0 failures, 9 known issues that were already there), architecture check passes, both mutations killed.** Main ef250e4 (TASK-397, TASK-401) was merged as 7221643 with no conflicts; main da94896 (TASK-408, ClipboardCapture only) as a second merge, d57045d, also clean. `ItemKind.isFileBacked` and `ItemMember.existingURL` are not reintroduced (no hits in Sources or the app; the two test files that still mention `isFileBacked` are main's own guard test and a comment).

**Shelf Missing rule (FR-003-07, Rule 9).** The Shelf and the Library now call one function: `Collection<ItemMember>.anyExists(files:)` in Storage (`ItemContent+Pasteboard.swift`), which asks `FileMemberLocator.currentURL` for each member (bookmark first, then path). `ItemContent.existingMemberURLs` uses the same `ItemMember.currentURL(files:)`. An item is Missing when none of its members exist; a bundle with one member left is not Missing; an empty bundle is Missing. The Library's private `FileMemberRef` copy of the rule is deleted.
- `ShelfCardDetails.memberPaths(of:)` became `fileMembers(of:) -> [UUID: [ItemMember]]`. `ShelfModel` takes a `FileSystemPort` (default `LocalFileSystem`) and filters with `ItemKind.referencesFiles`. A card the port does not describe is never marked, so the inert default (`NoShelfCardDetails`) still marks nothing.
- The `fileExists` effect port is deleted from `ShelfEffects` (no remaining user). The Shelf still imports only Base, Storage, Payload and Foundation.
- Docs: `FileMemberLocator` doc comment and `docs/ARCHITECTURE.md` list the Shelf as a caller. W-1: FR-006-14 and FR-006-18 now say trimming a bundle to 500 members is reported by CAP-LIM-003 and does not count as skipped. W-3: `acceptanceTakesTypesOnly` deleted. FR-003-07 and the Missing wording are untouched.

**Tests.** New `ShelfMissingTests` (4, real files, real bookmarks, real `LocalFileSystem`, real database for the Library side): moved member with a resolving bookmark is not Missing; deleted member is Missing; undescribed and non-file cards are never Missing; Shelf and Library agree on seven cases (all present, moved, partially gone, partially gone with the survivor moved, all gone, single file gone, empty bundle). The old `fileExists`-stubbing test became `inertDetailsPortMarksNothingMissing`. Shelf target: 158 tests, 0 failures.
- Mutation (both restored, `git diff` clean afterwards): (1) Shelf back to a path-only `FileManager.fileExists` check: OC-S2-M1 and M4 fail. (2) Shared rule changed to "all members exist": M4 fails on both the Shelf and the Library assertions.

**Assumption.** I kept the port architecture (FR-006-07 says "through Shelf ports") rather than reading `ItemRow.isMissing`, which `FlotsamDatabase.items(matching:)` already fills. Using `isMissing` would be simpler but changes how the Shelf gets its data; S1 may prefer it once the real `ShelfCardDetails` lands (it is still deferred, the app uses `NoShelfCardDetails`).

**C2b note (W-4).** `dropIgnoresCaptureMode` can never fail, so it proves nothing. C2b must test the real gate: OC-6090, OC-6093 and OC-6094 (a drop is stored regardless of capture mode and ignored apps), against the real drop target and pasteboard.

## 2026-11-17: FRD-006 C2b slices 1 and 2 (card text adapter, paste adapter) on `s2/frd006` @ 7eefa2b

**Verdict: slices 1 and 2 pushed, local equals origin (7eefa2b). Slices 3 to 6 NOT started in code; a compaction cap ended this agent's run, so the rest goes to a fresh agent.** Slice 1: `swift test` 319 tests in 49 suites, 8 known issues, 0 failures; `bin/check-architecture.sh` passes; `bin/build.sh` BUILD SUCCEEDED. Slice 2: architecture check passes and `bin/build.sh` BUILD SUCCEEDED (full `swift test` not re-run, the package change was a doc comment only). origin/main was da94896 at last fetch, already merged.

**What it is.**
- Slice 1 (5cc7da4): a real `ShelfCardDetails` adapter. `FlotsamDatabase` conforms (`ShelfPorts.swift`) through new `plainTexts(of:characterLimit:)` in `Storage/Query/CardText.swift`, one query for a screenful of ids (at most 40), reading at most `ShelfLayout.cardTextReadLimit` (1,000) characters per card. `ShelfModel` now shows `ItemRow.isMissing` (the one Missing rule, `anyExists(files:)`), so the Shelf has no Missing rule of its own and the `FileSystemPort` filtering added earlier is gone from the model. A failed text read is reported through `ShelfEffects.report` and the card falls back to its primary line.
- Slice 2 (7eefa2b): `App/Flotsam/Shelf/ShelfPasteAdapter.swift`, an `@MainActor struct` adapting `PasteService` to `ShelfPasting`, with exhaustive static `pasteMode(_:)` and `outcome(_:)` mappers and a private `PasteHost` bridge forwarding `isPanelVisible` and `hidePanel()` to the `ShelfPasteHost`. It is not yet constructed anywhere (slice 3 wires it in `AppContainer.startLibrary`, where `PasteService` is built).

**OCs covered:** the FR-006-07 Missing and card-text behaviour (OC-S2-M1 to M4 retargeted at the shared rule via `row.isMissing`), plus the paste outcome mapping by construction (compiler-checked exhaustive switch). No other deferred OC is closed yet.

**Tests.** New `CardTextQueryTests` (Storage) and `ShelfCardDetailsTests` (Shelf, real database); `ShelfMissingTests`, `ShelfModelTests`, `ShelfModelFakes`, `ShelfFakes` updated for the new port shape.
- Mutation, slice 1: 7 mutants, 6 killed. The survivor ("query one id group at a time") survived because SQLite here accepts 40,000 bound variables; I removed the grouping and its test and documented that the query is for one screenful. That run was on the pre-simplification code, so the shipped code differs by the removal of the grouping only; it was not re-mutated.
- Mutation, slice 2: none. The adapter is two exhaustive mappers and a forwarder; there is no app test target, so it is covered by build plus review only. Said plainly: nothing proves the adapter at run time.

**FRD edits (same commit as slice 1):** FR-006-07 final sentence rewritten (card text comes from the details port, Missing from the shared row flag); section 9 assumption 7 added. Slice 2: no behaviour change, no FRD edit. **Contract edits:** none yet (no S1-ruling-changed entry touched in these slices).

**Assumptions**
- Card text is read once per load for the visible cards only, capped at 1,000 characters, and trimmed to three lines of 120 characters by the model (FR-006-07).
- A text read that fails does not block the Shelf: report it, show the primary line.
- OCs that need AppKit (panel, NSDraggingDestination, drag source, hover highlight) cannot be unit-tested because the repo has no app test target. Adding one is an architecture change, so it is surfaced, not done. Proposed split: logic in package tests, AppKit shells thin and covered by build plus review plus a manual or UI-test pass.

**Handoff for the fresh agent (slices 3 to 6; worktree `/Users/home/Documents/Development/flotsam-s2-frd006`, tree clean at 7eefa2b).** Run `git fetch origin` first; merge origin/main if moved (`Merge origin/main into s2/frd006`).
- Slice 3, panel and wiring. Create `App/Flotsam/Shelf/ShelfPanelController.swift` modeled on `App/Flotsam/Library/LibraryPanelController.swift` (the `Panel` NSPanel subclass, `HostBox` for the model-needs-host cycle, `NSVisualEffectView` + `NSHostingView`, `Unchecked<Value>` box if a key monitor is needed). Differences: `styleMask [.borderless, .nonactivatingPanel]`, `becomesKeyOnlyIfNeeded`, `canBecomeKey` follows `ShelfRevealMachine.canBecomeKey` (sticky only), level `.floating`, `[.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`. Own a `ShelfRevealMachine` and drive it: feed `send(_:at:)`, execute commands, arm ONE one-shot timer for `nextDeadline`, none while idle (FR-006-17). `ShelfPasteHost.hidePanel` sends `.pasted`; the machine's hide command does `orderOut` plus `model.didHide()`. Frame from `ShelfLayout.frame(for:in:contentExtent:menuBarIcon:)` inside the revealed screen's `visibleFrame`; slide/fade from `ShelfLayout.transition(reduceMotion:)` (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`). Global monitors only while the Shelf is enabled: `leftMouseDragged` always, `mouseMoved` only when `shelf.revealOnEdgeHover` is on; map pointer to a screen with `ShelfLayout.screenIndex(of:placement:screens:)`; "drag in progress" = drag pasteboard `changeCount` changed while a button is down. Hide on Space change, Library opening, display-set change (FR-006-04, -20). Create `App/Flotsam/Shelf/ShelfView.swift` (sections from `model.sections()`, thumbnails via `database.thumbnail(itemId:size: .grid)`, Missing badge, `ui.shelf.empty` state, context menu from `model.contextMenu(for:)`, VoiceOver per FR-006-19). In `App/Flotsam/AppContainer.swift`: build `ShelfModel(source: database, paster: ShelfPasteAdapter(service: paster), host: ..., events:, details: database, effects:)` next to `startLibrary` (line ~199 area, where `SettingsLibraryHotkeyPreferences` and `CarbonHotkeyRegistrar` are used), assign `actions.toggleShelf`, register the `SettingKeys.shortcutsToggleShelf` hotkey (mirror `App/Platform/LibraryHotkey.swift`), subscribe to `shelfEnabled`, `shelfPlacement`, `shelfRevealOnEdgeHover` (as the library hotkey does at line ~206) to send `.configure`. `StatusItemController` owns a private `item`; expose its button's screen frame for `menuBar` placement and for menu-bar-icon drops. SHF-* errors go through `reporter` to the HUD (`presenter.showHUD(message:)`). Keep the Shelf module's imports to Base, Storage, Payload, Foundation.
- Slice 4, drop destination. `NSDraggingDestination` on the panel content: hover highlight with the system accent; a drag from the Shelf itself is refused silently (no highlight, no HUD, per FR-006-12 and OC-6087); read `NSPasteboard(name: .drag)` into `ShelfDropPlanner.plan(...)` then `ShelfDropService.drop(...)`; `dropCompleted` feeds the machine (`dropHold` 1.5 s). Real-gate tests for OC-6090, 6093, 6094 as PACKAGE tests in `FlotsamShelfTests` composing real `ShelfDropService` + real `IngestActor` + real `FlotsamDatabase` + real `ClipboardCapture` with capture mode Paused or Curated and an ignored app (TextEdit): the drop must store regardless. That needs `FlotsamCapture` added to the `FlotsamShelfTests` dependencies in `Packages/FlotsamCore/Package.swift` (around line 76; `bin/check-architecture.sh` lints Sources only, so this passes, but note it in the FRD or log). Also OC-6020, 6096, 6114 as far as testable.
- Slice 5, drag-out. `ShelfDragPlanner` (copy-only, drag threshold, stacked badge with count), SHF-OS-001 HUD on failure, `shelf.dragOut` log line (card count, a bundle counts once), `.dragOutAccepted` event, `.dragging(true)` for the Shelf's own drag so slice 4 refuses it silently.
- Slice 6, remaining deferred OCs 6070, 6071, 6074, 6077, 6081, 6082 as far as testable. Any contract entry changed by an S1 ruling gets `"amended": "S1 ruling 2026-11-17"`.
- Each slice: tests first, mutation on new logic (compilable mutants, all killed; `<scratchpad>/mutate.py` takes a JSON list of {name,file,old,new} plus a swift test filter), `swift test` in `Packages/FlotsamCore`, `bin/check-architecture.sh`, `bin/build.sh`, FRD-006 edit in the same commit, commit `[FRD-006] C2b slice N: ...` with the two trailers and explicit paths, push, verify local equals origin. Known flakes: OC-7132 and `optionArrowsStepThroughSidebarFilters` (re-run alone).
- Timings and constants live in one place each: reveal timings in `ShelfRevealMachine` (dragDwell 0.3, hoverDwell 0.5, hideDelay 0.6, dropHold 1.5), geometry in `ShelfLayout`. Do not copy them into the app layer.

**Drift / observations (surfaced, not fixed):** (1) the blind contract still has one `shelf.empty` assertion at about line 400 where OC-6040 now says `ui.shelf.empty` (S1 may want a pass). (2) There is no app test target, so the AppKit half of C2b (panel, destination, source) will be covered by build and review only unless S1 approves one.

## 2026-11-17: A1 health on main 37e00b8

**Verdict: PASS.** Clean clone of `main` at 37e00b8 (detached). All four steps exit 0, 0 test failures. Both known flakes (OC-7132, `optionArrowsStepThroughSidebarFilters`) passed on the first run, so no re-run was needed. Nothing fixed; this is a health record only.

| Step | Exit | Duration | Result |
|---|---|---|---|
| `bin/bootstrap.sh` | 0 | 5 s | Dependencies resolved (GRDB 7.12.0) |
| `swift test` (in `Packages/FlotsamCore`, lint harness included) | 0 | 73 s | Swift Testing: 9 "Test run with" lines, all passed, 0 failures. Largest run 319 tests in 49 suites, 8 known issues; second run 357 tests in 46 suites, 1 known issue. XCTest bundles: 0 failures. |
| `bin/check-architecture.sh` | 0 | 1 s | "architecture checks passed" |
| `bin/build.sh` | 0 | 24 s | BUILD SUCCEEDED, 0 errors. One `warning:` line is the AppIntents metadata processor notice "Metadata extraction skipped, no AppIntents.framework dependency found", not a compiler warning. |

**Failures:** none.

**Known issues (recorded, non-failing, 9 total):** `zeroByteMain_withNonEmptyWal_walBytesSurvivePlaceKnown()` (`Adversarial372ProbeCopyTests.swift:524`), and the TASK-368 / "identifiers that contain a view or network name" lint cases in `Adversarial000Tests.swift` (lines 1003, 1016, 1032). These are the same known-issue records as on the prior A1 runs.

**Flakes:** OC-7132 passed (3.2 s). `optionArrowsStepThroughSidebarFilters` passed (0.06 s). No re-run.

**Verdict:** main @ 37e00b8 is healthy for lane A1. Bootstrap, full tests, architecture check and build all pass.

### S1 ruling on C2b slices (2026-11-17)
- KEEP 5cc7da4 (slice 1) and 7eefa2b (slice 2); no revert. Slice 1 is the single-source Missing design S1 wanted.
- O'Brien on TASK-409 (`obrien-409`) merges `origin/s2/frd006` and does slices 3–6 from the 7f64339 handoff.
- `s2/frd006` is FROZEN: no more S2 pushes. App/ Shelf belongs to TASK-409.
- S1 noted the oracle `shelf.empty` vs `ui.shelf.empty` mismatch.
- S2 next: lane B 8T (FRD-001, then FRD-003), branches merged up to main 37e00b8.

## 2026-11-17: B FRD-001 8T, part 2 (INCOMPLETE, handoff)

**Status: part 2 test code NOT started; stopped on the compaction cap. Next OC ID: OC-1056.** Branch `s2/frd001-8t` @ 190fde0, pushed. Merged `origin/main` 9fcb65c (merge commit 58a14dc); main was still 9fcb65c at the last fetch. The final full `swift test` was NOT run after the merge, so no main-SHA verdict yet.

**Counts:** `swift test --filter FRD001Contract` at 190fde0: 49 tests in 2 suites, 49 passed, 0 failed (OC-1002..1055, part 1). No part 2 tests exist yet (OC-1056..OC-1110 are all unwritten).

**Defects found:** none confirmed (nothing in part 2 has been run). Suspected, unconfirmed (needs a test): nothing clears the CAP-PRM-001 Notice or warning dot when capture resumes (OC-1081, OC-1083). Code: `ClipboardCapture.swift:210-213` (`noteReadability(.readable)` only logs a trace); the only non-test `clearNotices(code:)` caller is `App/Flotsam/AppContainer.swift:136` (screenshot watcher). Likely Major.

**Leads (code reading only, not yet confirmed by test):** L-A refuted (CAP-LIM-003 context is `members.count`, not the 500 limit). L-B refuted (CAP-LIM-001 carries `.limitBytes`). Both still need a pinning test in part 2.

**Handoff for the next agent:**
- Harness is ready (190fde0): `withRig`, `uid`, `fileName` are internal in `FRD001ContractHarness.swift`; added `ContractSourceApps.names`, `ContractPasteboard.reveal(_:)` (set contents with no `changeCount` bump) and `ContractPasteboard.writes`.
- Create `Packages/FlotsamCore/Tests/FlotsamCaptureTests/FRD001ContractPart2Tests.swift`, starting with batch 1: OC-1056 (symlink name `link.txt` preserved), OC-1057 (600 files -> one bundle with 500 members, Notice 'A copy of 600 files was trimmed to the first 500.'), OC-1058 (exactly 500 -> no LIM-003), OC-1059..1063 source resolution, OC-1064..1066 remote clipboard. Then continue to OC-1110.
- Run: `swift test --package-path Packages/FlotsamCore --filter FRD001Contract`. Commit `[FRD-001] 8T: ...` with both trailers, explicit-path `git add`, push after each batch.
- Before the final full `swift test`: `git fetch origin`, `git merge origin/main` (merge only), record the main SHA tested.

**Unreachable IDs (part 1, from the test file's Unreachable comment):** OC-1001, 1003, 1022, 1023, 1033 (need a running app: CPU profile, menu tracking, Secure Event Input, system screenshot), plus the UI halves of OC-1005..1010, 1030, 1042, 1044, 1045, 1055 (panel/hotkey/paste UI). Part 2 unreachable list not yet built.

## 2026-11-17: B FRD-003 8T, part 2 (INCOMPLETE, handoff)

**Status: stopped on the compaction cap. Next OC ID: OC-3017 (primary lines per kind), then the preview batch (OC-3057, 3058, 3060, 3061, 3062, 3105), then the paste/error batch (OC-3068 onward).** Branch `s2/frd003-8t` @ 900d9e2, pushed. Merged `origin/main` 9fcb65c (main was 9fcb65c at the last fetch); that is the main SHA tested against. Test commits: 717c74d, 40523d0, 5c16a0d, 4c5bc28, 9d51901.

**Counts (full `swift test --package-path Packages/FlotsamCore` at 900d9e2, one run):** FlotsamLibraryTests 169 tests, 16 issues. FlotsamStorageTests 373 tests, 2 issues (1 known). Capture 195, Paste 56, Base 14, Shortcuts 42, others pass. FRD-003 contract tests: 59 test functions that run, 54 pass, 5 fail (the 5 are the defects below; the D6 test is parameterized and counts 5 failing cases). Known flakes OC-7132 and optionArrowsStepThroughSidebarFilters passed. One unrelated failure: OC-4102 (FRD-004 perf, WorfFRD004StorageTests.swift:430, p95(toggle) < 100), likely load-sensitive; not re-run, not mine.

**Pass (literal oracle assertions):** OC-3008, 3009, 3010, 3011, 3012, 3013, 3018, 3020, 3022-3047 (all), 3049, 3050, 3051, 3052, 3054. OC-3049 is mutation-verified (generation guard removed turns it red).

**Fail (defects, product code untouched):**
- D3 / OC-3015, Major: Command-Down with 10,000 items stops at index 199 (200 rows loaded) and never reaches the oldest. `LibraryViewModel.swift` `jump(toLast:)` (about line 355).
- D4 / OC-3019, Major: yesterday reads "Safari · yesterday" (lowercase; oracle wants "Yesterday"); a 10-day-old item reads "last wk." where a date is wanted. `Sources/FlotsamStorage/Search/ItemSpeech.swift:22-27`.
- D6 / OC-3060 and FR-003-14, Major: `LibraryPreview.memberLimit = 10` (`LibraryPreview.swift:10`), oracle wants 20 shown then "and 5 more" for a 25-member bundle. 5 parameterized cases fail.
- NEW OC-3053 (a), Major: sidebar Types order puts Screenshots last because `SidebarEntry.entries` iterates `ItemKind.allCases` (`LibraryPresentation.swift:73-76`); oracle order is Text, Rich Text, Links, Colors, Phone Numbers, Emails, Images, Screenshots, Files, Folders, Bundles.
- NEW OC-3053 (b), Minor: Pinned at 0 is not dimmed; `isDimmed: false` hardcoded at `LibraryPresentation.swift:71`.
- D5 / OC-3020: FIXED on main, test passes. Wording mismatch for Ryan: oracle says "Original file missing", FRD and product say "Missing". FRD governs; no code change.

**Predicted, unconfirmed (tests not written):** OC-3061 (preview has no First copied or Times copied field; `LibraryPreview.fields`), OC-3105 (no tag or note rows), OC-3058 (no colour swatch, hex or rgb data).

**Handoff for the next agent:**
- Worktree `flotsam-s2-frd003-8t`, test dir `Packages/FlotsamCore/Tests/FlotsamLibraryTests/`. Helpers: `RealLibrary` (real temp DB, shipping organizer; `add`, `allRows`), `Harness`, `FakeSource`, `UncancellableDelaySource`, `ContractPNG.make`, in `Frd003ContractSupport.swift`, `LibraryFakes.swift`, `Frd003ContractSearchTests.swift`.
- OC-3017 only: write the per-kind primary-line test (text/richText 2 lines, 140 chars; link URL; colour '#1A2b3C'; phone, email; see the contract text).
- Preview file `Frd003ContractPreviewTests.swift`: `model.preview`, `awaitPreview()`, `LibraryPreview.isTruncated`, `fields`, `memberPaths`, `hiddenMemberCount`; 3057 (25,000 chars truncated, 19,000 not), 3061 (labels Kind, Source, Copied, First copied, Times copied, Times pasted, Size, Pixel size), 3062 ('q' goes to search while preview open).
- Paste/error batch: the paste-sequence fakes are in `Tests/FlotsamPasteTests/PasteFakes.swift` (internal there; copy locally). Failure codes: LIB-IO-001 (blob missing, item removed), LIB-DAT-001 (all members missing, panel stays open), LIB-OS-001. Reachable: 3068, 3069, 3071-3073, 3077-3081 (footer part), 3084, 3085, 3087, 3095, 3096, 3098, 3100-3104 (string literals from `Localizable.xcstrings`).
- Run: `swift test --package-path Packages/FlotsamCore --filter Frd003Contract`. Commit `[FRD-003] 8T: ...` with both trailers, explicit-path `git add`, push after each batch; before the final full run `git fetch origin` and `git merge origin/main`, record the SHA.

**Unreachable from the package (one-line reason each):** OC-3002 to 3007 (Spaces, hotkey, focus: need a running app), 3014 (signpost p95: needs the app), 3016 (AX layout hierarchy), 3021 (pt measurement: view-level), 3048, 3055, 3056 (perf and memory: need the app), 3059 and 3097 (network monitor: system level), 3063-3067 and 3070-3076 (real target apps and key posting), 3082 (NSDoubleLocalizedStrings launch argument), 3083 (human study), 3086 label order via VoiceOver, 3088-3090 (Full Keyboard Access, Reduce Motion, appearance), 3099 (drag), plus the view-level halves of 3057 (280 pt width), 3058 (rendering), 3060 (image fit), 3062 (click focus), and the HUD placement and 2.5 s timing in 3068, 3075, 3077, 3084, 3100-3103.

---

## 2026-11-17: A3 on `obrien-409` @ a9a3114 (TASK-409 Shelf)

**Verdict: pass, ready to merge from S2's side. No defects.** The Shelf is wired into the app: it toggles from the menu bar item, shows without taking focus, pastes a card into the frontmost app, hides on Esc, and hides when the Library opens.

Machine: macOS 26.7, Xcode 26.3, Swift 6.2.4. Fresh clone from origin, detached at a9a3114.

**A1**
| Step | Exit | Result |
|---|---|---|
| `bin/bootstrap.sh` | 0 | OK (GRDB 7.12.0) |
| `swift test` (Packages/FlotsamCore, parallel, no workarounds) | 0 | 1129 Swift Testing tests in 151 suites, 0 failed, 9 known issues (KNOWN TASK-368 x2, "identifiers that contain a view or network name", and the existing adversarial pins). XCTest bundle: 18 tests, 0 failures. About 80 s. |
| `bin/check-architecture.sh` | 0 | architecture checks passed |
| `bin/build.sh` | 0 | **BUILD SUCCEEDED**. The only `warning:` line is the AppIntents metadata skip; 0 compiler warnings. |

Known flakes (OC-7132, `optionArrowsStepThroughSidebarFilters`) did not fail, so no isolated re-run was needed.

**A2 + Shelf checks** (Debug app, driven by System Events and a CGEvent double-click helper; screenshots in the S2 scratchpad as `a3-*.png`)
- **a. Launch, menu bar item, no crash: pass.** `Flotsam` item present at `menu bar item 1 of menu bar 1`, process stayed up for the whole run, clean quit through the menu item. Screenshot `a3-01-launch-desktop.png`.
- **b. Generic smoke: pass.** Two test strings captured ("A3-SMOKE-1 hello shelf", "A3-SMOKE-2 second card"); both rows are in the isolated database; the Library opened from the menu bar and listed both (`a3-02-library.png`).
- **c. Shelf toggled from the menu bar appears and does not steal focus: pass.** TextEdit stayed the frontmost app with its text area focused while the Shelf was up (`a3-04-shelf-shown.png`, `a3-06-shelf-shown2.png`).
- **d. Paste a Shelf card into a new untitled TextEdit doc: pass.** A single click only selects the card (`a3-05-after-paste.png`, no text inserted); a double-click pastes. The new doc then read "A3-SMOKE-2 second card" (`a3-05b-after-dblclick.png`). The Accessibility grant was present, so paste-back was not blocked. The doc was read through System Events AX, not Apple Events: the first Apple Events call to TextEdit raised a new Automation prompt, which was deliberately not granted. The doc was closed with Delete in the "keep this new document" sheet (never saved; `a3-10b-close-sheet.png`, `a3-11-textedit-closed.png`; TextEdit has 0 windows). No other TextEdit doc was touched.
- **e. Esc hides the Shelf: pass** (`a3-07-after-esc.png`). A control run with no Esc left the Shelf up for the full 7 s (`a3-08-ctrl-t1.png`, `a3-08-ctrl-t7.png`), so the hide is the Esc and not a timeout.
- **f. Opening the Library hides the Shelf: pass** (`a3-09-library-with-shelf.png`).
- **g. Crash logs: pass.** No `Flotsam*` files in `~/Library/Logs/DiagnosticReports` or `/Library/Logs/DiagnosticReports` (none before the launch either). `log show` for process Flotsam, last 30 min: 0 faults, 0 "fatal" messages, and 8 error-level lines (below).

**Defects:** none.

**Observations (not defects)**
- error-level os_log lines during the run: 6 AppKit `-[NSWindow makeKeyWindow] called on <_NSGlassEffectWindow> which returned NO from canBecomeKeyWindow` (21:33:12 to 21:37:03, lines up with Shelf shows), 1 `com.apple.appintents` registry connection error at launch, and 1 benign ViewBridge cancel. Left for S1 to judge; the AppKit warning is consistent with the non-activating Shelf panel being asked to become key.
- Single click on a card selects, double-click pastes (matches `ShelfView`: `onTapGesture(count: 2)`).

**Data isolation.** The app has no data-folder override, so it was launched with `CFFIXED_USER_HOME` pointing at a scratch directory. The isolated database ended with exactly 2 items and `PRAGMA integrity_check` returned ok. The real database was only opened read-only: 17 items before and 17 after; nothing deleted or altered. The pasteboard was saved before the run and the capture strings went to the system pasteboard during the test. No TCC or privacy settings were changed. Scratch clone deleted; logs and screenshots kept.
