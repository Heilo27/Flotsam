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
