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

**Handoff for the fresh agent (slices 3 to 6; worktree `flotsam-s2-frd006` (sibling of the main checkout), tree clean at 7eefa2b).** Run `git fetch origin` first; merge origin/main if moved (`Merge origin/main into s2/frd006`).
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

**Data isolation.** The app has no data-folder override, so it was launched with `CFFIXED_USER_HOME` pointing at a scratch directory. The isolated database ended with exactly 2 items and `PRAGMA integrity_check` returned ok. The real database was only opened read-only: 17 items before and 17 after; nothing deleted or altered. The pasteboard was empty before the run (nothing to save); the capture strings went to the system pasteboard during the test and it was cleared back to empty afterwards. No TCC or privacy settings were changed. Scratch clone deleted; logs and screenshots kept.

---

## 2026-11-17: B FRD-003 8T, part 3 (paste, copy-only, error paths) on `s2/frd003-8t`

**Branch SHA:** 7baffcd (65a9448 is the paste tests; 8b3bbe9 the preview tests; 7baffcd merges main 1c87093). Main tested: **1c87093**, which already carries the TASK-410 fixes.

**Counts.** Frd003Contract: 77 tests in 6 suites in the last `--filter` run before the merge; this part added 16 (`Frd003ContractPasteTests.swift`) plus the OC-3017 row test and the 6 preview tests earlier. Full `swift test --package-path Packages/FlotsamCore` after the merge: 558 Swift Testing tests in 67 suites by the per-target run lines; the only failures are 3 tests / 6 issues (below). Known flakes OC-7132, `optionArrowsStepThroughSidebarFilters`, OC-4102 all passed this run. 9 known issues, none new.

**PASS (with the real PasteService over a real database; OS edges faked):** OC-3017, 3057, 3062, 3068/3102 (LIB-DAT-001, panel stays open, nothing written), 3069, 3071, 3072, 3073, 3077/3078/3103 (SET-PRM-001, footer "Press ⌘V to paste"), 3079, 3080, 3081 (footer half), 3084/3101 (LIB-IO-001, item removed from count and search), 3085/3104 (STO-DB-004 state, search and Esc work, Retry recovers), 3087 (100 characters), 3095 (no stored change; Times-copied half unreadable), 3096, 3098 (no OCR), 3100 (LIB-OS-001, both ways). OC-3020/D5: PASS, the FRD governs ("Missing"); the oracle text "Original file missing" is stale. After the merge of TASK-410 the earlier defects D3 OC-3015, D4 OC-3019, D6 OC-3060/FR-003-14 and OC-3053 now PASS on main.

**Mutation checks (product edited, tests went red, product restored):** recordPaste skipped (7 tests red: 3069, 3071, 3077, 3079, 3095, 3096, 3100), LIB-IO-001 delete skipped (3084 red), hidePanel skipped (3071, 3077 red), speech limit 100 to 101 (3087 red).

**Defects (still open on main, tests left failing as proof):**
| ID | Sev | Where | Evidence |
|---|---|---|---|
| OC-3058 | Major | `Packages/FlotsamCore/Sources/FlotsamLibrary/LibraryPreview.swift:44` `fields(for:)`; `App/Flotsam/Library/LibraryPreviewView.swift:19` | a colour item previews with no hex and no "26, 43, 60"; rich text renders as plain monospaced `Text`, no bold |
| OC-3061 | Major | `LibraryPreview.swift:44` | image metadata lacks "First copied" and "Times copied" (expects the 8 fields in order) |
| OC-3105 | Major | `LibraryPreview.swift:44` | no tag or note rows in the metadata block |

**Unreachable from the package:** OC-3002 to 3007 (Spaces, hotkey, focus), 3014 (signpost p95), 3016 (AX hierarchy), 3021 (pt measurement), 3048/3055/3056 (perf, memory), 3059 and 3097 (network monitor), 3063 to 3067 and 3070 to 3076 (real target apps, real key posting), 3082 (double-length localisation), 3083 (human study), 3086 (VoiceOver order), 3088 to 3090 (Full Keyboard Access, Reduce Motion, appearance), 3091 to 3094 and 3099 (drag: need a real drag session). View-level halves of 3057 (280 pt), 3058 (rendering), 3060 (image fit), 3062 (click focus). HUD placement and 2.5 s timing in 3068, 3075, 3077, 3084, 3100 to 3103. "Times copied" half of OC-3095 (no public read API; copyCount is not exposed). OC-4102 left alone per S1.

**Note:** the oracle writes "120 x 80" in ASCII where the product shows "×"; normalised in the test, not a defect.

## 2026-11-17: B FRD-001 8T, part 2 on `s2/frd001-8t` (INCOMPLETE: stopped on the compaction cap, handoff)

**Branch SHA:** 3bf08ef (merge of main 1c87093 into de23097; test commits b70f53a, b37e4c1, 9142dbf, de23097). Main tested against: **1c87093**. Pushed.

**Status.** All of OC-1056..OC-1110 that are reachable from the package now have tests. Open work for the next agent, in this order: (1) mutation checks for batch 3b (OC-1088, 1091, 1092/1110, 1093, 1094, 1095, 1097, 1100..1106 were never mutated; batches 1 to 3a were, M1..M9 all went red); (2) make OC-1087 and OC-1088 robust under parallel load (see Flake); (3) re-run the full suite and record the result. **Next OC ID for the mutation pass: OC-1088.**

**Counts.** `swift test --filter FRD001` (before the merge): 100 tests in 8 suites (49 part 1, 51 part 2), 6 issues, all in the 3 tests below that pin defects. Full `swift test` after the merge, one run: failures outside my files are OC-7002 (StorageConcurrency), OC-408-W12 and GapPollingTests (OC-115-02), all timing tests under parallel load; I did not re-run them in isolation and did not compare against main. Inside my file the full run also failed OC-1087 and OC-1088 (see Flake).

**PASS (literal oracle assertions, real DB, faked OS seams):** OC-1056..1075, 1076, 1077, 1078, 1080, 1082, 1085 (Curated half), 1087, 1088, 1091, 1093 (sink half), 1094, 1095, 1097, 1098, 1099, 1100..1106, 1107, 1109 (1087 and 1088 pass in isolation, see Flake).

**FAIL (defects, product untouched, tests left red as proof):**
| ID | Sev | Where | Evidence |
|---|---|---|---|
| OC-1081, OC-1083 | Major | `Sources/FlotsamCapture/ClipboardCapture.swift` `noteReadability(.readable)` (about lines 205-215) | After suspension and resume the copy IS stored, but the CAP-PRM-001 Notice and the warning dot never clear (`latestNotices` non-empty). The only non-test `clearNotices(code:)` caller is `App/Flotsam/AppContainer.swift:136` (screenshot watcher). Fix: `reporter.clearNotices(code: .capPrm001)` on resume, plus the FRD edit, same commit. |
| OC-1110 (and the CAP-IO-001 half of OC-1092) | Major | `Sources/FlotsamBase/Errors/ErrorCode.swift:40` declares `capIo001`; no other file in Sources references it | With the DB refusing writes (`PRAGMA query_only = ON`) nothing is stored and an STO-* code surfaces (OC-1092's "or an STO-* code" branch passes), but the CAP-IO-001 message "Flotsam couldn't save a copy. The disk may be full or its data folder unreadable." is never shown and no error-level CAP-IO-001 record is logged. Recovery after `query_only = OFF` works. |
| OC-1084 | Major (code reading, no test possible) | `Sources/FlotsamCapture` | Nothing raises CAP-PRM-001 at launch when the system pasteboard access is not Allow; `PasteboardAccess` feeds onboarding only. |

**Leads:** L-A refuted (CAP-LIM-003 context is `members.count`; pinned by OC-1078). L-B refuted (CAP-LIM-001 Notice carries "over 10 MB" / "over 100 MB"; dropping `.limitBytes` turns OC-1076 and OC-1078 red).

**Minor (Rule 9):** the literal "Another device" is duplicated in `SourceApp.anotherDeviceName` and the catalogue key `ui.source.remoteDevice`. They agree today; a change to one must change the other.

**Mutation checks done (product edited, mapped tests red, product reverted):** M1..M9 over IngestLimits.swift, ClipboardCapture.swift and SettingValues.swift (batches 1 to 3a). None for batch 3b.

**Flake (mine, to fix).** OC-1087 (0.9 s window after resume) and OC-1088 (50 copies, 0.75 s each, real timer) pass alone and failed once in the full parallel run. They measure real-timer latency, so CPU load from the other suites widens them. Remediation: keep the 0.6 s contract bound but measure against the capture's own poll count or widen the load margin, and say so in the test comment. Not done.

**Unreachable from the package (reasons are in the test file's trailing comment):** OC-1079, 1089, 1090 (performance, memory, signposts need the app); OC-1084 (no seam, defect above); the Save Clipboard halves of OC-1085/1086 (`saveClipboard` at `AppContainer.swift:222` is a UI entry point, never assigned); OC-1096 (network monitor); the `log show` half of OC-1093; UI halves of OC-1059, 1064, 1069, 1070, 1077, 1100..1107 (rows, preview, menu-bar icon, HUD pixels, Data's 8V).

**Verdict:** FAIL (3 Major defects open). L-A refuted, L-B refuted. Confidence: Moderate (batch 3b has not been mutation-checked, and one full run showed load flakes).

## 2026-11-17: A2 + Shelf re-smoke on main 1c87093

**Verdict: FAIL (1 Major defect: the Toggle Shelf hotkey toggles the Library instead).** Clean clone at 1c87093, `bin/bootstrap.sh`, `bin/build.sh Debug`: both succeeded. Launched with `CFFIXED_USER_HOME` on a scratch home.

**A2 launch smoke**
- a. Build and launch: PASS.
- b. Menu bar item present: PASS. Items: Open Library, Save Clipboard, Toggle Shelf, Pause Capture, Notices, Settings, Show Setup Guide, Quit Flotsam.
- c. Quit cleanly via the menu: PASS (process gone within 3 s).
- d. Crash logs `~/Library/Logs/DiagnosticReports/Flotsam*`: none before, none after. `log show` faults for process Flotsam: none.

**Shelf re-smoke**
- a1. Hotkey, Library open: FAIL. There is no default Shelf hotkey (`shortcuts.toggleShelf` defaults to `ChordBinding.none`, Settings.swift:49), so the brief's "default" does not exist. Bound for the test to ctrl+cmd+B via a launch argument (`-shortcuts.toggleShelf 11:3`, never written to disk); the menu item showed the chord. Pressing it with the Library open hid the Library and showed NO Shelf; with the Library closed it OPENED the Library; ctrl+cmd+V (Library chord) also toggled the Library. Window lists via System Events AX: B from closed gave the Library window (760x480), V closed it, B opened it again. No `shelf.reveal` line for any hotkey press.
- a2. Menu item "Toggle Shelf" (trigger menuItem): PASS. Shelf window (280x160 at the right edge) appeared and the Library window was gone from the AX window list (one-panel rule holds on this path).
- a3. Reverse (Shelf up, then Open Library): PASS. Only the Library window remained.
- b. `shelf.reveal` log (menu path): PASS. Quote: `[io.github.heilo27.Flotsam:shelf] shelf.reveal outcome=revealed trigger=menuItem <private>` at 21:49:50.666 and 21:50:04.445. Hotkey path: no line, because the Shelf never revealed.
- c. TASK-411 warning (`makeKeyWindow called on _NSGlassEffectWindow`): 3 in this launch (21:47:38.548, 21:47:44.363, 21:50:06.228). Each coincided with a menu-bar menu open or the Open Library click, not with a Shelf show (Shelf shows were at 21:49:50 and 21:50:04 with no warning within 1.5 s). Observed only.
- d. Esc hides the Shelf: PASS (AX window list empty 1.5 s after Esc).

**Defects**
1. Major. Hotkey collision between the two `CarbonHotkeyRegistrar` instances. `App/Flotsam/AppContainer.swift:197` (Shelf) and `:260` (Library) each create their own registrar. `App/Platform/CarbonHotkeyRegistrar.swift:14,16,23` gives every instance the same signature "FLTS" and ids starting at 1, and each installs its own application-level event handler (`:65`) that looks the pressed id up in its own `entries`. The Shelf chord (id 1) is therefore delivered to the Library registrar's handler, which finds ITS id 1, runs the Library toggle and returns noErr. Matches the observed behaviour exactly. Fix direction: one shared registrar, or distinct ids/signatures. (Read from source plus the black-box behaviour above; I did not add logging to confirm the dispatch order.)
2. Minor (spec vs brief). Toggle Shelf has no default chord; FR-006-03c says "unbound by default", so this is as designed, but the A2/Shelf brief should not expect a default.

**Observations (not defects):** the Library chord toggles (open/close) with ctrl+cmd+V; System Events `keystroke` went to TextEdit (frontmost) while the Carbon hotkeys still fired system-wide.

**Data isolation.** Real DB opened read-only before and after: 17 items both times, not written. Pasteboard saved and restored (was an empty string; 0 bytes after). No TCC prompts. TextEdit not touched. DISCLOSURE: one `defaults write` with `CFFIXED_USER_HOME` set landed in the REAL prefs domain `io.github.heilo27.Flotsam` (key `shortcuts.toggleShelf`); noticed at once and removed with `defaults delete`. Real prefs now again hold only `onboarding.completed` and `settings.lastPane`. The prefs plist mtime changed; the DB did not. Scratch clone deleted; logs and screenshots kept in the session scratchpad.

## 2026-11-17: B FRD-001 8T, part 2 (completion of the handoff above): mutation pass, flake hardening, isolation reruns, full run

Branch `s2/frd001-8t` @ 2d580ef (pushed; tests only, no product code touched). **Verdict: batch 3b mutation-checked; 2 fake tests found and fixed; the 3 Major defects from the entry above are still open and still pinned red.**

**Mutation results (product edited, mapped test red, product reverted with `git checkout`, tree clean after each):**
- OC-1088 (poll 1.0 s, poll 0.65 s), OC-1087 (poll 1.0 s): red. OC-1087 stays green at 0.65 s (one sample, 0.1 s after resume; the timer phase can land inside the bound); OC-1088 (50 samples) catches 0.65 s.
- OC-1091 (CAP-OS-001 failure path invalidates the timer): was SURVIVING, now red (see fixes).
- OC-1092/1110 (CAP-IO-001 severity to error): red.
- OC-1093 (a leak of classified text into the log through `FlotsamLog.trace`), OC-1094, OC-1095, OC-1097, OC-1100..1103, OC-1105: red under their mutations (logs for each: round 1 and 2 of the pass; mutations M1..M25 across ClipboardCapture, IngestWorker, ErrorCode, LogEvent, OwnWriteLedger, CaptureClassifier).
- OC-1104 (delete the ledger guard; delete the marker guard): were SURVIVING, now red.
- OC-1106 (CAP-DAT-001 severity to error): red.

**Fake tests found and fixed (P1 per doctrine, test-only fixes):**
1. OC-1091: the "the timer kept running after a failed read" claim called `rig.process()`, which stops and restarts the timer, so a failure path that killed the timer survived (M11b). Removed the `process()`; the real timer now has to hit the failure and then pick up the next copy by itself. M11b rerun: red.
2. OC-1104: each own-write guard (ledger, marker) was only tested together via `ledger.write`, so deleting either alone stayed green (M23a, M23b). New test `oc1104EachGuard`: marker-only (marker type present, not in ledger) and ledger-only (recorded count, marker types swapped out with `reveal`). Both mutations rerun: red.

**OC-1087 / OC-1088 hardening.** They timed write -> stored on the real 0.5 s timer and flaked once under full load. Now they measure write -> first type-list read by the capture (a timestamp in the `ContractPasteboard` fake), which is the detection latency the oracle bounds at 0.6 s, so ingest and the test's own DB polling are out of the margin. Samples taken while the main actor was starved (a 20 ms sleep overrunning by more than 0.1 s) are excluded and retaken; OC-1088 needs at least 35 of 50 clean samples and OC-1087 fails if 5 attempts are all starved, so neither can pass on nothing. Bound stays 0.6 s; item count 50 and one item per text are still asserted. Not weakened: a 1.0 s poll still turns both red.

**Isolation reruns at this HEAD (note: `swift test --filter "OC-xxxx"` matches nothing, display names are not matched, and exits 0 with zero tests; I used suite and function names and checked the test counts):**
- OC-7002: `oc7002_leftoverTmpIsEmptiedAtLaunch` 1 test pass; `StorageConcurrencyTests` (the four other OC-7002 tests) 5 tests pass.
- OC-408-W12 (`emptySnapshotNeverResets`): pass in isolation.
- GapPollingTests (OC-115-02): 4 tests pass.
- None failed in isolation, so no clean-main-1c87093 checkout was needed.

**Full `swift test` at 2d580ef (one run, counted by grep on the log):** 956 swift-testing tests passed, 4 failed (distinct names). The 4: the three intentional defect pins (OC-1081, OC-1083, OC-1092/1110 CAP-IO half) and OC-408-W12 (`rig.board.snapshotReads == 3` at ClipboardEmptyReadWorf408Tests.swift:320, 1.1 s under full load). OC-7132, optionArrowsStepThroughSidebarFilters and OC-4102 did not fail in this run. Known issues reported by Swift Testing: 1 and 8 (expected-failure annotations).

**OC-408-W12 triage (cause NOT confirmed).** The test file and `Sources/FlotsamCapture` are byte-identical between main 1c87093 and this branch (`git diff 1c87093 HEAD` on both is empty), so this branch did not cause it. It passes in isolation and passed 6 of 6 under a 2x-core CPU burn, so I could not reproduce it. Hypothesis, unproven: the test starts the real 0.5 s timer and awaits `drain()` between ticks, and its file header says no suspension point lets the timer interleave; under heavy full-suite load an extra timer read would make `snapshotReads` 4. Treat as a pre-existing load flake of TASK-408's test; fix is for its owner (replace `capture.start()` with a timer-free rig, or assert `>= 3`).

**Not done:** no run on a clean main checkout (not needed per the brief's rule); OC-1089/1090/1079/1084 still unreachable from the package; the three Major defects above are product bugs for S1 and are untouched.

**Addendum (Rule 0 correction to the entry above).** The pre-hardening OC-1087 stayed green under the 1.0 s poll mutation (queue 1 shows only OC-1088 red), so the old OC-1087 was a third surviving mutation, not only a flake. The hardened OC-1087 goes red at 1.0 s (rerun above); at 0.65 s only OC-1088 goes red. Also: M12 (text leak) did not compile in round 1; the red result for OC-1093 is from the rewritten M12 in round 2.

---

## 2026-11-17: A1 + A4 on `main` @ 7948739 and 42cb847

Toolchain on this run: macOS 27.3, Xcode 27.0 (27A266a), Apple Swift 6.4 (the header above is stale: it says 26.7 / 26.3 / 6.2.4). M1 Max. A1 was run at 7948739 first; `main` then moved to 42cb847 (FRD-005 merge), so A1 was run again there and A4 was run on the 42cb847 Debug build only.

**A1 (clean clone per SHA in the session scratchpad, deleted afterwards; logs kept). Verdict: PASS at both SHAs, 0 failures.**

| Step | 7948739 | 42cb847 |
|---|---|---|
| `bin/bootstrap.sh` | exit 0, 4 s | exit 0, 5 s |
| `swift test` (Packages/FlotsamCore, no scratch path, so the lint harness ran) | exit 0, 82 s incl. build | exit 0, 89 s incl. build |
| `bin/check-architecture.sh` | exit 0, 1 s ("architecture checks passed") | exit 0, 1 s |
| `bin/build.sh` (Debug, unsigned) | exit 0, 24 s, BUILD SUCCEEDED | exit 0, 25 s, BUILD SUCCEEDED |
| Swift Testing, sum of every "Test run with N tests" line | 1312 tests in 10 runs, all passed | 1612 tests in 11 runs, all passed |
| XCTest "Executed" (FlotsamCaptureTests only) | 18, 0 failures | 18, 0 failures |
| Failures (`✘` lines) | 0 | 0 |
| Known issues | 9 (1 + 8) | 10 (1 + 1 + 8) |

- Counting method: ANSI codes stripped, then `grep "Test run with"` and a sum; failures by `grep -c "^✘"`; known issues by `grep -c "recorded a known issue"`, which matches the per-run "with N known issue(s)" totals.
- Against S1's figures: at 42cb847 my sum is 1612, equal to S1's 1612. At 7948739 I count 1312, S1 reported 1310. The difference is 2; I did not find out why (two runs are single-test runs, "1 test in 1 suite"). Counted, not explained.
- Known issues are all pre-existing pins: `Adversarial372ProbeCopyTests.swift:524` (zero-byte main with non-empty WAL), `Adversarial000Tests.swift:1003` and `:1016` (TASK-368 regex/division lint), `:1032` (identifier lint).
- Known flakes OC-7132, `optionArrowsStepThroughSidebarFilters`, OC-4102, OC-408-W12 all passed in the full run at both SHAs, so no single re-run was needed. LintHarnessTests passed (18.4 s and 20.9 s).
- Load at A1 start was about 8.4 (other sessions on the machine), and `swift test` itself drove 1-min load to 83 at the end of the first run.
- Warnings: 4 distinct compiler warnings in the test targets at both SHAs (unused result): `Frd003ContractPasteTests.swift:493`, `ShelfDropServiceTests.swift:524`, `:526`, `:536`. The app build has no compiler warnings (one `appintentsmetadataprocessor` note about no AppIntents.framework). The cross-project rule is zero warnings, so the test warnings are a defect to ticket. Not fixed.

**A4 idle profile, TASK-116: 42cb847 Debug build (Debug, not Release; the lane says the same build)**

| Budget line | Budget | Measured | Verdict |
|---|---|---|---|
| Idle CPU, mean over 10 min | at most 0.2 % of one core | 0.0845 % (0.509 s CPU in 603 s) in window 2; 0.083 % (0.51 s in 602 s) in window 1 | PASS |
| Wakeups | at most 2.5 /s | 2.109 /s (1272 interrupt wakeups in 603 s); max 23 in any 10 s bucket (2.3 /s); the 10 s buckets were 20 to 23 | PASS (0.39 /s headroom) |
| Resident memory | at most 60 MB | RSS 89.7 MB (ps) / 87.6 MB (`ri_resident_size`), flat between 89.68 and 89.76 MB across 20 min; end footprint 23.0 MB | FAIL on RSS; the physical footprint is 23 MB |

Method:
- Process: the Debug binary launched directly, `CFFIXED_USER_HOME` pointing at a scratch home, capture on (default). Load at start 1.69 (1-min, 22:23:23), 1.79 at the end of window 1, 1.73 at the end of window 2; no swift/xcodebuild process running of mine (an idle sourcekitd service and someone's `cp` were on the box). Waited from load 83 to under 2 first.
- Settle: 55 s after launch (footprint and ps taken then), then window 1: 10 min hands-off, `top -l 62 -s 10 -pid <PID> -stats pid,cpu,idlew,mem,rsize` plus `ps -o rss=,cputime=` every 10 s.
- CPU: delta of `ps cputime` (10 ms resolution) divided by wall time, and, in window 2, `proc_pid_rusage` (`ri_user_time + ri_system_time`, converted with mach_timebase) divided by wall time. `top` showed 0.0 % in every one of 61 samples.
- Wakeups: window 1 `top` IDLEW is cumulative package-idle wakeups: 20 at 22:24:24 to 278 at 22:34:41, so 258 in 617 s = 0.42 /s. That column only counts wakeups that brought the core out of idle, so it undercounts (a 0.5 s timer alone is 2 /s). Window 2 (22:36 to 22:46, hands-off) therefore read `ri_interrupt_wkups` through `proc_pid_rusage` (RUSAGE_INFO_V4) every 10 s: 1571 to 2843 over 603 s = 2.109 /s. The package-idle counter in the same window gave 185 in 603 s = 0.307 /s. The number to compare with the budget is the interrupt one. Cumulative since launch (714 s, launch burst included) was 1561, 2.19 /s.
- Memory: `ps -o rss` and `ri_resident_size` for resident, `footprint <PID>` and `vmmap --summary` for physical footprint (23 MB at start, 23.0 MB at end, peak 23.3 MB). `top`'s mem and rsize columns both printed 23M (the footprint), so I did not use `top` for RSS.
- Wakeup source: not traced. The budget lines pass, so no `xctrace` trace was taken. The roughly 2.0 /s is consistent with the 0.5 s pasteboard poll timer in FRD-001 (AC-001-01); that is an inference, not a measured attribution, and about 0.1 /s is unattributed.
- RSS fail diagnosis (`vmmap --summary`): private dirty is 23 MB (Malloc Small 13 MB, `__DATA` 2.8 MB, `__DATA_DIRTY` 2.3 MB, malloc metadata 1.1 MB), and 18 MB is clean mapped file. The other roughly 65 MB of resident size is clean pages of the system libraries mapped from the shared cache (`__TEXT`, `__OBJC_RO`, `__AUTH_CONST`, `__DATA_CONST`), which are shared with other processes and are not heap. I did not attribute them per framework, and I did not measure a Release build. The FRD does not say whether "resident" means RSS or footprint. By RSS the line fails; by footprint it passes with 37 MB of headroom. Needs a decision from S1 / Ryan on which definition the budget uses.
- The pasteboard (one `public.utf8-plain-text` item, 0 bytes) was saved before and compared after: identical items, changeCount 68 before and after, so the app and I never touched it and no restore was needed.
- Not done: capture latency and the 50k-item search latency (the other two A4 bullets, not in this brief); the Edit-menu-held-open check; a Time Profiler trace; a Release-build profile. Onboarding state was not observed (no screenshot and no AX). I did not see a plist land in the scratch home's Library/Preferences, and the real prefs plist hash is unchanged, so I do not know which domain the app read its settings from.
- Quit: the app was stopped with SIGTERM (a menu quit needs AX or an Automation grant, and I made no TCC grant). Exit was clean to the shell; the scratch database holds 0 items and I did not run `integrity_check` on it. No DiagnosticReports entry for Flotsam.

**Data isolation.** `lsof` showed the app opening only the scratch home's `Application Support/Flotsam`, 0 handles on the real folder. Real DB opened read-only before and after: 17 items both times; `flotsam.sqlite` and `-wal` have identical size, mtime and sha1 before and after (`-shm` excluded, readers touch it). The real prefs plist `io.github.heilo27.Flotsam.plist` has the same sha1 before and after. No `defaults write` was used. Scratch clones deleted; logs kept in the scratchpad.

**Defects / follow-ups for S1:**
1. A4 RSS 89.7 MB against the 60 MB line (see above); decide the definition, and re-measure on a Release build.
2. Four unused-result warnings in test targets (list above).
3. The `S2-LOG.md` header toolchain line is stale.

---

## 2026-11-17: A1, A2, hotkey re-test (TASK-416) and 10k A4 on `main` @ 7632f6f

Contains 614f9fe and 4cf4a91 (checked with `git merge-base --is-ancestor`). Toolchain: macOS 27.3, Xcode 27.0, Apple Swift 6.4, M1 Max. Clean clone in the session scratchpad. **Verdict: A1 PASS, A2 PASS, hotkey re-test PASS, A4 CPU and wake-ups PASS (Release and Debug, 10k items). Memory lines are numbers only, per S1's scope change.**

**A1**

| Step | Result |
|---|---|
| `bin/bootstrap.sh` | exit 0, 5 s |
| `swift test` (Packages/FlotsamCore) | exit 0, 111 s incl. build (load was 2.13 at start, about 25 at the end of the run) |
| `bin/check-architecture.sh` | exit 0, 2 s, "architecture checks passed" |
| `bin/build.sh` (Debug) | exit 0, 25 s, BUILD SUCCEEDED |
| Release build for A4 (`xcodebuild`, own derived-data path) | exit 0, 64 s, BUILD SUCCEEDED |
| Swift Testing, sum of every "Test run with N tests" line | 1736 tests in 11 runs, all passed |
| XCTest "Executed" (FlotsamCaptureTests) | 18, 0 failures |
| Failures (`✘` lines) | 0 |
| Known issues | 9 (1 + 8) |

- Counting method as in the previous A1 entry (ANSI stripped, `grep "Test run with"`, sum of the test count field; `grep -c "^✘"`; `grep -c "recorded a known issue"`).
- The known flakes (OC-7132, optionArrowsStepThroughSidebarFilters, OC-4102, OC-408-W12) did not fail, so no single re-run was needed.

**A2 launch smoke (Debug build, scratch `CFFIXED_USER_HOME`, no TCC grants)**

| Check | Result |
|---|---|
| Build and launch | PASS |
| Menu bar item (read through AX, process menu bar 1) | PASS: Open Library, Save Clipboard, Toggle Shelf, Pause Capture, Notices, Settings..., Show Setup Guide..., Quit Flotsam |
| Quit via the menu item | PASS, process gone within 2 s |
| `~/Library/Logs/DiagnosticReports/Flotsam*` | none |
| `log show` faults for process Flotsam (10 min window) | none |
| Scratch DB after the run | `integrity_check` ok, 0 items |

**Hotkey re-test (TASK-416 fix 4cf4a91)**

The Shelf hotkey was bound only through the launch argument `-shortcuts.toggleShelf 11:3` (ctrl+cmd+B; NSArgumentDomain, nothing persisted). No `defaults write`. The Library hotkey was the default ctrl+cmd+V. A separate helper process (own Carbon hotkey ctrl+opt+cmd+K, signature `FLTS`, id 1, the same signature and id the app's registrars use) stood in for a non-Flotsam global shortcut. Keys were sent with System Events `key code`. Two passes over the whole sequence; the log came from `log stream` plus `log show` for process Flotsam (a first stream attempt in pass 1 captured nothing because of a shell mistake; `log show` recovered pass 1's `shelf.reveal` line).

| Press | Expected | Observed (both passes) | Result |
|---|---|---|---|
| ctrl+cmd+B | only the Shelf | one window, 280x160 (Shelf size); `shelf.reveal outcome=revealed trigger=hotkey` logged at 23:22:45 and 23:23:09; no 760x480 window | PASS |
| ctrl+cmd+B again | Shelf hides | no window | PASS |
| ctrl+cmd+V | only the Library | one window, 760x480 (Library size); no `shelf.reveal` line at 23:22:49 or 23:23:14 | PASS |
| ctrl+cmd+V again | Library hides | no window | PASS |
| ctrl+opt+cmd+K | foreign shortcut fires in its own process | `FOREIGN_HOTKEY_FIRED id=1` after each press (2 of 2), with both Flotsam hotkeys bound | PASS |

Limits: the Library action writes no log line, so "Library fired" rests on the window appearing at the Library's size, not on a log entry. The window sizes are identifying only by size; I did not read the panel titles. The foreign check proves a hotkey in another process is not swallowed while Flotsam holds two; it does not test another process that reuses the id 1 / `FLTS` pair with a different key beyond the helper itself (the helper did use that pair).

**A4 idle profile, seeded 10k library (S1 scope change)**

Seed: a throwaway database in a scratch `CFFIXED_USER_HOME`, 10,000 items, FRD-007 mix (5200 text, 1200 link, 2000 image, 600 file, 300 color, 300 email, 200 phone, 200 richText) within the 30-day retention window, schema v1, 2,000 generated synthetic JPEG blobs (1280x800, 20 variants). `integrity_check` ok. The app (Release) showed "All 10,000" and "10000 items". The thumbnail cache stayed empty (the library was not scrolled), so a full thumbnail cache is not covered.

Method: 55 s settle after launch, then 10 min hands-off, sampling every 10 s. CPU is the delta of `ri_user_time + ri_system_time` and wake-ups the delta of `ri_interrupt_wkups`, both from `proc_pid_rusage` (RUSAGE_INFO_V4, mach_timebase converted). RSS is `ri_resident_size`; footprint is `ri_phys_footprint` (exact bytes below; `footprint` prints whole MB only).

| Build | Load at start | CPU, mean over 10 min (budget 0.2 %) | Wake-ups (budget 2.5 /s) | RSS at settle | Footprint at settle | RSS / footprint at end |
|---|---|---|---|---|---|---|
| Release | 1.987 (end 1.729) | 0.0806 % PASS | 2.139 /s PASS | 102,252,544 B (97.5 MiB) | 23,708,512 B (22.6 MiB) | 102,219,776 / 23,675,744 B |
| Debug | 1.934 (end 2.826) | 0.0836 % PASS | 2.117 /s PASS | 104,120,320 B (99.3 MiB) | 24,183,672 B (23.1 MiB) | 104,087,552 / 24,167,264 B |

- The Debug window ended at load 2.826, above the load-under-2 rule (another session started work on the machine); the start was under 2.
- Memory against the 60 MB line: no verdict given, as instructed. By RSS both builds are about 98-99 MiB; by footprint both are about 23 MiB.

**10k, Library panel open (budget 150 MB, numbers only)**: panel opened with the default Library hotkey (ctrl+cmd+V), read 30 s and 60 s later.

| Build | RSS +30 s | Footprint +30 s | RSS +60 s | Footprint +60 s |
|---|---|---|---|---|
| Release | 117,129,216 B (111.7 MiB) | 33,571,704 B (32.0 MiB) | 117,096,448 B | 33,538,936 B |
| Debug | 118,784,000 B (113.3 MiB) | 33,915,768 B (32.3 MiB) | 118,800,384 B | 33,932,152 B |

**Capture latency and 50k-item search latency: no harness.** No benchmark or Instruments harness exists in the repo for these (FRD-007 FR-007-16 names the 10k / 2,000-image release case; AC-003-09 sets the p95 at most 100 ms search at 10k). I did not build an ad-hoc one. The Debug in-suite tests OC-7131 and OC-7140 ran and passed in A1 (10k items, not 50k). Capture persist latency in a running app was not measured.

**Data isolation.** Real DB, read-only before and after: 17 items both times; `flotsam.sqlite` sha1 03fc64cf... and `-wal` sha1 c1189741... identical before and after; real prefs plist sha1 c190d732... identical before and after. No `defaults write`; no plist appeared in any scratch home's Library/Preferences. All launches used a scratch `CFFIXED_USER_HOME`. Pasteboard: I never wrote to it. `clipboard info` before and after is identical (utf8 and utf16 text, 2 bytes); I compared the type listing only, not a content hash, and the app only reads the pasteboard in these homes. No restore was needed. Nothing was added to TCC. The measurement apps were stopped by SIGTERM and the A2 app by its menu Quit.

**Not done / unknown:** capture latency, 50k search, a full thumbnail cache, a scrolled Library, a Release-build smoke beyond the idle and panel runs, panel titles for the hotkey check, and attribution of the roughly 75 MiB gap between RSS and footprint (not traced).

**Defects / follow-ups for S1:** none found at 7632f6f. Observation: the Library open/close action emits no log line, which limits log-based hotkey verification to the Shelf.

---

## 2026-11-17: A4 idle wake-up measurement on `obrien-381` @ e623370 (Debug, 10k library)

Numbers only, no verdict, as requested. The branch tip had moved on to fa91379 when I cloned it, so I checked out e623370 explicitly (a fresh clone, `bin/bootstrap.sh` exit 0, `bin/build.sh Debug` exit 0, 21 s, BUILD SUCCEEDED). The same seeded 10,000-item scratch home as the 7632f6f entry (`integrity_check` ok, 10,000 items before and after). No arguments, capture on (default).

| Measure | Value |
|---|---|
| Load (1-min) at start | 1.966 (23:27:55); at the end of the window 8.01 (other sessions started work) |
| Settle | 55 s |
| Window | 600.4 s hands-off, sampled every 10 s |
| Wake-ups, `ri_interrupt_wkups` delta (`proc_pid_rusage` RUSAGE_INFO_V4) | 1210 in 600.4 s = **2.015 /s**; every 10 s bucket between 19 and 21 |
| Package-idle wake-ups, same window (undercounts) | 150 = 0.25 /s |
| CPU, `ri_user_time + ri_system_time` delta | 0.440 s in 600.4 s = **0.0733 %** of one core |
| RSS at settle and at end | 103,956,480 B (99.1 MiB), unchanged |
| Footprint (`ri_phys_footprint`) at settle and at end | 24,036,192 B (22.9 MiB), unchanged |

Reference figure from S1: 2.71 to 2.90 /s before, target about 2.0 /s. Measured on this Mac and library, not comparable with S1's machine beyond what the method gives. The elevated load at the end of the window is disclosed; the wake-up count in every bucket stayed 19 to 21, so I saw no sign it moved the result, but I did not test that.

Not done: no Release build of this branch, no panel-open case, no attribution of the wake-ups by source (not traced).

**Data isolation.** Real DB (read-only) before and after: 17 items; `flotsam.sqlite` sha1 03fc64cf... and `-wal` sha1 c1189741... identical; real prefs plist sha1 c190d732... identical. No `defaults write`. No plist in the scratch home's Library/Preferences. The app ran only with a scratch `CFFIXED_USER_HOME`. `clipboard info` identical before and after (utf8 and utf16 text, 2 bytes; type listing compared, not a content hash); I never wrote to the pasteboard, so no restore was needed. No TCC grants. No DiagnosticReports entry for Flotsam. The app was stopped by SIGTERM and no Flotsam process remains. The clones, builds and scratch homes were deleted afterwards.

**Defects / follow-ups for S1:** none from this run.

---

## 2026-11-17: FRD-001 and FRD-003 contract re-verification on df9bf09, plus FRD-003 gap tests (`s2/frd003-8t-gap` @ 82bbf7d)

Tests only; no `Sources/` change. One new file: `Tests/FlotsamLibraryTests/Frd003ContractGapTests.swift` (14 tests, all pass on first run).

| FRD | IDs | PASS | FAIL | No runtime test |
|---|---|---|---|---|
| 001 | 110 | 99 | 0 | 11: OC-1007 (gap, not written as briefed) + 10 comment-only "no seam" (1001, 1003, 1022, 1023, 1033, 1079, 1086, 1089, 1090, 1096) |
| 003 before | 105 | 70 | 0 | 35 |
| 003 after | 105 | 84 | 0 | 21: "no seam: manual" (AppKit/SwiftUI/OS) |

New 003 coverage: OC-3002 (Esc half), 3007, 3059 (URL half), 3064–3067, 3074–3076, 3086, 3092–3094. The manual halves of these stay manual: hotkey toggle, 50 ms timing, zero network connections, HUD placement, VoiceOver, and what the target app receives.

003 "no seam: manual": 3001, 3003–3006, 3014, 3016, 3021, 3048, 3055, 3056, 3063, 3070, 3082, 3083, 3088–3091, 3097, 3099. Caveat: the agent carried the reasons for 18 of these forward from an earlier pass without re-reading the oracle text, so treat that list as provisional.

Mutation check: 6 of 6 mutations went red (OC-3074/3075/3094, 3075/3076, 3064, 3067, 3092, 3086), and all were reverted; `Sources/` is clean.

Full `swift test`: one failure, **OC-381-21** (`Worf381PollTickTimerTests.swift:62`). It also fails on the baseline, passes 3 of 3 when run alone, and was under concurrent load (other test builds running). Likely a load-sensitive timing flake, not proven. It is not on the known-flake list.

**Defects / follow-ups for S1 (from reading source only, not run):**
- OC-3091 (major): the Library row context-menu order and separators differ from FR-003-22. Needs a manual check.
- OC-3021 (major): rows use a 22 pt SF Symbol, with no 44 pt rows and no 32 pt thumbnails for image/screenshot/file/folder/bundle. Needs a manual check.
- OC-3086 (minor): the catalogue says "Pinned" and the contract says "pinned". The test compares case-insensitively.
- OC-381-21: the flake above.

---

## 2026-11-17: GRDB 7.12.0 security check + perf harness (`s2/perf-harness` @ dd8537d)

**GRDB: no upgrade. 7.12.0 is the latest release** (v7.12.0, 2026-11-01; nothing newer as of 2026-11-17 23:55). Flotsam pins it `exact: "7.12.0"` in `Packages/FlotsamCore/Package.swift`.
- GitHub advisory DB: no advisory for GRDB.swift. Checked with the `affects=github.com/groue/GRDB.swift` query and a scan of the swift-ecosystem list.
- GRDB repository advisories (`repos/groue/GRDB.swift/security-advisories`): 0.
- 7.12.0 release notes list no security fixes. They do include a fix for quadratic statement compilation, a workaround for an SQLite WAL-snapshot ordering bug, and a fix for a SharedValueObservation deadlock.
- Residual risk is the system SQLite, not GRDB: GRDB links the OS SQLite. GRDB issue #1866 (closed, upstream says "report to Apple") cites an FTS5 tombstone integer overflow, heap overflow, fixed in SQLite 3.50.3. Flotsam uses FTS5 (`Migrations.swift`, `LibraryQueries.swift`) and deploys to macOS 14. This Mac (macOS 27.3) ships SQLite 3.54.0, which is patched. I did not verify which SQLite build macOS 14 and 15 ship. Options if S1 wants it closed: raise the deployment floor, or use a custom SQLite build (GRDB documents that this isn't SPM-compatible). No action recommended for MVP; noting it only.

**Perf harness** (opt-in `FlotsamPerfTests`, `FLOTSAM_PERF=1 bin/perf.sh`, Release, M1 Max, two runs, load avg 34–63):

| Measure | Run 1 | Run 2 |
|---|---|---|
| Capture write→stored row, n=200, p50 / p95 | 260 / 485 ms | 269 / 486 ms |
| … of which poll wait p50 / p95 | 252 / 472 ms | 263 / 481 ms |
| … persist after detection p50 / p95 | 5.6 / 44.3 ms | 7.2 / 18.6 ms |
| Search 50k items, n=20, p50 / p95 / max | 25.6 / 54.6 / 57.1 ms | 26.5 / 52.5 / 61.3 ms |

Capture interval: from `SystemPasteboard.write`, on a private NSPasteboard (never `.general`), to the `itemsChanged` event after the ingest commit. Path: the real `ClipboardCapture` 0.5 s timer, `IngestActor` and a temp GRDB DB. Copies use a seeded 0–500 ms jitter, so the poll phase is spread. Search ran with the page cache warm after seeding; the slowest query was multi-term with no hits.

**Capture p95 rerun under load < 10: PENDING a quiet box.** The 1-min load average was 78.5 at 23:54, with other sessions' test runs in progress.

**Defects / follow-ups for S1:** none new. OC-381-21 fake-timer rewrite is on obrien-430, per S1.

## 2026-11-17: A1 + A2 (+ symlinked screenshot folder) on `main` @ df9bf09

Contains the S1-named commits (checked with `git merge-base --is-ancestor`). Toolchain: macOS 27.3, Xcode 27.0, Apple Swift 6.4, M1 Max. Clean clone in the session scratchpad, detached at df9bf09. **Verdict: A1 PASS (one load-induced flake, green on re-run). A2 PARTIAL: text, URL, image, concealed-type and menu bar PASS; file copy NOT stored in 5 attempts (known intermittent, see below). Symlinked Desktop: PASS, matches AC-002-14. Symlinked override folder: NOT TESTED.**

**A1**

| Step | Result |
|---|---|
| `bin/bootstrap.sh` | exit 0 |
| `swift test` (Packages/FlotsamCore) | first run: 11 Swift Testing runs, 1848 tests, 1 failure: OC-381-21 "a second start() adds no second tick source" (`fired >= 2 && fired <= 4`, a timing expectation, machine load was high). Re-run of that suite: green |
| Known issues | 9 |
| `bin/check-architecture.sh` | exit 0, "architecture checks passed" |
| `bin/build.sh` (Debug) | exit 0, BUILD SUCCEEDED |

- Counting method as in the previous A1 entry (ANSI stripped, `grep "Test run with"`, sum of the count field). I did not keep the counts of the green re-run, so the 1848 figure is from the run that had the one failure; XCTest "Executed" lines showed 0 in the retained output and I did not break the XCTest total out.
- OC-381-21 is the fake-timer test S1 already has on obrien-430.

**A2 launch smoke (Debug build, scratch `CFFIXED_USER_HOME`, no TCC grants)**

| Check | Result |
|---|---|
| Launch, menu bar item, quit via menu item | pass. Process exited after the menu Quit |
| Text copy | stored once (`kind=text`, copyCount 1) |
| URL copy | stored once (`kind=link`) |
| Image copy | stored once (`kind=image`, 267 B) |
| Concealed-type copy | nothing stored; log shows `CAP-POL-001 outcome=skipped` |
| File copy | **not stored**: 5 attempts (including one after an intervening text copy) each logged `CAP-VAL-001`; no `item` or `bundleMember` row |
| `~/Library/Logs/DiagnosticReports/Flotsam*` | none; no fault-level log lines from the process |

- First round of text and URL copies: the first read logged `CAP-VAL-001`, then `CAP-PRM-001 warning permission=pasteboard`; nothing stored for text and URL. After the image capture, a second round stored text and URL once each. I count the second round as the result. Correction: this entry first blamed the first-round miss on the perf harness writing the shared pasteboard. That is wrong. The harness writes only to a private named pasteboard, and a test asserts it is not `.general` (see the perf harness entry). The cause of the first-round miss is unknown. It may be a permission warm-up after launch (`CAP-PRM-001`); S1, please confirm.
- File copy matches the intermittent capture already logged at 2990d01. This run it never stored. A file URL is an honoured type (FR-001-05) and is the first precedence in FR-001-08, so a copied file should be stored. Cause not determined; harness timing is not ruled out, but 0 of 5 is stronger than the earlier 3 misses.

**Symlinked screenshot folder (FRD-002, TASK-428 guard)**

- Method: `CFFIXED_USER_HOME` does not redirect CFPreferences on this macOS (a scratch `com.apple.screencapture` plist was ignored, so my first attempt tested nothing). Instead the scratch home's `Desktop` was made a symlink to a real directory in the session scratchpad. That is the default resolution path (`ScreenshotLocation.resolve`, `resolvingSymlinksInPath`), the "Desktop is a relocated or symlinked folder" case in FR-002-16.
- Observed: after launch, a PNG named `Screenshot <date>.png`, written under a hidden name and renamed into the real directory, was picked up within about 10 s: one `item` row `kind=screenshot`, `originalPath` set, 120 px wide, 28953 B; log `screenshot.imported byteSize=28953B outcome=stored`; `meta` row `screenshots.lastScanAt` written.
- Specified: FR-002-01 / FR-002-16 / AC-002-14: the watched folder itself may be a symlink, its target is watched, qualifying files are listed. **Observed matches specified.**
- Not tested: the folder override (`screenshots.folderOverride`) pointing at a symlink. Creating a bookmark for the symlink URL failed ("Could not open() the item"), and a bookmark for a real folder passed as a launch argument was rejected with SET-DAT-001; I did not find out why. Links inside the folder being dropped, and the no-follow read with `SSP-VAL-001` on a swap (AC-002-13), were also not exercised.

**Data isolation:** the real app DB, its `-wal` and the real prefs plist were hashed before and after; sha1 identical (the `-shm` was not compared, it is volatile). No `defaults write` was run. The scratch home isolated files only; prefs are not redirected on this macOS, so the app's UserDefaults domain was the real one, but the plist hash is unchanged. Pasteboard: contents are not personal data; I overwrote it with test strings and cleared it at the end (the prior contents were not restored beyond empty). Clone and scratch homes deleted; no Flotsam process left running.

**Not done / unknown:** symlinked override folder and AC-002-13 swap check; full-suite re-run counts; cause of the file-copy misses; cause of SET-DAT-001 for the launch-argument bookmark.

**Defects / follow-ups for S1:**
- File copy is not stored (0 of 5), `CAP-VAL-001` logged, FR-001-05 / FR-001-08 expect a `file` item. Repeats the earlier intermittent miss; needs a deterministic repro (real Finder copy) from S1 or me.
- The first text and URL reads after launch gave `CAP-VAL-001` then `CAP-PRM-001` before capture worked; confirm whether that is the expected permission warm-up on macOS 27.

---

## 2026-11-17: capture p95 rerun (`s2/perf-harness` @ dd8537d, Release)

Load at start was 10.02 (1-min), at 23:57. It rose to 57 by the end (23:59), caused by other sessions' `swift test` compiles, so this is **not a clean quiet-box run**.

| Measure | Value |
|---|---|
| Capture n=200 p50 / p95 / max | 268.2 / 494.2 / 757.1 ms |
| … poll wait p50 / p95 | 251.8 / 484.4 ms |
| … persist p50 / p95 / max | 5.8 / 86.2 / 386.9 ms |
| Search 50k n=20 p50 / p95 / max | 26.5 / 54.9 / 57.8 ms |

Across three runs (load 34–63, 34–63, then 10→57), capture p95 holds at 485–494 ms, and the 0.5 s poll wait accounts for 472–484 ms of it. Load moves only the persist tail: p95 of 19, 44 and 86 ms. Search p95 is steady at 53–55 ms. **Conclusion: capture p95 is bound by the poll period, not by load.** Cutting it means a shorter poll interval or change-count signalling, which is a product decision, not a perf bug. A truly quiet rerun would only tighten the persist tail.

The harness uses a private `NSPasteboard(name: "flotsam.perf.<uuid>")` (asserted ≠ `.general`), so it cannot have contaminated other sessions' general-pasteboard reads.

---

## 2026-11-18: FRD-008 phase 8T (`s2/frd008-8t` @ 6f95646, base df9bf09)

138 contract tests (OC-8001..OC-8147): Part A 83 and Part B 55. The filtered run is green with 15 `withKnownIssue` DEFECTs. Sources are unchanged.

- **Mutations:** 11 of 11 went red (Part A M1–M5 plus Part B: PasteGate.outcome, the menu shelf filter, captureToggle, LoginItem setEnabled, LSUIElement, `import Network`).
- **check-architecture:** passed.
- **Full suite:** only the known flakes OC-4102 and OC-381-21 failed.
- Part A was re-authored before its first push, so all commits are by Friday.

**DEFECTs (product untouched):**
- OC-8001/8030: "Launch at login" case.
- OC-8011: recovery removes the key instead of holding d30.
- OC-8016: an invalid key code is accepted, there's no reset to ⌃⌘V, and no SET-DAT-001.
- OC-8038: SET-PRM-001 copy lacks "triggers are paused".
- OC-8047: "image limit" vs "image budget".
- OC-8075: "Add app" vs "Add…".
- OC-8098: onboarding resume is lost on ⌘Q.
- OC-8110: no on-demand Accessibility or Input Monitoring request.
- OC-8127: ⌘⇧9 vs ⇧⌘9.
- OC-8139: Title Case labels against sentence case.
- OC-8141: onboarding step 5 writes the screenshot prefs.

**Rule 9 (Critical):** `PasteGate` has no production caller, and 5 paths re-implement SET-PRM-001.

**[Spec Drift]:** FRD-007 FR-007-12 and FRD-008 FR-008-16 disagree on the menu capture toggle. The menu follows FRD-008, while `Unmapped007IngestTests.swift:163-168` pins the FRD-007 behaviour. Needs an S1 ruling.

**No seam, manual:** onboarding live UI (8084, 8086–8092, 8095, 8096, 8099), live permission flows (8105, 8106, 8108, 8109, 8112–8114, 8116–8118, 8124), menu visuals and VoiceOver (8126, 8128, 8130, 8135–8138), binary and packet checks (8142–8147, live halves), and the screenshot halves of 8033, 8065 and 8066. OC-8043 and 8079 are weakly covered.

---

## 2026-11-18: A2 re-run (file copy, first reads after launch) on `main` @ 3b5c01c

Clean clone detached at 3b5c01c; `ef250e4` (merge of worf-401b, TASK-401 reread-latch fix) is an ancestor (`git merge-base --is-ancestor`). Debug build via `bin/build.sh`: BUILD SUCCEEDED. Launched only with a scratch `CFFIXED_USER_HOME` per launch, no TCC grants, no `defaults write`. Load average during the run: 1-minute 9.7 at the start, 3.3 at the end (another session was running `swift test`). **Verdict: A2 file copy PASS, first reads PASS. Both defects from the df9bf09 entry did not reproduce, and I found a likely harness cause for them (below).**

**File copy (item kinds counted in the scratch DB before and after each attempt)**

| Method | Attempts | `file` item stored | Log codes |
|---|---|---|---|
| Real Finder copy (osascript: Finder `select` a scratch file, System Events Cmd+C) | 6 | 6 of 6 (pasteboard held `public.file-url`, utf8 and utf16 plain text, `com.apple.icns`) | `pasteboard.processed kind=file outcome=stored`, no `CAP-*` |
| NSPasteboard file-URL write (`writeObjects([NSURL])`, only `public.file-url`) on launch 1 | 6 | 6 of 6 | `outcome=stored` |
| Same, launches 2 and 3 | 3 + 3 | 6 of 6 | `outcome=stored` |
| Same, on the app instance of the discarded first attempt, after fixing the writer (3 writes of one file) | 3 | 1 new item, 2 deduped (expected for the same file) | `outcome=stored` once, then `outcome=deduped` |

**Harness defect found, probable cause of the old 0 of 5.** My first NSPasteboard writer was built with `swiftc -O` and exited immediately after `writeObjects`. For file URLs the pasteboard was then empty (a separate process listing `pasteboardItems` printed nothing, while the same code in a longer-lived process showed `public.file-url`). Flotsam saw this as empty changes: `CAP-VAL-001`, `CAP-VAL-001`, then `CAP-PRM-001 warning permission=pasteboard` after the third, and nothing stored (0 of 6; these 6 attempts are discarded as a harness error, not counted). That is exactly the signature of the df9bf09 run (file copy `CAP-VAL-001`; first reads `CAP-VAL-001` then `CAP-PRM-001`). Rebuilt the writer without `-O` and with a 0.3 s wait before exit; every write then persisted and was captured. I cannot see the earlier run's harness, so this is a probable cause, not a confirmed one. Hint for S1: the product behaved per FR-001-01 / FR-001-18 on the empty reads (three empty changes raised `CAP-PRM-001`).

**First text and URL read after a fresh launch (3 launches)**

| Launch | Pasteboard at launch | Codes before first text | First text | First URL (text plus `public.url`, as a browser writes it) |
|---|---|---|---|---|
| 1 | cleared (empty) | one `CAP-VAL-001` at launch (empty read) | stored, no code | stored as `link`, no code |
| 2 | cleared (empty) | one `CAP-VAL-001` at launch (empty read) | stored, no code | stored as `link`, no code |
| 3 | held a text string | none | the pre-launch text was stored once at launch, then the new text stored | stored as `link`, no code |

- No `CAP-PRM-001` on any of the three formal launches. The single `CAP-VAL-001` with an empty pasteboard is the specified empty-payload log (AC-001-06 family), not a failure of the first read.
- Side observation: a pasteboard holding only `public.url` (an `NSURL` write, no plain text) gave `CAP-VAL-001` and nothing stored. FR-001-05 says `public.url` only confirms a link and the plain text is the stored value, so I read this as specified; flagging it in case S1 intends a URL-only copy to be stored.
- TASK-401 itself (re-read before counting an empty change) was not isolated here: no case in this run exercised a copy caught between clear and write.

**Data isolation:** real DB, its `-wal` and the real prefs plist hashed (sha1) before and after: `flotsam.sqlite` sha1 03fc64cf..., `-wal` sha1 c1189741..., prefs plist sha1 c190d732...; all three identical before and after (full-hash `diff` clean). No `defaults write`, no TCC grants, `com.apple.screencapture` and the media volumes untouched, no TextEdit documents saved. Only scratch files I created were copied. Pasteboard cleared at the end. App quit after each launch; clone, scratch homes and test files deleted; no Flotsam process left running.

**Not done:** TASK-401 empty-between-clear-and-write race (AC-001-18) was not provoked; nothing about the symlinked folder was re-run (not in scope).

**Defects / follow-ups for S1:** none new for the product. The two df9bf09 defects are retracted as not reproduced on 3b5c01c, with the harness cause above as the likely explanation. Optional: confirm intended behaviour for a URL-only (`public.url`, no text) pasteboard.

## FRD-006 8T (Shelf) — s2/frd006-8t @ e31e6ff (pushed 2026-11-18)

Contract tests for all 123 oracle IDs (OC-6001..6123), base df9bf09, with s2/frd006-8t-b (part 3) and origin/main 18a306f merged in (merges only, no rebase). New files in Packages/FlotsamCore/Tests: Frd006Contract{Reveal,Settings,Shortcut,Model}Tests, FlotsamShelfTests/Frd006Contract{Drag,Behavior,PrecitedGap}Tests. `swift test --filter Frd006`: 79 tests, all pass, 0 known issues. `bin/check-architecture.sh` passes. Sources diff vs merge-base empty (no product code touched). Mutation checks: 6 seeded breaks (incl. pasteCount +2, dropHighlightDuration 1.0, .libDat001→.shfOs001), all turned tests red, all reverted. Author on new commits: Friday only.

**Probable defect (code read, not run; App layer, no library seam):** OC-6082. `ShelfDragOut.draggingSession(_:endedAt:operation:)` returns silently when the operation is empty, so a system-aborted drag shows no SHF-OS-001 HUD. Paste count stays correct. Severity Major.

**No seam: manual:** OC-6007, 6010, 6011, 6037, 6077 (4 pt threshold is private in the App target's ShelfCardInteraction), 6081, 6089, 6108, 6111, 6112, 6113, 6114, 6121.

**Partial (library half tested, rest app-side or unmeasurable in unit tests):** 6067, 6069 (changeCount half), 6070, 6071 (AppKit half), 6074, 6078 (recordPaste wiring), 6094 (ignored-app copy case), 6105 (timer and flash draw; constant tested), 6107, 6109 (scroll), 6115 (CPU clause), 6116, 6117 (drag-out log emission), 6119 (network clause).

**PASS:** every other ID, by a new Frd006 test or by an existing library test confirmed in the part 3 audit (ShelfRevealMachine, ShelfLayout, ShelfModel, ShelfPresentation, ShelfKeyMap, ShelfDragPlanner, ShelfDrop*, ShelfLogEvent tests). Part 3 closed 11 gaps among pre-cited IDs: 6020, 6040, 6078, 6079, 6080, 6088, 6090, 6091, 6093, 6094, 6105.

**Follow-up suggestion:** the app-side halves above need app-level (UI or integration) coverage.

## AC-001-18 live race test (clear, then a late write) on main @ 18a306f (2026-11-18)

Fresh clone of main, Debug via `bin/build.sh`, each launch with its own scratch `CFFIXED_USER_HOME`, no TCC grants, no `defaults write`. Writer (built `-Onone`): `clearContents()`, sleep for the delay, `writeObjects([NSURL])`, wait 0.5 s before exit. Three back-to-back race copies per launch, distinct scratch files, 4-5 s apart. Poll interval is 0.5 s (`FlotsamBase/Concurrency/PollTick.swift:20`).

| Delay between clear and write | Launches | Race copies stored | Codes | Capture after the third copy |
|---|---|---|---|---|
| 0.75 s | 2 | 6 of 6 | `outcome=stored` each, no `CAP-PRM-001` | live |
| 1.0 s | 1 | 3 of 3 | `outcome=stored` each | live |
| 1.5 s | 2 | **0 of 6** | `CAP-VAL-001`, `CAP-VAL-001`, then `CAP-PRM-001 warning permission=pasteboard` | suspended; resumed on the next text copy (per FR-001-18) |

**Verdict: PASS up to 1.0 s, FAIL at 1.5 s.** The 1.5 s result follows FR-001-01 (three reads of one changeCount, about 1 s, then the change counts as empty) plus FR-001-18(b) (three empty changes suspend capture). But AC-001-18 states no bound on the gap, and the late write never bumps changeCount, so a writer slower than about 1 s loses the copy permanently and three of them suspend capture. **Spec question for S1/Ryan:** bound AC-001-18 and FR-001-01 at about 1 s, or treat the 1.5 s case as a defect. Boundary not narrowed between 1.0 s and 1.5 s. Synthetic writer only; no Finder-style slow copy tried.

**Data isolation:** sha1 of the real `flotsam.sqlite`, its `-wal` and `-shm`, and the real prefs plist identical before and after. Clone, scratch homes and harness deleted; pasteboard cleared; no Flotsam process left running.

## FRD-002 8T (Screenshots): `s2/frd002-8t` @ 8ce85a9, base 9032ae1 (pushed 2026-11-18)

Tests only: 5 new files plus display-name fixes in ScreenshotWatcherTests.swift. `swift test --filter FlotsamScreenshotsTests` gives 186 tests in 22 suites, 186 passed, 0 failed, 9 known issues, on 2 consecutive runs. main has since moved to 59d3ea2, so the branch has not been rebased.

**Known issues, wrapped in withKnownIssue (production diverges from the contract):**
- OC-2038 live and OC-2074 relaunch leg: a screenshot imported live and then deleted is imported again on relaunch. The seen set lives only in memory, and `meta.screenshots.lastScanAt` does not advance on a live import or on the 30 s tick. This contradicts AC-002-07 and FR-002-08.
- OC-2041: the reconcile-scan outcome writes no LogEvent.
- OC-2080: when an override folder is deleted and then recreated, `SettingsStore.read` drops the override, as FRD-008 AC-008-02 requires. So there is no SSP-IO-003 and nothing resumes. **[Spec Drift] FRD-002 vs FRD-008, for Ryan to rule on.**

**[Spec Drift] for Ryan:** FR-002-12 says import-recent is "always available in Settings", but only onboarding calls it. This affects OC-2062 and the HUD halves of OC-2020 and OC-2055. It is not wrapped in withKnownIssue because it is UNTESTABLE-AT-PACKAGE.

| ID | Status | Test file:name | Note |
|---|---|---|---|
| OC-2001 | PASS + PRE-EXISTING PASS | FRD002AuditATests.swift:tildeLocationAndAtomicRename; ScreenshotWatcherTests.swift:17 | ~/Pictures/Shots expands, hidden temp name not imported, rename imports once |
| OC-2002 | PASS | FRD002NoticeContractTests.swift:folder conditions | Deleted system folder: Desktop fallback, one SSP-IO-001 across a second tick, status Using Desktop; control: nothing raised before deletion |
| OC-2003 | PASS | FRD002NoticeContractTests.swift:folder conditions | Missing override: SSP-IO-003, status Paused; control: folder returns, held-back item stored, Desktop one still not |
| OC-2004 | PRE-EXISTING PASS | ScreenshotWatcherTests.swift:17, ScreenshotWatcherTests.swift:111 | Override wins |
| OC-2005 | PASS | FRD002WatcherContractTests.swift:~/Pictures/Tilde | Tilde location expanded; hidden temp name then rename imports once; defaults write modelled by the preference fake |
| OC-2006 | PASS | FRD002AuditATests.swift:locationIsARegularFile | .usingDesktop, SSP-IO-001 once, Desktop shot imported. (SW:36 was mis-cited; now titled FR-002-01) |
| OC-2007 | PASS (simulated) + UNTESTABLE-AT-PACKAGE (real eject) | FRD002AuditATests.swift:systemFolderVanishes | Vanish simulated via ProbedFileSystem.hide. Missing seam for the real part: a mounted disk image |
| OC-2008 | PRE-EXISTING PASS | ScreenshotWatcherTests.swift:48 | Raised once per state change via NoticeLog; the watcher writes nothing to the LogSink for it |
| OC-2009 | PASS | FRD002AuditATests.swift:locationChangeLiveDelivery | New folder event imported, old folder event not, old watch stopped |
| OC-2010 | PASS | FRD002AuditATests.swift:activationThenLiveImport | No tick: file imported, assertion is < 30 s of clock elapsed (confirmed) |
| OC-2011 | PRE-EXISTING PASS | ScreenshotWatcherTests.swift:73 |  |
| OC-2012 | PASS | FRD002NoticeContractTests.swift:folder conditions | chmod 000: nothing imported, SSP-PRM-001 without path/name, Needs access; control: access restored, imported, notice cleared |
| OC-2013 | PRE-EXISTING PASS | ScreenshotWatcherTests.swift:507 |  |
| OC-2014 | PASS (TCC grant modelled) | FRD002WatcherContractTests.swift:permission restored | The real TCC prompt cannot run at package level |
| OC-2015 | UNTESTABLE-AT-PACKAGE | - | Real macOS Files and Folders TCC prompt after tccutil reset. Missing seam: an OS permission-prompt harness (UI test on a reset TCC database); no port exists for the prompt |
| OC-2016 | PASS | FRD002NoticeContractTests.swift:polling and unsettled | Failing stream found by the 5 s poll, SSP-OS-001 once, status Watching; control: working stream raises nothing |
| OC-2017 | PASS | FRD002AuditATests.swift:fallbackEndsAndStreamDelivers | Notice cleared once, new stream delivers |
| OC-2018 | PASS | FRD002AuditATests.swift:subfolderAndSymlinkIgnored | Nested + symlink by event, activation scan and tick, delta 0, watcher alive |
| OC-2019 | PASS | FRD002AuditATests.swift:offThenOnDiscriminates | Shots newer than the launch watermark taken while off are not imported |
| OC-2020 | PASS (pickup on) + PRE-EXISTING PASS (SW:428, now cited OC-2020) + UNTESTABLE-AT-PACKAGE (HUD text) | FRD002AuditATests.swift:backfillWithPickupOn; ScreenshotWatcherTests.swift:428 | 3 created, second run 0. HUD 'Imported 3': importRecent returns a count only and nothing in App shows a HUD for it (see NEW DIVERGENCE 1) |
| OC-2021 | PASS + UNTESTABLE-AT-PACKAGE (Settings toggle UI) | FRD002AuditATests.swift:freshInstallDefaultsOn | Default value true, watcher starts watching. Missing seam: SwiftUI GeneralPane view-model |
| OC-2022 | PASS (proxy) + UNTESTABLE-AT-PACKAGE (fs_usage) | FRD002AuditATests.swift:noFolderAccessWhileOff | Recording FileSystemPort: zero touches while off across start/tick/activate/wake/settings; control proves the recorder sees access. Missing seam: fs_usage |
| OC-2023 | PASS + PRE-EXISTING PASS | FRD002AuditATests.swift:pausedThenResumedThenRelaunched; ScreenshotWatcherTests.swift:460 | Checked before and after relaunch, a later shot imports |
| OC-2024 | PASS (Curated) + UNTESTABLE-AT-PACKAGE (Save Clipboard) | FRD002AuditATests.swift:curatedImportsNothing | Save Clipboard needs a pasteboard seam. SW:428 was mis-cited as 2024 (now OC-2020) |
| OC-2025 | PASS | FRD002AuditATests.swift:exactOracleFileSet | png+jpg import; mov, PDF, hidden, subfolder, attribute-less do not |
| OC-2026 | PASS | FRD002WatcherContractTests.swift | Case-insensitive extensions .PNG .JPEG .jpeg .TIF .tiff .heic imported (+6); .gif adds nothing |
| OC-2027 | PASS | FRD002WatcherContractTests.swift | Unprefixed name with attribute imported; same name without not |
| OC-2028 | PASS | FRD002WatcherContractTests.swift | No attribute: Screenshot / Screen Shot imported, Holiday not (+2) |
| OC-2029 | PASS | FRD002WatcherContractTests.swift | Attribute false beats the Screenshot prefix, by live event and by reconcile scan |
| OC-2030 | PASS | FRD002WatcherContractTests.swift | name=Grab pref imports Grab <uuid>.png; without the pref it does not |
| OC-2031 | PASS | FRD002WatcherContractTests.swift | Nine localized catalogue prefixes imported; zh_HK separate |
| OC-2032 | PASS | FRD002WatcherContractTests.swift | Hidden file: nothing for 5 s and two events; renamed visible: exactly one item. Disputed run not reproduced in 10 runs |
| OC-2033 | PASS | FRD002AuditBTests.swift:gifAndMovLeaveNoTrace | gif+mov: candidates empty, log delta 0, no notices; png control adds exactly 1 record |
| OC-2034 | PASS | FRD002WatcherContractTests.swift:growing file | 6 x 0.5 s chunks with events: one item, bytes read once, at >= 3.0 s elapsed |
| OC-2035 | PASS | FRD002NoticeContractTests.swift:unsettled file | Growing file: SSP-IO-002 at info, nothing stored; control stable file stored |
| OC-2036 | PRE-EXISTING PASS | ScreenshotWatcherTests.swift:322 (triesAreBounded) | candidates empty, SSP-IO-002 x4 |
| OC-2037 | PASS | FRD002AuditBTests.swift:launchImportsExactlyTheNewThree | 3 new files + 1 non-screenshot: names == the 3 |
| OC-2038 | PASS (launch-imported) + KNOWN-ISSUE (live-imported) | FRD002PipelineContractTests.swift:deletedStaysAbsentAcrossTriggers, liveImportedDeletedStaysAbsent | DIVERGENCE: a live-imported item deleted and relaunched before any reconcile scan returns (seen set memory-only, watermark not advanced on live import or the 30 s tick) |
| OC-2039 | PRE-EXISTING PASS | ScreenshotWatcherTests.swift:226 (launchReconcile) | fresh imported, older not |
| OC-2040 | PRE-EXISTING PASS + PASS | ScreenshotWatcherTests.swift:226; FRD002AuditBTests.swift:relaunchDoesNotReimportTwenty | 20 imported, relaunch, count stays 20, same names, watermark not backwards |
| OC-2041 | KNOWN-ISSUE | FRD002AuditBTests.swift:scanOutcomeIsLogged | DIVERGENCE: LogEvent has no reconcile-scan outcome case; reconcileScan() logs nothing (2 known-issue expectations, wake and activation) |
| OC-2042 | PASS | FRD002PipelineContractTests.swift | Through the real ingest pipeline, fresh DB instance |
| OC-2043 | PASS | FRD002PipelineContractTests.swift:itemSurvivesFileDeletionAcrossReopen | Item survives file deletion across a reopen (41x29 stored copy) |
| OC-2044 | PASS | FRD002PipelineContractTests.swift | Through the real ingest pipeline, fresh DB instance |
| OC-2045 | PASS | FRD002PipelineContractTests.swift | Through the real ingest pipeline, fresh DB instance |
| OC-2046 | PASS | FRD002PipelineContractTests.swift | Through the real ingest pipeline, fresh DB instance |
| OC-2047 | PASS | FRD002PipelineContractTests.swift | Through the real ingest pipeline, fresh DB instance |
| OC-2048 | UNTESTABLE-AT-PACKAGE | - | Finder reveal with the file selected (Cmd-R). Missing seam: a Finder/NSWorkspace reveal port with an assertion on the selected URL (FRD-003 library action, App target). Package half (original path stored) is not the contract's then-clause |
| OC-2049 | PRE-EXISTING PASS | ScreenshotWatcherTests.swift:196 (repeatedEventsAreIdempotent) | count 1 |
| OC-2050 | PASS | FRD002PipelineContractTests.swift | Through the real ingest pipeline, fresh DB instance |
| OC-2051 | PASS | FRD002PipelineContractTests.swift | Through the real ingest pipeline, fresh DB instance |
| OC-2052 | PASS | FRD002PipelineContractTests.swift | Through the real ingest pipeline, fresh DB instance |
| OC-2053 | PASS | FRD002PipelineContractTests.swift | Through the real ingest pipeline, fresh DB instance |
| OC-2054 | UNTESTABLE-AT-PACKAGE | - | A system Save-to-Clipboard capture is an OS screencapture plus the pasteboard monitor (FlotsamCapture on NSPasteboard.general, forbidden here). Missing seam: a pasteboard port driven by a real screenshot-to-clipboard. A seeded clipboard image would only assert the seed (B1); the nearest real coverage is screenshotDedupesAgainstClipboardImage (kind image item stays image) |
| OC-2055 | PASS + UNTESTABLE-AT-PACKAGE (HUD) | FRD002AuditBTests.swift:backfillSevenHundred | 700 files: importRecent == 500, the 500 newest by name, 200 oldest absent. HUD 'Imported 500' has no producer (see NEW DIVERGENCE 1) |
| OC-2056 | PRE-EXISTING PASS + PASS | ScreenshotWatcherTests.swift:~403; FRD002AuditBTests.swift:backfillSevenHundred | second importRecent == 0 |
| OC-2057 | PASS | FRD002AuditBTests.swift:backfillHonoursSevenDayRetention, backfillSevenDayBoundary | 3 d in, 10 d out; 6.5 d in, 7.5 d out |
| OC-2058 | PASS | FRD002AuditBTests.swift:backfillThirtyDayCap(retention:) | 20 d and 29 d in; 31 d and 40 d out |
| OC-2059 | PASS | FRD002PipelineContractTests.swift | Through the real ingest pipeline, fresh DB instance |
| OC-2060 | PASS (package half) + UNTESTABLE-AT-PACKAGE (checkbox default, UI) | FRD002PipelineContractTests.swift:checkedImportBringsInTheWeek | importRecent on 2 week-old shots: count +2, both by pixel-width identity, kind screenshot, fresh DB. The checkbox and its default-on live in App/Flotsam/OnboardingModel.swift (needs AppContainer, no package seam) |
| OC-2061 | PASS (package half) + UNTESTABLE-AT-PACKAGE (checkbox UI) | FRD002PipelineContractTests.swift:uncheckedImportBringsInNothing | First run, no watermark, 2 week-old shots: tick, wake, activation and live events leave count 0 (fresh DB). The unchecked checkbox itself is App-side |
| OC-2062 | UNTESTABLE-AT-PACKAGE + NEW DIVERGENCE 1 | - | Settings > General has no 'Import recent screenshots' button: App/Flotsam/Settings/GeneralPane.swift has no such control and importRecentScreenshots is wired only to onboarding (AppContainer.swift:200, OnboardingModel.swift:88). Even with a seam this would fail today |
| OC-2063 | PASS | FRD002NoticeContractTests.swift:rejected content | 100 MiB + 1: not stored, SSP-LIM-001 once, not retried; boundary: exactly 100 MiB stored |
| OC-2064 | PASS | FRD002NoticeContractTests.swift:rejected content | Non-image bytes: info log SSP-VAL-001 once, count 0, original untouched, not retried |
| OC-2065 | PASS | FRD002AuditBTests.swift:validFilesPassTheStuckOne | Stuck mode-000 file + 5 valid: all 5 within 2.0 s, stuck not imported, SSP-IO-002 raised |
| OC-2066 | PASS (proxy) + UNTESTABLE-AT-PACKAGE (signposts, p95) | FRD002AuditBTests.swift:burstLatencyBound | 20 in a burst within 2 s, peakInFlight <= 2 (fake ingest). Missing seam: pickup-import PerfInterval / injectable signposter; p95 needs real ingest + Library search |
| OC-2067 | UNTESTABLE-AT-PACKAGE | - | 10,000-item Library, 100 files 3 s apart, p95 file-arrival-to-search <= 2.0 s: a timed perf run on real wall-clock and a real DB, not a deterministic test (SteppedClock skips sleeps). Missing seam: a screenshot-pickup case in FlotsamPerfTests (bin/perf.sh, FLOTSAM_PERF=1) and a pickup-import signpost |
| OC-2068 | UNTESTABLE-AT-PACKAGE | - | 10 min idle CPU profile vs pickup-off baseline, < 0.1 % of a core: needs a real process under Instruments/sample. Missing seam: a CPU profiling harness (bin/perf.sh has none for pickup) |
| OC-2069 | PASS + UNTESTABLE-AT-PACKAGE (log show, Copy Diagnostics, Notices window) | FRD002AuditBTests.swift:markerNeverLeaks | Marker folder and files, SSP-IO-001 and SSP-LIM-001 provoked: no marker in any record field or reported error. Missing seam: OSLog store reader, diagnostics export, Notices UI |
| OC-2070 | PASS (log half) + UNTESTABLE-AT-PACKAGE (Settings label) | FRD002PipelineContractTests.swift:overrideFolderNameStaysOutOfTheLog | Override fold-zq7marker is the watched folder (via FolderOverride): marker-named screenshot imported, marker-named non-image rejected (SSP-VAL-001 logged, provoked); no marker in any record field. Settings label is SwiftUI (GeneralPane shows lastPathComponent), no seam |
| OC-2071 | PASS | FRD002PipelineContractTests.swift:sessionLeavesWatchedFolderUntouched | Distinct widths keep content unique; Clear History bound uses the rig clock (test-bug fix) |
| OC-2072 | PRE-EXISTING PASS (now cited) | ScreenshotWatcherTests.swift:111 (overrideFolderLifecycle) | Override S/O/Desktop emission, names == [inChosen] |
| OC-2073 | PASS | FRD002AuditBTests.swift:oldFolderIsNeverScannedAgain | After location W->N, file in W: event, wake, activation, tick all skip it; control file in N imports |
| OC-2074 | PASS (launch-imported, wake, activation) + KNOWN-ISSUE (live-imported relaunch leg) | FRD002PipelineContractTests.swift:deletedStaysAbsentAcrossTriggers, liveImportedDeletedStaysAbsent | Same divergence as OC-2038 |
| OC-2075 | PASS | FRD002WatcherContractTests.swift:sameRuleEverywhere | Same 2 files from system folder, Desktop fallback and override, live and launch scan (6 combinations) |
| OC-2076 | PASS | FRD002NoticeContractTests.swift | SSP-PRM-001 literal text, warning, no path/name, no HUD |
| OC-2077 | PASS | FRD002NoticeContractTests.swift | SSP-IO-001 literal text, warning, no leak, no HUD |
| OC-2078 | PASS | FRD002NoticeContractTests.swift | SSP-IO-002 never reaches the user; found once after it settles |
| OC-2079 | PASS | FRD002NoticeContractTests.swift | SSP-IO-003 literal text, warning, no leak, no HUD |
| OC-2080 | KNOWN-ISSUE | FRD002AuditBTests.swift:recreatedOverrideResumes | DIVERGENCE (spec drift FRD-002 vs FRD-008 AC-008-02): override deleted for real reads as none and SettingsStore.read drops it; no SSP-IO-003, no resume on recreate. Hide/unhide variant (SW:111) passes |
| OC-2081 | PASS | FRD002NoticeContractTests.swift:rejected content | SSP-VAL-001 never reaches the user; next real screenshot stored |
| OC-2082 | PASS | FRD002NoticeContractTests.swift:rejected content | Literal 'A screenshot was too large to import (over 100 MB).', warning, no path/name, no HUD |
| OC-2083 | PASS | FRD002NoticeContractTests.swift:polling and unsettled | SSP-OS-001 literal text, warning, no leak, no HUD |
| OC-2084 | PASS | FRD002PipelineContractTests.swift:unwritableDataFolderFailsCleanly | STO-IO-001 literal message, count 0, F SHA unchanged |
| OC-2085 | PASS + UNTESTABLE-AT-PACKAGE (button visibility, label) | FRD002AuditBTests.swift:clearedOverrideImportsFromSystem | After clearing: override reads none, watch is S, S file imported, O file not. Button is in GeneralPane.swift (no package view model) |
| OC-2086 | PASS (behavior) + UNTESTABLE-AT-PACKAGE (UI) | FRD002WatcherContractTests.swift:override choice | Choosing O: override resolves to O, only O watched and imported. Button visibility and label are SwiftUI in GeneralPane.swift |

## Totals by status (86 IDs)

- Fully covered, no gap: 63 (of which pre-existing only: 8)
- Covered with an UNTESTABLE-AT-PACKAGE remainder (PASS / PRE-EXISTING half plus a missing seam): 13
- KNOWN-ISSUE (production divergence, test wrapped in withKnownIssue): 4 (OC-2038 live, OC-2041, OC-2074 live, OC-2080); OC-2038 and OC-2074 also have a passing half
- UNTESTABLE-AT-PACKAGE with no passing half: 6 (OC-2015, 2048, 2054, 2062, 2067, 2068)
- Any PASS component (new or pre-existing): 78
- Any UNTESTABLE-AT-PACKAGE component: 19

## New divergences found in this pass
1. FR-002-12 / OC-2062 (also the HUD half of OC-2020 and OC-2055): Settings > General has no 'Import recent screenshots' button and nothing shows 'Imported {n}'. importRecentScreenshots is wired only to onboarding (App/Flotsam/AppContainer.swift:200 discards the count; OnboardingModel.swift:88). Evidence is a code search, not a run: UNTESTABLE-AT-PACKAGE, but it would fail today. Severity: Major.
2. From the earlier watcher-agent note, not a contract ID: a hidden temp file that stays hidden across a reconcile scan and is then renamed is not picked up on the rename event (the scan advanced the watermark past its birth date). OC-2032's scenario passes; real screencapture renames within milliseconds. For Friday to rule on.

## Citation notes
- ScreenshotWatcherTests.swift:17 still cites OC-2006 and 2072 for a test that proves plain-folder and system-vs-Desktop; probable mis-cite, left alone (out of the approved edit list).

## TASK-442 late-write fix: `s2/cap-late-write` @ 07e13da, with live race re-run (2026-11-18)

**Fix (FR-001-01, FR-001-18):** an empty clipboard change is watched for up to 10 s (`ClipboardCapture.emptyChangeWatchLimit`, its only home), and a newer changeCount ends the watch early. A late fill is stored once, never counts toward FR-001-18(b), and resets the empty count. FRD-001 is in the same commit: FR-001-01, FR-001-18(b), AC-001-15 and AC-001-18 are reworded, and AC-001-20..24 are new.

**Gates on 07e13da:**
- `bin/check-architecture.sh` passes.
- The full `swift test` passes: the largest run had 559 tests in 67 suites, 12 known issues, 0 failures and no flake re-runs.
- `bin/build.sh` succeeds.
- `FlotsamCaptureTests` passed 228/228 on two extra runs.

**Mutation checks:**
- Turned tests red: limits of 5, 1, 20 and 10.5 s, and counting late fills toward FR-001-18(b).
- Stayed green: a limit of 9.9 s, so the low side of the 9.9 s boundary is not tightly pinned.

**Live race re-run.** Same method as the AC-001-18 run above: fresh clone, Debug build, a scratch `CFFIXED_USER_HOME` per launch, an `-Onone` writer, 3 race copies per launch.

| Delay between clear and write | Launches | Race copies stored | Duplicates | Codes | Capture after the third copy |
|---|---|---|---|---|---|
| 0.75 s | 2 | 6 of 6 | 0 | `outcome=stored` each, no `CAP-VAL-001`, no `CAP-PRM-001` | live |
| 1.5 s | 2 | **6 of 6** (was 0 of 6 on 18a306f) | 0 | `outcome=stored` each, no `CAP-VAL-001`, no `CAP-PRM-001` | live |
| 5 s | 2 | 6 of 6 | 0 | `outcome=stored` each, no `CAP-VAL-001`, no `CAP-PRM-001` | live |

**Verdict: PASS.** All 18 copies were stored exactly once (`copyCount=1`). This run did not exercise writes later than 10 s or the suspension path; unit tests cover those (AC-001-21, AC-001-22, AC-001-24). The writer was synthetic only; no Finder-style slow copy was tried. Each launch also stored the text already on the pasteboard, which is expected and is not a race copy.

**Data isolation:** sha1 of the real `flotsam.sqlite`, its `-wal` and `-shm`, and the prefs plist was identical before and after. The clipboard was restored, scratch files were deleted, and no Flotsam process was left running.

**For S1 and Ryan:**
- **[Spec Drift]** OC-1080's `CAP-PRM-001` now fires when the third watch ends, up to 10 s later or sooner if the change is superseded. The oracle file is not edited.
- A superseded empty change now counts toward FR-001-18(b).
- TASK-442 has no Ticketmaster record in `flotsam`.

## FRD-002 gap tests: TASK-218/219/220/231/232, `s2/frd002-gaps` @ 1195b01, base 3227b40 (2026-11-18)

These are tests only. `swift test --filter FlotsamScreenshotsTests` gives 118 tests in 16 suites, all passed with 0 failures and 0 known issues. Each agent ran the suite twice, and I re-ran the combined branch once. The ticket texts are not in this Mac's Ticketmaster, so I tested against FRD-002 and `.claude/oracle/frd-002-contract.json`. The new tests use a real database, IngestActor and watermark store; the shared rig is in `FRD002GapTestsSupport.swift`.

| Ticket | IDs | Verdict | Tests |
|---|---|---|---|
| TASK-218 | OC-2037, 2038, 2040, FR-002-08 | PASS (4 tests) | FRD002GapTests218_219.swift: threeNewShotsImportedOnLaunch, deletedShotStaysDeletedAfterRelaunch, twentyImportedRelaunchAddsNothing, firstLaunchSeedsWatermarkOnly |
| TASK-219 | FR-002-09, AC-002-08 | PASS (3 tests) | FRD002GapTests218_219.swift: rowFacts, blobIsSeparateCopy, blobSurvivesOriginalChange |
| TASK-220 | OC-2043, 2044, 2052, 2053 | PASS (5 tests) | FRD002GapTests220.swift: deletingOriginalKeepsItemAndPreview, previewRebuiltFromBlobNotOriginal, deletingItemsLeavesOriginalsAlone, deletingItemAfterOriginalGone, deletingUnknownIdChangesNothing |
| TASK-231/232 | OC-2069, FR-002-15, FR-000-10, AC-002-12 | PASS (3 tests + detector control) | FRD002GapTests231_232.swift: unusableSystemFolderLeaksNothing, oversizeScreenshotLeaksNothing, diagnosticsReportLeaksNothing |

**Mutations.** Each was a temporary edit, reverted, and confirmed with a clean `git diff -- Sources`. Every one turned the named tests red:
- watermark rewind after relaunch: OC-2038 and OC-2040 went red.
- `performDelete` also removing originalPath, skipping `discardThumbnails`, `content(of:)` needing the original, and thumbnail regeneration needing the original: the TASK-220 tests went red.
- filename in the SSP-LIM-001 context and folder path in the SSP-IO-001 context: the TASK-231/232 log and report tests went red.

The notice and report absence checks have no production mutation, because Notice carries only catalogue text and RaisedError carries only code, severity and timestamp. Liveness assertions guard them instead.

**UNTESTABLE-AT-PACKAGE:**
- ⌘⌫ UI: covered at the `FlotsamDatabase.delete(ids:)` seam.
- Process quit: covered by `RealIngestRig.relaunch()`.
- Trash-and-empty: covered by `removeItem`.
- Real OSLog `log show`: covered at the `LogSink` seam.

**Product bugs found:** none.

**Notes:**
- The OC-2038 delete-then-relaunch case passes when the shot came in through the launch reconcile scan. The TASK-445 divergence is specific to shots imported LIVE, because the live path does not advance the watermark, so it still stands.
- The contract says "thumbnail rows", but thumbnails are files at `thumbs/<id>-<edge>.jpg`. This is a contract wording gap.
- `FlotsamError.message` is a StaticString, which is a compile-time guard against paths in messages.
- 4560b64's trailer says Sonnet 5.5. It is left as is, because rewriting it would need a force-push.

## 2026-11-18: A1 + A2 on `main` @ 10596ad (re-targeted from a9e1029)

Clean clone at 10596ad. Nothing committed.

**A1**
- bootstrap: exit 0.
- `swift test` (FlotsamCore): 2350 tests in 284 suites across 12 runs. 2349 passed, 1 failed, 9 known issues.
  - The failure was OC-4102 (`WorfFRD004StorageTests.swift:429`, p95(pin) < 100 ms). It measured 150.8 ms while the load average was 32.7.
  - Re-running that suite alone passed (17/17). This is a timing flake, the same class as OC-381-21.
  - The 2350 total comes from the run that hit the flake.
- check-architecture: pass.
- build.sh Debug: BUILD SUCCEEDED with 1 warning, `ClipboardCapture.swift:112:27` ("result of call to 'assumeIsolated' is unused").
- Delta vs df9bf09: 1848 → 2350 tests, 11 → 12 runs, known issues unchanged at 9.

**A2** (Debug build, scratch home, no TCC grants)
- Launch: pass. Menu bar item present (8 menu entries).
- Quit: pass. No process left.
- Text copy: stored as `text`.
- URL copy: stored as `link`.
- Image copy: stored as `image`, 12530 B.
- Concealed copy: skipped with `CAP-POL-001`.
- File copy, 5 attempts: 1 item stored, 4 deduped, copyCount 5.
- First reads: one `CAP-VAL-001` on the empty pasteboard at launch; no `CAP-PRM-001`.
- Crash reports: 0 before, 0 after.

**Real DB, -wal and prefs plist (sha1):** identical before and after, and identical to the values in the 3b5c01c entry.

**Not run:** the symlinked folder, the override folder and the AC-001-18 race.

## 2026-11-18: A4 perf baseline on `main` @ 10596ad (Release)

Values are the median of 3 harness runs. Earlier A4 values are in brackets.

**Idle** (10 min, sampled every 10 s via proc_pid_rusage; empty library)
- CPU mean 0.0750 % [0.0806]. Budget ≤ 0.2 %: PASS. Max 10 s interval 0.0908 %.
- Wakeups 2.000/s [2.139]. Budget ≤ 2.5/s: PASS.
- RSS 85.9 / 85.8 / 85.9 MiB (start / end / peak) [97.5 MiB, but that was a seeded 10k library].
- phys_footprint 22.5 MiB [22.6].
- No verdict on the 60 MB line. Which measure FR-001-20 means is Ryan's call (S1 ruling, 2026-11-18); S1 recommends phys_footprint, the measure Activity Monitor shows.

**Capture**
- End to end: p50 272.3, p95 479.8, max 507.1 ms [268.2 / 494.2 / 757.1]. The 0.5 s poll accounts for 470-477 ms of the p95.
- Persist only: p50 7.7, p95 11.5, max 22.3 ms [5.8 / 86.2 / 386.9]. Budget ≤ 250 ms: PASS.

**Search** (50k items, n=20)
- p50 25.5, p95 52.65, max 55.9 ms [26.5 / 54.9 / 57.8].
- Budget is p95 ≤ 100 ms, stated at 10k items: PASS.

**DB open + schema check** (OC-7130, 10k items)
- PASS in 3 of 3 runs. Budget ≤ 300 ms. No per-open time is printed; the whole test, including seeding, took 0.254-0.261 s.

**Library open (hotkey → visible) and paste p95** (TASK-167/168/195/196)
- UNTESTABLE-AT-PACKAGE for both. Hotkey → visible needs the real NSPanel, the Carbon hotkey and the `library.open` signpost. Paste needs the real run loop, a real pasteboard and a CGEvent post.
- Budget for both is p95 ≤ 150 ms. Not measured.

**Conditions**
- 1-minute load average: idle run 3.69 at start, about 12.3 at end; perf runs 12.20 / 3.90 / 6.37.
- Run 1, at load 12.20, landed within 2 % of runs 2 and 3.

**Isolation**
- Real DB, -wal and prefs sha1 identical before and after, and matching earlier entries.
- No `defaults write`, no processes left behind.

## 2026-11-18: Live functional walk of the Debug app on main ecd9f87 (includes 1ee480b)

**Verdict: no blocking failures. 7 of 10 flows PASS and 3 PARTIAL, with 4 minor defects. No crashes and no `.ips` reports.**

- **Setup:** clean clone, `bin/bootstrap.sh`, Debug build. A real-user walk driven with System Events keystrokes, AX presses, cliclick drags and pasteboard writes, with TextEdit and Finder as the other apps.
- **Isolation:** each launch used a scratch `CFFIXED_USER_HOME`.
- **Flows 4-10:** run on a copy built with only `PRODUCT_BUNDLE_IDENTIFIER=io.github.heilo27.FlotsamWalk` changed, so the app's UserDefaults landed in a throwaway domain (see Disclosure). No code was changed.

| Flow | Result |
|---|---|
| 1 Launch, menu bar, onboarding, AX prompt | PARTIAL |
| 2 Hotkey panel, search, Return paste, ⇧Return copy | PASS |
| 3 Capture kinds and concealed copy | PASS |
| 4 Pause, Resume, Curated | PASS |
| 5 Shelf | PASS |
| 6 Library: tags, pin, note, edit, sort, bundles | PARTIAL |
| 7 Settings panes, shortcut recorder, ignored apps | PARTIAL |
| 8 Text triggers in TextEdit | PASS |
| 9 Screenshot pickup, Import Recent | PASS |
| 10 Clear history, quit and relaunch | PASS |

**FAILs (all minor)**
1. **Sort is not named in the footer (FR-004-12).**
   - Repro: open the Library and press ⌘S repeatedly.
   - Expected: the footer names the active sort.
   - Actual: it shows only "N items".
2. **⌘A in edit text does not select all.**
   - Repro: select a text item, press ⌘E, press ⌘A, type Z.
   - Expected: the text is replaced by Z.
   - Actual: Z is appended.
   - Driven by System Events keystrokes, so likely real but worth a human confirm.
3. **Copy Diagnostics item counts are wrong.**
   - Repro: Settings › About › Copy Diagnostics.
   - Expected: counts match the store.
   - Actual: the "Items" section reports 0 for every kind while the DB holds 28 items (the Storage pane shows 27).
4. **Unexpected SET-DAT-001 notice (flow 1).**
   - It appeared during the onboarding run.
   - The likely cause is the launch argument that forced onboarding. Not confirmed.

**Passes worth noting**
- **Flow 1:** the menu bar item and all 8 onboarding steps work.
- **Flow 2:** with TextEdit frontmost, the hotkey opened the panel. Typing filtered, Return pasted into TextEdit, and ⇧Return copied without pasting.
- **Flow 3:** text, URL, image, file, rich text from TextEdit and a multi-file Finder selection (stored as a bundle) were each stored once with the right kind. A concealed copy was not stored.
- **Flow 4:** Pause and Resume work from the menu. Curated is the "Capture mode" popup in Settings › Storage, not a menu item.
- **Flow 5:** Shelf enable and reveal work. Dragging an item out to Finder and TextEdit and dropping a file in all work.
- **Flow 6:** pin, note, tags, edit text, sort, bundle ungroup, grid view and delete work.
- **Flow 7:** ignored apps work: with TextEdit listed, its copy was skipped (CAP-POL-002, 0 rows). After removal, the same copy was stored. The shortcut recorder works, including conflict rejection. Reset to Defaults and the Storage popups write their prefs.
- **Flow 8:** ⌘K opens "Shortcut and Trigger". The trigger `;wlkx` plus Space expanded in TextEdit, and the trigger and Space were consumed.
- **Flow 9:** a capture written into the scratch watched folder appeared in about 2 s.
- **Flow 10:**
  - 37 items survived quit and relaunch.
  - Clear History removed 35 and kept the pinned item and the triggered item, as the Storage pane text says.
  - A new copy survived a second relaunch.

**Observations (not FAILs, for triage)**
- The panel footer has no ⇧Return hint.
- A copy-only ⇧Return is logged as `paste.back started/succeeded`.
- The menu bar status reads "Needs attention" while capturing normally.
- Search text typed before ⌘K does not filter, so the trigger was set on the first row.
- Import Recent imported nothing (only deduped) and showed no HUD. Logs show two parallel passes per press.
- Any image written to the watched folder is imported, including the walk's own `screencapture` output.
- The Clear History range defaults to "Last hour". The "Also delete pinned items and items with a shortcut" path was not tested.
- Onboarding's "Launch at login" is pre-checked and triggers the macOS "Login Item Added" banner. It was unchecked or switched off each time.

**Not verified**
- Launch at Login effect: it toggles, but no pref or launchctl evidence was found.
- Edge-hover Shelf reveal: the pref was set but not exercised.
- Triggers pane "Add…": result unclear.
- Open System Settings buttons and Project Page: not pressed.

**Disclosure: real prefs written in part 1**
- The app uses `UserDefaults.standard`, and `CFFIXED_USER_HOME` does not redirect CFPreferences. The first (onboarding) run therefore wrote the real `io.github.heilo27.Flotsam` domain.
- Its plist sha1 went from c190d732… to f20f539d….
- It still holds only `onboarding.completed` and `settings.lastPane`, the same keys recorded on 2026-11-17.
- No `defaults write` was run. The rest of the walk used the bundle-id copy, and the hash did not change again.
- Launch at Login was switched off. No Flotsam login item, launchd job or process remains.
- In part 2 an agent opened Clear History by mistake in the walk copy and cancelled it. No items were lost.

**Isolation**
- Real DB (03fc64cf…) and `-wal` (c1189741…) sha1 were unchanged throughout.
- The walk prefs domain and its plist were deleted, and TextEdit docs were discarded unsaved.
- No `com.apple.screencapture` change and no files on the real Desktop or Documents. Evidence (notes and screenshots) is kept in the session scratchpad.

## 2026-11-18: A1 + A2 on `main` @ 19dd364 (TASK-451 de-flake; re-targeted from ca74844)

**Verdict: PASS. Zero failures, no flakes, and both S1 re-checks pass.**

**A1**
- `swift test` exited 0. 2513 tests in 312 suites across 12 runs: 2513 passed, 0 failed, 15 known issues.
- OC-4102 (pin p95), OC-7132 and the capture timing tests all passed in the full run. The 1-minute load average ranged from 22 to 164 during it.
- `bin/check-architecture.sh` passed.
- The Debug build has 1 warning: `ClipboardCapture.swift:118:27`, an unused `assumeIsolated` result. It is the same warning as before, moved from line 112.
- The earlier partial run on ca74844 had the same totals, all passing, with no flake.

**A2** (scratch `CFFIXED_USER_HOME`; built with the bundle-id override `io.github.heilo27.FlotsamWalk` so prefs are isolated)
- The menu bar item showed 8 entries: PASS.
- Text, URL and image copies were stored as `text`, `link` and `image`: PASS.
- A concealed copy was skipped with CAP-POL-001: PASS.
- The same file copied 5 times gave 1 stored item and 4 deduped, with `copyCount` 5: PASS.
- Launch at login was unchecked in onboarding and stayed off after relaunch: PASS.
  - Observation: macOS still showed a "Login Item Added" banner for Flotsam at launch.
- (a) Copy Diagnostics item counts match the scratch DB by kind (text 2, link 1, image 1, file 1, all others 0): **PASS**. The all-zero defect seen at ecd9f87 is fixed.
  - Side note: the diagnostics show `pasteboard: notDetermined`.
- (b) Import Recent: one press now runs one pass (one dedup line per file, one window order-in). At ecd9f87 one press ran two parallel passes. **PASS**
  - Count: fresh screenshots were imported by the watcher before any press: 3 written live gave 2 stored and 1 deduped. 3 written while the app was quit were imported at launch (`screenshot.scan count=3`). So each press imported 0 and deduped everything.
  - A case where Import Recent finds anything the watcher missed was not produced.
  - HUD: the log shows one window order-in per press, but none of 3 screen captures caught it at that load. Not visually confirmed.

**Isolation**
- Real DB, `-wal` and prefs sha1 matched their baselines (03fc64cf…, c1189741…, f20f539d…).
- The walk prefs domain and its plist were removed, and no Flotsam launchd entry, process or crash report remains. The clone was deleted.

## 2026-11-18: S1 checks on main ea9b4af and obrien-460 @ 67a0883 (log only, nothing fixed)

Setup: fresh clones, Debug builds with `PRODUCT_BUNDLE_IDENTIFIER=io.github.heilo27.FlotsamWalk`, and a clean sandbox (walk prefs domain and scratch `CFFIXED_USER_HOME`) before each launch. Real DB, -wal and prefs hashes were unchanged before and after (03fc64cf…, c1189741…, f20f539d…). No login item remained at the end (`launchctl print gui/$UID | grep -i flotsam` was empty).

### TASK-460 "Login Item Added" banner: INCONCLUSIVE on both builds
- `sfltool dumpbtm` timed out after 30 s (rc=142) before and after on both builds, without sudo. So there is no before/after BTM dump. The evidence is from `log show`.
- **ea9b4af:**
  - The only BTM event was `BTMManager.userDataDidChange`, about 0.4 s after the first clean launch, while onboarding was still on step 1. This is before any register call path can run.
  - No BTM event fired when Launch at Login was unchecked on step 7, or on Continue.
- **obrien-460 @ 67a0883:**
  - Same pattern: one `userDataDidChange` about 0.4 s after the first launch, and none on uncheck or Continue.
  - A third launch, with onboarding already complete, produced 0 events.
- **Banner timing:** the banner stays on screen, so screenshots can't time it. The only matching system event is at first launch, not at Continue.
- **Code:** the only `SMAppService.mainApp` calls in ea9b4af are in `App/Platform/SMLoginItemService.swift` (status read, register, unregister). What causes the launch-time BTM event is not determined. The live evidence can't separate the 460 reconcile path from the old guard + setEnabled path.

### TASK-455 "Needs attention" dot clears after recovery: BLOCKED
- The degraded state needs a missing Accessibility or Input Monitoring grant, and the walk can't change TCC.
- The live app showed "capturing" and "No notices". This needs a human to revoke the grant, recover, and watch the dot.
- Ticketmaster `get_task` returned "Task not found" for TASK-455 on this Mac.

### TASK-453 ⌘A/⌘C/⌘V in Library search: PASS (ea9b4af)
- Typed `hello453`, then ⌘A and ⌘C: the pasteboard read `hello453`.
- Cleared the field, put `SENTINEL453` on the pasteboard, then ⌘V: the field read `SENTINEL453`.

## 2026-11-18: TASK-460 recheck on obrien-460 @ 5267479 (log only, nothing fixed)

The build used a new bundle ID (`io.github.heilo27.FlotsamWalk460b`) and a fresh scratch home. A streaming `log` capture ran with timestamped markers at each onboarding step.

| Window | BTM events (Flotsam) |
|---|---|
| Launch → steps 1–6 (09:43:13.8 → 09:43:41.275) | 0 |
| Arriving at step 7 | one `userDataDidChange` burst at 09:43:41.804–.824, with BTM "updating item name=Flotsam", ~0.5 s after the first status read (41.309) |
| While step 7 is visible | status is re-read about every 2.1 s; no further events |
| Uncheck Launch at Login (51.07) and Continue (54.67) | 0 |
| Relaunch with onboarding done (09:44:33.8) | 0 |

- **Meets S1's stated expectation:** 0 events on steps 1–6, one on arriving at step 7, 0 on relaunch.
- **The banner still shows:** "Login Item Added" appears on arriving at step 7, before the user touches the checkbox. It stays on screen through the uncheck. The fix moves the banner from step 1 to step 7; it does not remove it. A user who unchecks still sees it.
- **Caveat: this was not a first registration for macOS.** BTM already held an app item named Flotsam (`2.Flotsam`) from earlier walk builds. It re-pointed that item's path to the new build. A clean first-registration test needs a different PRODUCT_NAME as well. `launchctl print` does not show this BTM item. It was left in place: it was created by an earlier walk build and has no launchd job.
- **Control build:** not run, because nothing fired before step 7.
- **End state:** no Flotsam process is running. The walk prefs domains are removed. The real DB, -wal and prefs hashes are unchanged (03fc64cf…, c1189741…, f20f539d…).

## 2026-11-18: TASK-460 first-sight BTM test on obrien-460 @ 5267479

The method changed from the request. A PRODUCT_NAME override breaks the build ("Multiple commands produce …bundle/Contents", because the package resource bundles take PRODUCT_NAME too). So each copy was built with a bundle-id override only (`io.github.heilo27.flotsam.btmtest1` / `btmtest2`). The built .app, its executable, CFBundleName and CFBundleDisplayName were then renamed to FlotsamBTM1 / FlotsamBTM2 and ad-hoc re-signed. No source change, nothing committed. No `sfltool resetbtm` or other machine-wide action.

**Results**
- (a) Arriving at step 7, nothing touched: **no banner and no register call.** The log shows only status reads (3 = not found), about every 2.1 s.
- (b) Uncheck, then Continue (BTM1): no BTM event, no banner, no item.
- (c) Check, then Continue (BTM2): `registerLaunchItem` fired 41 ms after Continue, the banner request followed 6 ms later, and status went to 1. A "FlotsamBTM2" banner was shown.
  - A clean unregister was possible: Settings › Launch at Login OFF → `unregisterLaunchItem`, status 0.
  - After quit, `launchctl print gui/501 | grep -i flotsam` is empty.

**This corrects my Check 1 and 1b entries.** A persistent "Login Item Added: Flotsam" banner from earlier walk builds (BTM item 2.Flotsam) was still on screen when Run A started. Dismissing it removed that notification request, which proves it was stale. The "banner on arrival at step 7" I logged for 5267479 was most likely this stale banner, so treat it as unreliable. On a never-seen name and bundle id, 5267479 registers only on Continue with the box checked.

**2.1 s status-read caller:** `App/Flotsam/OnboardingView.swift:26-31`.
- It is a `.task` loop: `model.refresh()`, then a 2 s sleep. `didBecomeActive` at :32-34 also triggers a refresh.
- `refresh()` is at `OnboardingModel.swift:39-45`. It is gated by `Onboarding.swift:60` (`readsLoginStatus`, step == .loginItem).
- It reads `SMLoginItemService.swift:7-8` (`SMAppService.mainApp.status`).

**Caveats**
- `sfltool dumpbtm` timed out (rc 142). The pre-launch "no item" check rests on the BTM log ("record not found") and launchctl.
- A system `userDataDidChange` burst at 09:50:17 during Run A steps 1-6 has no app-originated register call; its cause is unknown.

**End state**
- Both apps have quit, and both test domains and plists are deleted.
- No FlotsamBTM1/2 BTM item is left. The old 2.Flotsam item was left untouched.
- Real DB, -wal and prefs hashes match the baselines: 03fc64cf…, c1189741…, f20f539d….

## 2026-11-18: FRD-005 8T, OC-5137 per S1 ruling (FR-007-10 wins)

Branch `s2/frd005-8t` is at **5ce3c78**.
- 45f5c3b: the known-issue wrapper is gone.
  - The test now asserts that an immediate second sweep after the trigger is cleared keeps the item. The existing companion test asserts kept at exactly 24 h, gone 1 ms later.
  - Mutation: with the grace removed in `Exemption.autoDeletableSQL`, the new test goes red. Reverted.
- 5ce3c78 merges origin/main, which brings in 89866d2. Merged, not rebased: no force-push.
- Full run of FlotsamCore after the merge: **2664 tests, 0 failures, 15 known issues**, exit 0.

**Exact 24 h boundary.** The 89866d2 contract line says "a sweep 24 h or more after the clear removes it". FR-007-09 says eligible when `exemptReleasedAt` is "older than 24 h", which is a strict comparison. The code (`exemptReleasedAt < now-24h`) keeps the item at exactly 24 h. The test follows the FRD and the code. The contract line should say "more than 24 h" (contract drift, OC-5137).

## 2026-11-18: 3× full-suite runs: torres-447 @ db9f24f, obrien-461 @ 986bea7 (verify only)

Fresh clone for each target. The runs used `swift test --package-path Packages/FlotsamCore` with the build cache kept, so run 1 is cold and runs 2-3 are warm. The two targets ran one after the other, with no other S2 tests running at the same time.

| Target | Run | Exit | Tests | Failed | Known issues | Wall | 1-min load min/max |
|---|---|---|---|---|---|---|---|
| 447 | 1 (cold) | 0 | 2540 | 0 | 15 | 118 s | 28.5 / 70.1 |
| 447 | 2 | 0 | 2540 | 0 | 15 | 68 s | 44.9 / 74.1 |
| 447 | 3 | 0 | 2540 | 0 | 15 | 68 s | 45.9 / 68.7 |
| 461 | 1 (cold) | 1 | 2544 | 1 | 15 | 114 s | 26.6 / 65.3 |
| 461 | 2 | 0 | 2544 | 0 | 15 | 69 s | 41.5 / 77.2 |
| 461 | 3 | 0 | 2544 | 0 | 15 | 67 s | 41.4 / 70.5 |

- **One failure, on 461 run 1:** `SystemClockTests.swift:64:9`, in "cancelling during a 10 s sleep wakes it early" (OC-0077). The failed expectation is `outcome.elapsed < .seconds(1)`, a wall-clock bound. It passed on runs 2 and 3. Load was very high during that run. That load is the likely cause, but this is not proven.
- **Watched locations:** no issue recorded in any of the 6 runs, checked by grepping every log for "recorded an issue at".
  - FRD002GapTests218_219:103
  - Task456ImportRecentFailureTests:147
  - ClipboardLateWriteTests:67-148
  - FRD002GapTests220:171/198
  - FRD001ContractPart2Tests:681
  - ThumbnailMemoryTests:23
- **`bin/check-architecture.sh`:** exit 0 on both targets ("architecture checks passed").
- **Machine load:** this Mac was heavily loaded the whole time. The 1-min load average ran 27-77 on a machine that normally sits far lower. Afterwards the top processes were `bird` (iCloud Drive) at about 52 % CPU and `backupd` (Time Machine) at about 50 %. Read the timing tests in these runs as being under stress.
- Nothing was fixed or committed. The clones are kept in the session scratchpad.

## 2026-11-18 · 3× full suite on origin/obrien-461 @ b6f83ec (S1 request; replaces the stale 986bea7 runs)

- **Result:** 3 of 3 runs green. `swift test --package-path Packages/FlotsamCore` exited 0 every time.
  - No `recorded an issue` lines.
  - 15 known issues per run.
  - Wall time 66-75 s.
  - Tests per run: 2562. This is the sum of the "Test run with N tests" lines after stripping ANSI. The run agent reported 2547, so one of the two counts double-counts something; I'm not resolving it here.
- **FRD002GapTests220:198:** no issue recorded in any run. The TASK-220 suite ran and passed all 3 times.
  - b6f83ec does NOT contain main's TASK-459 merge: torres-459 merge 359cd18 and worf-459 merge 01fed85 are both outside it (`merge-base --is-ancestor` = 1).
  - So these runs say nothing about the fix. The flake simply did not show up here.
- **SystemClockTests:64 (TASK-462):** no occurrences.
- **`bin/check-architecture.sh`:** exit 0.
- **Load:** 1-min load ranged 3-93, mostly 40-75. No other swift-test, swift-build or xctest was running during the runs.
- Nothing was fixed or committed. Logs are in the session scratchpad (`runs/461b-run{1,2,3}.txt`).
