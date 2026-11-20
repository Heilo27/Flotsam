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

### Correction to the b6f83ec entry above (5520b21)
- The correct count is **2547 tests per run**, as the run agent reported.
- My "2562" was an awk bug. It also added the N from "with N known issues" and "with N issues" on each summary line, so it overcounted by 15.
- Every other figure in that entry stands.

## 2026-11-18 · FRD-005 8T (Shortcuts and Triggers) complete on s2/frd005-8t, ready for S1

- **Branch:** `s2/frd005-8t` @ 1d8c1a0, pushed. It merged origin/main at 5ce3c78 (which includes contract fix 89866d2). It does not include main 01fed85 (TASK-459).
- **Commits:** 85561e0, 13eaf18, 83c6ad2, 5853044, 76a41a6, d02670e, 251d91b, 0621ff4, 62ac018, ccf5797, 45f5c3b (OC-5137), 5ce3c78 (merge of main), 5c175c6 (S9 remainder), 77a9148 (Triggers gap tests), 19c8c04 (editor citations, OC-5055 test), 1d8c1a0 (serialized the OC-5134 editor test).
- **Slices:** S1-S9 follow the plan. The OC counts per slice were 11/16/11/7/11/15/19/14/8.
  - Each slice had one mutation check. Each one turned the named test red and was then reverted with `git checkout`, leaving no source diff. The mutations:
    - S1 ChordValidator accepts a reserved letter → 5006/5007 red
    - S2 `bind(.openLibrary, to: nil)` succeeds → 5003 red
    - S3 ItemHotkeyAction skips the permission check → 5028 red
    - S4 saveClipboardNow keeps Concealed → 5036 red
    - S5 max length 24→25 → boundary OC red
    - S6 tap starts without Input Monitoring → 5064 red
    - S7 secure input is no longer treated as suppression → 5091 red
    - S8 `{clipboard}` re-expands → 5116 red
    - S9 `hasShortcut` and `ShortcutRegistry.remove` mutations → 5060 and 5134 red
    - gap slice: drop `resetSignal.request()` in `TriggerEngine.systemDidResume` → `oc5125WakeClearsTheWord` red (3 issues)
- **Coverage (145 OCs):** 119 are covered by a test and 21 are cited to existing tests, leaving 5 untestable at package level and 0 uncovered.
  - Cited: 5054, 5056-5059, 5061, 5063, 5076-5079, 5081-5083, 5101-5106, 5108.
- **Full run at 1d8c1a0:** 2678 tests, verified by summing the 12 summary lines by hand. 15 known issues, unchanged from the baseline.
  - The only failure is OC-5055, with 3 issues: the help line lacks `{date}`, `{time}` and `{clipboard}`.
  - S1 ruled that this is a product bug, **TASK-463**, expected until obrien-463 merges. It is a plain assert, with no `withKnownIssue`.
- **Flake fixed in test code:**
  - The OC-5134 editor test failed 2 of 3 parallel runs. A recorder's key monitor covers the whole process, so a key press reached another suite's recorder.
  - The test now nests under the serialized `WorfEditorRecorderTests`. It passed 6 of 6 parallel runs.
- **Resolved:**
  - OC-5137: per S1, FR-007-10 wins, so the 24 h release grace is asserted. A wording drift remains at the exact boundary: the contract says "24 h or more", while FR-007-09 and the code keep the item at exactly 24 h.
  - OC-5055: product bug, TASK-463.
- **[Spec Drift], nothing edited:**
  - OC-5099 is contract drift (D3). The contract makes it conditional; the FRD wins.
  - OC-5108: the oracle predates FR-005-16; the test follows the FRD.
  - D1: the OC-5036/5037 tags sit on FR-005-16 clipboard tests that assert OC-5108 behaviour.
- **Untestable at package level, with the missing seam:**
  - 5020: no permission probe on `ShortcutRegistry` for Carbon registration under denied TCC.
  - 5021: the real registrar teardown at `applicationWillTerminate`.
  - 5100: CGEventTap timing of 10 ms or less, observed from a second process.
  - 5131: a timing harness over the real Carbon hotkey and CGEvent post.
  - 5132: a launch benchmark in the App target.
- **Real-app halves only (the package half is tested):**
  - 5055: opening via the popover or NSMenu
  - 5086: "no line break" in a real document
  - 5098: the Messages compose field
  - 5120: a real NSTextView
  - Plus earlier ones: 5141, the 5117 drag, 5119, 5142, the 5094 Settings UI, the signpost halves of 5127/5130, and the S5 saved/badge half.
- **Next:** FRD-004 8T on a new `s2/frd004-8t` from current origin/main.

### S1 rulings on the FRD-005 entry (2026-11-18)
- **OC-5137 is not drift.** The contract on main now says "a sweep more than 24 h after the clear removes it … exactly 24 h keeps it". That matches FR-007-09 and the code.
  - `oc5137_graceBoundary` already asserts that the item is kept at exactly 24 h and gone 1 ms later, so no test change is needed. I've withdrawn the boundary-drift note.
- **OC-5099, OC-5108 and the OC-5036/5037 tags:** S1 agrees the FRD wins. S1 has ticketed the oracle cleanup.
- **Merge order (S1):** obrien-463 (TASK-463) merges first, once its Worf QA passes, including against our OC-5055 test. s2/frd005-8t follows.

### s2/frd005-8t ready to merge @ 5c427a9 (2026-11-18)
- Merged origin/main 20676e0 (TASK-463) into the branch as 5ab44cd. No conflicts.
- 5c427a9: both OC-5055 tests now use `SettingsString.editorVariablesHelp` and assert the key `ui.settings.editorVariablesHelp`. The TASK-463 pending comment is gone.
- `swift test --filter 5055`: 2 tests in 1 suite passed.
- Full `swift test` (Packages/FlotsamCore): exit 0. 2697 tests across 12 runs (sum of the "Test run with N tests" lines only), 0 failures, 15 known issues (1 + 5 + 9). No "recorded an issue" lines.
- `bin/check-architecture.sh`: passed.
- Pushed as a plain push. Handed to S1 to merge.

### S1 ruling: TASK-458 / SET-DAT-001 (2026-11-18)
- The SET-DAT-001 from the folder-bookmark launch argument is a harness artifact, not an app defect. A bookmark made outside the app, or made without `.withSecurityScope`, cannot resolve with scope (NSCocoaError 259). The app's own `choosing()` round trip resolves as usable (OC-8065). No scope-less fallback will be added.
- From now on, smoke runs set the screenshot folder override through the app (the Settings UI or onboarding), never with a hand-made launch-argument bookmark. That SET-DAT-001 is no longer logged as a defect.

## 2026-11-18: FRD-004 8T on `s2/frd004-8t` @ 5e1ec4e (cut from main 35f59ff)
- **Slices:**
  - S1 Tags: a6cd32d, 17 tests.
  - S2 NoteEdit: 37ee5f1, 16 tests.
  - S3 DeleteUngroupSort: 8a1b38d, 16 tests.
  - S4 Library: de3b028, 24 tests.
  - Remainder + OC-4099 + OC-4073 + Gaps: 5e1ec4e.
- **Mutations, each reverted and the source left clean:**
  - `Tags.swift` `<` → `<=`: OC-4018 went red.
  - `Ungroup.swift` `- index` → `+ index`: OC-4074 and 4078 went red.
  - `LibraryQueries.swift` `pasteCount DESC` → `copyCount DESC`: OC-4091, 4094 and 4098 went red.
  - `LibraryOrganizer.canUngroup` `== 1` → `!isEmpty`: OC-4072 went red.
- **Coverage (109 ids, checked mechanically):** 98 tested, 5 cited-only (4002, 4008, 4010, 4079, 4103), 6 untestable-only (4026, 4028, 4041, 4042, 4052, 4054), 0 uncovered. Another 15 tested ids have an App-only half, each listed in the Gaps file as a `.disabled("no seam: …")` test.
- **Full run on the branch:** exit 0. 2658 tests (sum of the "Test run with" lines only), 17 known issues, 0 failures, 0 "recorded an issue". Arch passed.
- **Merge check:** the branch is 41 commits behind main and merges cleanly (merge-tree check).
- **[Spec Drift], nothing edited:**
  - OC-4073: the contract key `organize.confirm.ungroup` against the FRD key `ui.organize.confirmUngroup`.
  - OC-4053: `organize.edit.formattingRemoved` against `ui.organize.editFormattingRemoved`.
  - In both, the FRD key is asserted and the contract key is wrapped in `withKnownIssue`.
- **Copy note, not a defect:** the delete-tag confirmation reads "1 items" at n = 1. FR-004-04 gives the wording literally as "… from {n} items?", so a singular form would need an FRD change.
- **Missing seam:** the OC-4031 0-item no-confirm decision sits inline in `OrganizeCoordinator.deleteTag`. Suggested seam: `LibraryOrganizer.deleteTagNeedsConfirmation(itemCount:)`. The App target has no test target, which blocks the OrganizeCoordinator overlays and the hotkey halves.
- **Defects:** none found in production code.
- **Process note:** the commits' Co-Authored-By trailer says Sonnet 5.5, which is the model that wrote them, rather than the Opus 5.5 line in the brief. They are left as they are, because no force-push is allowed.
- **Next:** FRD-000 8T on a new `s2/frd000-8t` from current origin/main.

## 2026-11-18: FRD-000 8T on `s2/frd000-8t` @ 0f2ad26 (cut from main ee59355)
- **Slices:**
  - S1 Fatal: 199982a, 8 tests (OC-0008, 0009, 0010, 0069, 0070).
  - S2 Catalogue: 6adee52, 6 tests (OC-0017, 0033, 0048, 0074, 0075).
  - S3 Gaps: 0f2ad26, 13 disabled no-seam stubs plus the CITED header.
- **Mutations, re-run by S2 itself because the agent's results were lost to compaction:**
  - `FatalAlert.nearestExistingFolder` changed to `return folder`: OC-0009 ×3 and OC-0069 went red, 6 issues.
  - `URLSession.shared` added to FlotsamBase: OC-0048 went red.
  - Both were reverted and the tree is clean.
- **Coverage (77 ids):** 10 tested, 63 cited, 4 untestable (0025, 0054, 0055, 0056 UI half), 0 uncovered.
  - Caveat: a cited id was counted when an existing test or suite title names it. Nobody re-checked that each of those 63 asserts the behaviour.
  - OC-0056's data half rests on `tagNameBoundary`, which does not carry the id.
- **Full run on the branch:** exit 0. 2740 tests, 17 known issues (1 + 5 + 11), 0 "recorded an issue". Arch passed.
- **Defect (Major): OC-0017, plurals.**
  - FR-000-05 requires plural and count variations to use catalogue variations. `ui.settings.clearDone` has none, so it reads "1 items deleted".
  - The test is wrapped in `withKnownIssue` until S1 rules.
  - The same class, untested:
    - "%lld items"
    - "Delete %lld items permanently?"
    - "Remove tag '%@' from %lld items?" (FRD-004)
    - "This permanently deletes %lld items…"
    - the "older than" template
- **Correction to the FRD-004 entry:** the delete-tag "1 items" IS a defect under FR-000-05. FR-004-04's literal "{n} items" is the template, and FR-000-05 makes it plural-aware. It is not a copy-only note.
- **Untestable, with the seam each needs:**
  - OC-0025: a pure HUD placement function plus a clock.
  - OC-0054: an injectable VoiceOver announcer.
  - OC-0055: a pure `Notice.menuTitle` in FlotsamBase.
  - OC-0056: the inline error view lives in the App target.
- **[Spec Drift]:** none.

## 2026-11-18: FRD-007 8T on `s2/frd007-8t` @ 173f6f1 (cut from main c0382e8)
- **Slices:**
  - 315e5b0: OC-7062/63/65, 7080/81/85/88, 7109, 7125, 7151.
  - 4c0ed68: OC-7102 to 7105, 7107, 7108.
  - 43b4de7: OC-7115, 7116.
  - 3e22fdd: OC-7126, 7150.
  - 31a52c7: OC-7127.
  - 930cf96: comments only.
  - 173f6f1: the Gaps file, with 17 disabled no-seam stubs.
- **Mutations, all red and reverted, one per slice:**
  - ImageBudgetEnforcement eviction target
  - ClipboardCapture gate `|| true`
  - FlotsamDatabase migrate-log `if false`
  - IngestActor copyCount `+0`
  - ItemDeletion `where false`
  - PasteService delete skipped
- **Coverage of 153 ids:** 21 tested here, 130 cited, 2 untestable-only (7011, 7152), 0 uncovered (checked by grep script).
- **Recon correction:** S2 first reported 62 untagged ids. That came from a grep that only matched OC-70xx; the real number was 13.
- **Full run on the branch:** exit 0. 2866 tests in 12 runs, 20 known issues, 0 "recorded an issue". S2 re-summed this from the log. Arch passed.
- **Defect (Minor), OC-7088:** `ui.settings.clearDelete` reads "Delete", but FR-007-11 says "Delete {n} Items". It is a known issue. Once fixed it falls under TASK-469 for the plural.
- **[Spec Drift] FR-007-12 vs FR-008-16:** for Curated, the menu item reads "Pause Capture" in FR-007-12 and "Resume Capture" in FR-008-16. The code follows FRD-008. `CaptureMode.afterMenuToggle` and `MenuBarModel.captureToggle` also disagree (Rule 9). This needs a ruling.
- **OC-7105:** the icon label "Flotsam, capture paused" differs from the contract's "Flotsam, paused". No FRD fixes this wording, so it is logged as a known issue marked unverified, not a defect.
- **OC-7127:** the contract conflates moved-file (LIB-DAT-001, item kept) with missing-blob (LIB-IO-001, item deleted). The two are asserted separately.
- **Seams needed:**
  - StorageChangeCoordinator: 7062, 7063, 7080, 7081.
  - Popups or sheet rendering: 7065, 7085, 7109, 7088, 7105.
  - Cross-target Shelf/Capture: 7102, 7103, 7104, 7127.
  - Running app: 7011, 7115.
  - A reveal port: 7152.

## 2026-11-18: Lane A, A1 + A2 on `main` @ 5ad05df

- Fresh clone, fetched at start; 5ad05df was still the tip after a final fetch.
- No code fixed, nothing committed.

**A1**
- bootstrap: exit 0.
- `swift test`: 2880 tests in 12 runs. 0 failures (no "recorded an issue" lines). 16 known issues (5 in one run, 11 in another).
- Delta vs 10596ad: +530 tests (2350 → 2880). Runs unchanged at 12. Known issues up by 7 (9 → 16), from the 8T merges that landed since.
- No timing flake, even at load average 105–185.
- `bin/check-architecture.sh`: pass.
- `bin/build.sh Debug`: BUILD SUCCEEDED with 1 warning, the same one as before. It moved to `ClipboardCapture.swift:118:27` ("result of call to 'assumeIsolated' is unused").

**A2** (bundle id `io.github.heilo27.FlotsamWalk`, scratch CFFIXED_USER_HOME, empty prefs domain)

| Check | Result |
|---|---|
| Launch, menu bar | PASS. 8 actions: Open Library, Save Clipboard, Toggle Shelf, Pause Capture, Notices, Settings…, Show Setup Guide…, Quit Flotsam. |
| Onboarding | 8 steps. Launch at Login is pre-checked on step 7 (left alone; Ryan's call). The agent passed step 7 with it still checked, then went Back and unchecked it. No Flotsam login item at any point. |
| text | PASS, `text`, copyCount 1 |
| URL | PASS, `link`, copyCount 1 |
| image | PASS, `image`, 64×64 PNG stored at 8382 B (15638 B on the pasteboard) |
| concealed | PASS, CAP-POL-001 skip; nothing stored; 0 hits for the secret in the scratch data folder |
| file ×5 | PASS. 1 item: stored once, deduped ×4, copyCount 5, 1 bundleMember row |
| first reads | One CAP-VAL-001 at launch; no CAP-PRM-001 |
| Quit | PASS, no process left |
| crash reports | 28 → 37. All 9 new reports are AccessibilityControlsExtension / UsageTrackingAgent; none from Flotsam |

- New observation, not called a defect: `screenshot.scan count=0 outcome=failed` at launch. The scratch home has no Desktop folder, which is a likely harness artifact. 10596ad's entry did not record this line.
- Real files, before and after, unchanged: DB 03fc64cf…, -wal c1189741…, prefs f20f539d….
- Cleanup:
  - `launchctl print gui/$UID | grep -i flotsam` is empty. Re-checked by S2 after the agent finished.
  - FlotsamWalk prefs domain and plist deleted. Scratch home deleted.
  - No sfltool left running. `sfltool dumpbtm` hung, so BTM was not checked directly.

## 2026-11-18: Lane C, TASK-457 items 2 and 3 on `s2/task457` (base 5ad05df)

Item 1 (the ScreenshotWatcher race) is S1's and is not touched here.

| SHA | Change |
|---|---|
| a052762 | `ClipboardCapture.swift:118` now reads `MainActor.assumeIsolated { _ = self?.applyMode() }`. `applyMode()` returns a `Bool?` result, so behavior is unchanged. The other `assumeIsolated` sites give no warning and were left as they are. |
| 36a7318 | TASK-229 gap. `PerfInterval.screenshotImport = "screenshot.import"` added to `Signposts.swift`, the one home for the interval names. It wraps `ScreenshotImporter.run` with a begin and a `defer` end, so every outcome is timed (skipped, unstable, rejected, failed). |

**36a7318 also changes the FRDs in the same commit:**
- FRD-000 FR-000-12 lists the 9th interval.
- FRD-000 AC-000-07 now says "nine".
- FRD-000 change log updated.
- FRD-002 FR-002-14 names its signpost.

**Test (36a7318):** `ScreenshotImportSignpostTests` reads the real signpost stream for 3 cases: an imported file, a vanished file and a symlink.
- `SignpostProbe` was moved into a shared file and symlinked into the Screenshots tests, the repo's existing pattern for sharing test files.
- The probe only counts intervals begun inside its own time window.
- It now reads only the newly added log bytes. Re-parsing the whole log hung the target-wide run past 60 s.

**Mutation:**
- Remove the begin and the `defer`: the test fails on the begun count.
- End the interval only on success: the test fails on begin/end pairing.
- Both were restored afterwards.

**Gates:**
- arch: PASS.
- `swift test`: 2881 tests (+1 vs 2880), 12 runs, 16 known issues (unchanged).
- 1 failure in the full run: `OC-7098 Clear History … inside 5 s` (Unmapped007IngestTests). It is a timing flake under load and passes when run alone.
- `bin/build.sh Debug`: 0 compiler warnings. The only "warning:" line is the AppIntents metadata note.

**Found, not fixed:** the header comment in `FRD002AuditBTests.swift` still says signposts have no test seam. `SignpostProbe` now provides one.

## 2026-11-18: TASK-477, OC-5133 root cause, on `s2/task477` (base bc8cf82)

**Verdict: test-timing defect, not a product race.**
- The "extra" write is the first expansion's own clipboard restore, its write #2 ("previous clipboard"). It comes from `ClipboardPreserver.restore` (ClipboardPreservation.swift), via `PasteExpansion.finish`, which is `TriggerExpander.expand` step 8.
- The test's `writesBefore` snapshot was taken after `eventually { writtenTexts.contains("gone text") }`. That condition is met after the first write, so the restore landed 3–10 ms later under load.
- The first expansion's ⌘V lands late in the same way. That made line 133, the `keys.actions.count` check, flaky too.
- The post-delete ';del' is ruled out as the source. In every instrumented failure, `decision == .pass` and the only writes were the expansion write and the restore.

**Fix, 7615768 (test only, no FRD change):**
- A new `expansionSettled` helper waits for the paste to be posted and the previous clipboard to be restored.
- It waits for that both before the baseline snapshot and after the ';keep' expansion.
- It asserts the baseline exactly: 2 writes, 2 key actions.
- The no-write and no-key checks moved to after ';keep' settles. Events are handled serially, so any expansion from the deleted ';del' would already show up in the totals. The old checks, taken straight after the Space, passed whether or not it fired.
- The new end-state checks are `writtenTexts == ["gone text","kept text"]`, writes == before+2 and keys == before+2.

**Mutation:** skip `store.remove(itemIds:)` in the `.itemsDeleted` handler. The test goes red at decision == .pass, at keys == before+2, and at triggers.count == 1. The write-count check alone does not catch this, because once the item is deleted the expansion posts keys but writes nothing. Reverted.

**OC-448-W8: unresolved.**
- It passed 60/60 alone under 10× `yes` load, and 3/3 in the gate runs.
- The original failure text could not be recovered. Line 108 is the `@Test` attribute, so a thrown `try` in file setup (WatcherRig, setxattr, setAttributes) is likely.
- It is probably a different cause from OC-5133. That is unproven, so it is left unchanged.

**Gates:**
- arch PASS.
- 3 consecutive full `swift test` runs under load: 2976 tests each, 0 failures, 19 known issues each. Load average at start 16 / 78 / 88, reaching 133 at the end.
- `build.sh Debug`: 1 warning. It is the known ClipboardCapture:118 one, already fixed on `s2/task457`, which is not in this base.

**Report only:** `TriggerEngine.run()` discards `ExpansionOutcome`, so tests have no engine completion signal. They infer the end of an expansion from the pasteboard instead.

## 2026-11-18 — TASK-479 + TASK-480 (tests only) — s2/task479 @ 378506c (base main df2c641)
- Commits: 29a228c TASK-480, 378506c TASK-479. Diff: 8 files under Tests/FlotsamScreenshotsTests only (+92/-23). No product code changes. Task457WatcherRaceTests.swift and ScreenshotWatcher.swift untouched.
- TASK-479: importRecentCount() now goes through importRecentWithin(10 s). Task456:73/:77, OC-2020/2041/2055/2059/2060/2071 and OC-448-W7 are bounded, and a nil (timeout) records an issue. Extra unbounded sites found and bounded: Worf446ImportHUDTests, Worf456RaceTests, ScreenshotWatcherTests ~:419-432. New helper: importRecentAnnouncingWithin. Stale header at FRD002AuditBTests:13 corrected (signposts now have a seam: SignpostProbe).
- Hang mutant (the press never resumes), `swift test --filter FlotsamScreenshotsTests`: FAILS with 95 issues and does not hang. Wall time is 97 s, OVER the ~60 s target, because each press pays the full 10 s bound and some tests press 2-3 times. Lowering the bound would meet the target; that is S1's call. Mutant reverted, tree clean.
- TASK-480 OC-466-NOPRESS: the async tail is ScreenshotWatcher.finish (~:587-612: ingest, settle, "screenshot.imported" log, complete, pump). The test now waits until 2 candidates and 2 import log lines exist before the snapshot, then asserts 4 distinct names: 2 live copies and 2 press imports. Mutation (no-press path imports) goes red 3/3; reverted.
- Side changes:
  - Worf456Race press now starts via Task.immediate (macOS 26 guard), with the scan held deterministically. A plain-Task variant also passed 40/40, so the stated reason for this change is unproven.
  - ScreenshotImportSignpostTests: added a bounded wait for in-window intervals to end. This fixes a flake that predates this branch (another suite's held import could end after collect's fixed settle).
- Gates: arch OK. 3 consecutive clean full runs under `yes` ×10 load, each 3038 tests / 0 failures / 19 known issues; 1-minute load at start 44.3 / 88.1 / 95.5. An earlier set was restarted after 2 failures; both were diagnosed and fixed as above. build.sh Debug: 0 warnings. Load killed.
- Report-only: pre-existing "no async operations" warnings at `await RaceHUDLog()` in the test files.

## Real-OS matrix, priority 1 (TASK-521 / OC-8024): BLOCKED, screen locked (2026-11-19)

**OS:** macOS 27.3 (26C5035r), not 26. **SHA:** obrien-521 @ f56197f (also the branch tip), Debug build via `bin/build.sh`, build succeeded. Launched isolated per docs/AGENT-LAUNCH.md.

**Blocked:** this Mac's session is locked. `CGSSessionScreenIsLocked` is 1, the frontmost app is `loginwindow` and `screencapture` returns a black frame, so synthetic input reaches no window. The lock was not bypassed. Rows a, b, c, e, f and g need Ryan to unlock the Mac and keep it awake, then a rerun. Priority 2 (origin/main) is not started for the same reason.

**Row d is a partial pass.** No Dock icon: the activation policy is accessory and `lsappinfo` reports the type as UIElement. "No focus steal" is unproven, because `loginwindow` was frontmost before and after launch.

**Probable defects (code read, not run):**
- **g:** nothing deminiaturizes Settings. `WindowFrontAdapter.swift:27-30` (App) calls only `orderFrontRegardless` and `makeKeyAndOrderFront`. `SettingsWindowDriver.open` (FlotsamBase/Settings/SettingsWindowDriver.swift:51-59) calls only `bringToFront`. The window is `.miniaturizable` (SettingsWindowController.swift:29). Repro: open Settings, press ⌘M, then press ⌘, or choose the status-item "Settings…" row. Settings probably stays in the Dock.
- **f:** the follow-up check at FlotsamBase/Ports/WindowFronting.swift:55 forces activation whenever the window is open and Flotsam is not frontmost after 200 ms. It cannot tell a refused activation from the user switching to another app inside the grace period.

**Snapshot identity:** the real Flotsam was not running. The 16 real data files (sha1), the prefs plist and the `defaults read` hash were identical before and after. The pasteboard was empty throughout and never written to. The isolated instance was stopped, and its suite plist (written under ~/Library/Preferences despite CFFIXED_USER_HOME) was deleted. No TextEdit document was opened.

**Harness notes for the rerun:** call `/usr/bin/log` explicitly, because zsh's `log` builtin hides it. `CFFIXED_USER_HOME` does not redirect `cfprefsd` suite writes.

## Real-OS matrix, priority 1 rerun (TASK-521): PASS, a–g (2026-11-19)

**OS:** macOS 27.3 (26C5035r). **SHA:** obrien-521 @ 1f20a8c. Debug build via `bin/build.sh`, launched isolated per docs/AGENT-LAUNCH.md. The screen was unlocked and `caffeinate -d` was running.

**Results:**
- **Rows a–e:** PASS. Row d's partial from the last run is now a full pass: no Dock icon and no focus steal.
- **Row f:** PASS.
  - With a switch to Finder inside the 200 ms grace (at +60 ms and +120 ms, 3 runs each), Finder stayed frontmost 6/6 and Flotsam never took front.
  - The no-switch control brought Flotsam forward 3/3.
  - Caveat: the +120 ms switches landed 175–191 ms after the key, near the edge of the grace. Flotsam's own request time was not measured.
  - Two earlier invalid runs were discarded: in one the Library wasn't open; in the other the harness printed nothing.
- **Row g:** PASS 3/3. A miniaturized Settings deminiaturizes and comes on screen, Flotsam is front, and Settings is key. The f56197f code-read defect is fixed.

**Observation, not a defect:** with Settings miniaturized and the Library open, ⌘, leaves the Library panel open above Settings. With Settings closed, the Library closes 3/3. Whether FRD-008 requires it to close was not checked.

**Snapshot identity:** the real Flotsam never ran. The 16 real data files (sha1, including the DB, -wal and -shm), the prefs plist and the `defaults read` hash were identical before and after. The pasteboard was empty at start and left empty. The TextEdit scratch document was deleted unsaved. Only own PIDs were killed. The suite plist and temp data dir were removed.

**Priority 2** (origin/main 669e1e1) is next.

## Real-OS matrix, priority 2 — origin/main @ 669e1e1 (2026-11-19)

**Setup:** macOS 27.3 (26C5035r). Debug build, unsigned, launched isolated per docs/AGENT-LAUNCH.md.

**Results**
- **Row 1, shelf drag:** PASS. Dragging in, out, and onto an untitled TextEdit document leaves no duplicate history entry.
- **Row 2, relaunch reopens the last Settings pane (FR-008-03):** PASS.
- **Row 3, Library window:**
  - Over a full-screen app, and the toggle: PASS.
  - Across multiple Spaces: needs Ryan. The Space-switch shortcut did nothing, and settings changes aren't allowed in this lane.
- **Row 4, layout and thumbnails (list and grid):** PASS, with candidate defect D1 below.
- **Row 5, spikes:**
  - S-2, S-3 and S-7: PASS. For S-3, Accessibility trust was not confirmed independently.
  - S-4 (text, file and image captured, no privacy warnings): partial. Concealed types were not tested.
  - S-5 (hotkey registers and fires): partial. AX state is unconfirmed and the option-only rule was not tested.
  - S-9: needs Ryan (TCC).
  - S-1, S-6 and S-8: out of lane.
- **Row 6, TASK-116 idle sample at 45 s (Debug only):** PASS on budget.
  - Footprint 51 MB (peak 52) against a limit of 60.
  - CPU 0.0% against 0.2%.
  - About 2.0 wake-ups/s against 2.5, from top's IDLEW column (10 per 5 s), so the margin is thin.
  - powermetrics needs sudo and was not run.

**D1, candidate defect (cause unproven):** the relative-time label on Library rows may go stale while the panel stays open. Related code: `LibraryViewModel.swift:122`, `LibraryRows.swift:15`, `ItemSpeech.swift:34`, `LibraryPresentation.swift:53`. The lead comes from a screenshot only.

**Observations**
- Once, cmd-, opened Settings behind TextEdit. Not explained.
- A synthetic drag that ended over a Terminal window typed text into its prompt. It was cleared with ctrl-U before anything was submitted. This is a harness hazard: future drag rows need an inert drop target.

**Snapshot identity:**
- Before and after are identical: 16 real data files (sha1), the prefs plist, and the `defaults read` hash.
- The real Flotsam never ran.
- Only the session's own PIDs were killed.
- The pasteboard was restored, TextEdit closed unsaved, and the suite plist removed.

## TASK-524 real-OS check: obrien-524 @ 4cfce1f, 6/6 rows PASS (2026-11-19)

**Setup.** macOS 27.3 (26C5035r). Debug build, launched isolated per docs/AGENT-LAUNCH.md, with 3 items seeded. Each row ran 3 times.

**Results**
- **Row 1** (Library open, Settings closed, ⌘,): PASS. The Library hid and Settings came forward on top.
- **Row 2** (Settings open behind an untitled TextEdit, ⌘,): PASS. The Library hid and Settings came above TextEdit. The "Settings behind TextEdit" result seen in P2 at 669e1e1, which predates TASK-521, did not recur in any of the 18 runs.
- **Row 3** (Settings minimized, ⌘,): PASS. The Library hid and Settings came out of the Dock. ⌘M does nothing on Settings (FR-008-19), so the window was minimized through System Events.
- **Row 4** (⌘K, one item selected): PASS. The Library hid and the editor opened.
- **Row 5** (⌘K, nothing selected, via a search with no matches): PASS. The Library stayed up and no editor opened.
- **Row 6** (⌘K, several items selected with ⇧↑/⇧↓, FR-003-08): PASS. The Library stayed up.

**Spec.** The ruling is in FRD-003, FR-003-02 and AC-003-01a, in the diff at 4cfce1f. FRD-008 FR-008-03 and AC-008-03 are unchanged and not contradicted. No drift.

**Not covered.** The key window was inferred from the front app, the window order and screenshots, not read from AppKit. The context-menu route to the editor was not tested.

**Snapshot identity.** The real data, prefs plist and `defaults read` hash were identical before and after. The real Flotsam never ran. The pasteboard was restored, TextEdit was closed unsaved, and the suite plist was removed.

## Spike follow-ups S-4 and S-5: main @ 7482269 (2026-11-19)

**OS:** macOS 27.3 (26C5035r). Debug build, isolated launch. Dummy pasteboard values only.

- **S-4: PASS, 3 runs for each marker.**
  - ConcealedType is stored as a secure row: AES-GCM ciphertext only, no plaintext, no search entry. The Library shows the mask and the source app (FR-001-25, AC-001-25).
  - TransientType and AutoGeneratedType are not stored, and CAP-POL-001 is logged; 6 skips in all (AC-001-04).
  - The dummy string appears nowhere in the DB, the blobs or the log.
  - Not tested: own-write, ignored-source, blank-concealed, remote clipboard.
- **S-5 (option-only rule): PASS.**
  - ⌥Space and ⌥K are each rejected 3/3. The inline error shows, the recorder stays live, and nothing is saved (FR-005-02(a), AC-005-02, FR-005-04).
  - Control: ⌃⌥B is accepted, registered and fires a shelf reveal with no TCC grant, but only with Flotsam frontmost.
  - Firing with another app frontmost was not tested, so FR-008-14 is unverified here. **Needs Ryan.**
- **Snapshot identity:** the real data, the prefs plist and the `defaults read` hash are identical before and after. The real Flotsam never ran. The pasteboard was restored and the suite plist removed.

## S-4 capture gaps: main @ 7482269 (2026-11-19)

**OS:** macOS 27.3 (26C5035r). Fresh Debug build, isolated launch. Dummy pasteboard values only. Each row ran 3 times.

- **Own-write: PASS.** A Library paste-back into an untitled TextEdit document was not re-captured. Each run logged CAP-POL-004 skipped. The item count, copyCount and lastCopiedAt stayed the same, and only pasteCount went from 0 to 1 (FR-001-03, FR-001-04 gate 2).
- **Ignored source: PASS.** `com.flotsam.qa.ignored` was added to privacy.ignoredApps, in the isolated suite only. Copies from that source were not stored, and CAP-POL-002 was logged each time. The non-ignored control was stored 3/3 (AC-001-05 ignored half, FR-008-11, AC-008-06).
  - Not tested: a real copy from an ignored app. The source came from the `org.nspasteboard.source` marker. The pause half of AC-001-05 is also out of scope.
- **Blank concealed: PASS.** ConcealedType was copied as both an empty string and whitespace only, 3 runs each. Nothing was stored, with no secure or blank rows. The app stayed alive, and CAP-POL-001 was logged 6 times (FR-001-04 gate 3).
- **Defects:** none.
- **Snapshot identity:** the real data, the prefs plist and the `defaults read` hash are identical before and after. The real Flotsam never ran. The pasteboard was restored, TextEdit was closed unsaved, and the suite plist was removed.

## TASK-525 relative-time label: obrien-525 @ fbe850f (2026-11-19)

**Setup.** macOS 27.3 (26C5035r). Fresh Debug builds of fbe850f and of its merge base with main, 7482269, used as the baseline. Isolated launch.

- **Row 1, the label advances while the panel stays open: PASS** (FR-003-24, AC-003-20). With the Library held open, the row read "11s ago", then "1m ago", "2m ago" and "3m ago" at about 10, 70, 130 and 190 s. Older rows advanced in step.
- **Row 2, the VoiceOver/AX label advances: needs Ryan.** Reading it requires a TCC grant. The visible label does advance.
- **Row 3, idle cost with the panel hidden** (45 s settle, then a 45 s window): **PASS**, no worse than the baseline.

  | Build | Wake-ups/s | CPU | Footprint |
  |---|---|---|---|
  | fbe850f | 2.00 | 0.0% | 24 MB |
  | 7482269 | 2.02 | 0.0% | 24 MB |

  Wake-ups are interrupt wake-ups from proc_pid_rusage deltas, not top's rounded IDLEW column.
- **Row 4, panel open with a row under 1 min old: recorded, acceptable.** fbe850f: 3.44 wake-ups/s, 0.28 ms/s CPU. Baseline: 2.09 wake-ups/s, 0.02 ms/s. That is about +1.35/s against the roughly +1/s expected; RSS is +0.5 MB.
- **Spec.** FRD-003 adds FR-003-24 and AC-003-20 in the same commit. The FRD says a hidden panel schedules nothing, which agrees with FR-001-20. No drift.
- **Defects:** none.
- **Snapshot identity:** the real data, the prefs plist and the `defaults read` hash are identical before and after. The real Flotsam never ran. The pasteboard was restored, the suite plists were removed and TextEdit was closed unsaved.

## TASK-524 round 2: obrien-524 @ b24af87 (2026-11-19)

**Setup:** macOS 27.3 (26C5035r), Debug build, isolated launch. Each row ran 3 times. Evidence for each run: a screenshot, the front app, the window order and the AX main/focused state.

**Results.** All PASS:

- **Row 1** (Library open, then menu-bar "Settings…"): PASS. The Library hides; Settings comes to the front and is key.
- **Row 2** (Settings minimized, then menu-bar "Settings…"): PASS. The Library hides; Settings un-minimizes and is front and key. Settings was minimized via the System Events AXMinimized attribute, because ⌘M does nothing on Settings (FR-008-19).
- **Row 3** (the six round-1 rows as a regression, covering ⌘, and ⌘K with one, none and several items selected): PASS.
- **Row 4** (⌘K with zero items selected, and with several selected via ⇧↑/⇧↓, "3 selected"): PASS. The Library stays open and no editor opens.
- **Row 5** ("Show Setup Guide…"):
  - From the menu bar: PASS. The Library hides and the guide comes to the front.
  - From the Settings General button with the Library open behind: PASS. The Library hides and the guide comes to the front.

**Run notes**
- Row 4 (several selected), run 2: the first attempt was invalid because the Library was left over from run 1. It was redone from a clean state.
- Row 5 (from the menu bar), runs 2 and 3: ⌘W does not close the guide or Settings while the Library is key, so the guide was closed through its AX close button. Those two runs therefore started with the guide already open behind TextEdit.

**Spec:** FR-003-02 and AC-003-01a were edited in the same commits. FR-008-03, AC-008-03 and FR-005-09 are unchanged and not contradicted. No drift.

**Defects:** none.

**Snapshot identity:** the real data, the prefs plist and the `defaults read` hash are identical before and after. The real Flotsam never ran. The pasteboard was restored, TextEdit was closed unsaved and the suite plist was removed.

## AC-001-05 pause half and a real ignored-app copy: main @ 2e73758 (2026-11-19)

**OS:** macOS 27.3 (26C5035r). Debug build, isolated launch. Each row ran 3 times with distinct dummy texts.

- **Row 1, paused then copying 3 distinct items: PASS.** The count did not change, and every copy logged CAP-POL-003 skipped (9 in all). Covers FR-001-04 gate 1, FR-007-12 and AC-001-05.
- **Row 2, resumed then copying 1 item: PASS.** The count rose by 1 each run, and the copy was logged as stored.
- **Row 3, real copy from an ignored app: PASS.** com.apple.TextEdit was added to privacy.ignoredApps, in the isolated suite only. Selecting all and pressing ⌘C in an untitled TextEdit document stored nothing and logged CAP-POL-002 each run. Covers FR-001-04 gate 4 and FR-008-11.
  - **Control:** with an empty ignored list, the same real copy was stored 3/3, as richText from com.apple.TextEdit.
  - The ignored list was read live, with no relaunch needed.
- **Pause route: needs Ryan.** The pause was set by writing capture.mode to the isolated suite, which the running app picks up live. The menu-bar Pause/Resume item (FR-008-16) could not be driven here: clicking the status item opened no menu. Settings › Storage also needs a hand check.
- **Defects:** none. **Spec drift:** none.
- **Snapshot identity:** the real data, the prefs plist and the `defaults read` hash are identical before and after. The real Flotsam never ran. The pasteboard was empty before the run and empty after. TextEdit was closed unsaved, and the suite plist was removed.

## Spikes S-7/S-3 and perf timings: main @ 2e73758 (2026-11-19)

Setup: a Debug build on macOS 27.3. The app ran isolated (CFFIXED_USER_HOME, a fresh FLOTSAM_DATA_DIR, an agent suite, FAKE_SECURE=1). The 10,000 items were seeded by direct insert on the shipped migrations, not through the capture path. Load average was 19.35 at the start of rows 1–2; rows 3–5 ran at a load of 2.4–5. The numbers are external wall-clock times unless marked as signposts. Release-build numbers may be lower.

- **R1 S-7: PASS.** 5 valid runs; run 1 was invalid and is excluded. The panel was visible in 55–71 ms, and Return pasted in 94–118 ms.
- **R2 S-3: PASS as observed.** All 5 runs logged `shelf.reveal outcome=revealed trigger=drag`. From arrival to visible took 328–364 ms, which includes the 300 ms dwell.
  - **Strict no-AX: needs Ryan.** TCC attributes the process to Terminal, which holds a grant, so "no Accessibility" can't be proven from here.
- **R3 Library open (FR-003-05, budget p95 ≤ 150 ms): PASS (external).**
  - Warm: p50 55.3, p95 73.3, max 92.6 ms.
  - Cold: p50 86.3, p95 95.1, max 97.3 ms.
  - AC-003-04 asks for 50 runs; fewer were run here.
  - The `library.open` signpost covers only the model reload (5 runs: p50 7.7, p95 8.3 ms). It does not span the open-to-visible time the budget names.
- **R4 paste-back (FR-003-19, budget p95 ≤ 150 ms): PASS (external).** From Return to landed: p50 106.9, p95 120.5, max 120.8 ms. The `paste.back` signpost over 6 runs read p50 47.0, p95 53.3 ms.
- **R5 Shelf reveal (FR-006-17 / AC-006-18, budget p95 ≤ 120 ms from dwell complete, 20 runs at 10k): FAIL on the signpost.** Over 20 runs, `shelf.reveal` read p50 164.4, p95 176.3, max 178.9 ms.
  - **Unresolved discrepancy:** externally, arrival to visible was p50 337.4, p95 359.6, max 362.5 ms. Minus the 300 ms dwell, that is 37.4 / 59.6 / 62.5 ms, which is inside the budget.
  - So either the signpost does not start at dwell complete as FRD-006 note 8 says, or the external method misses time. Not diagnosed. The signpost begin needs a code read before this counts as a real perf failure.
- **Not measured:** the drag-start-to-drag-image budget (≤ 100 ms) and the 5 MiB drop-to-card budget (≤ 800 ms) from FR-006-17.
- **Defect: the Shelf sometimes stays visible after a transient reveal.** This happened in R2 run 5 and R5 run 1. It needed 1–5 extra pointer moves to dismiss. Repro rate is low (2 of 25 reveals).
- **Signpost coverage:** log retention kept only the final process, so R3 and most of R4 have no signposts.
- **Snapshot identity:** the real data dir, the prefs plist and the `defaults read` hash are identical before and after. The real Flotsam never ran. The pasteboard was empty before and after, and the suite plist was removed.

## TASK-525/526 real-OS rows: main @ 5bbe312 (2026-11-19): BLOCKED, screen locked

- **Not run: all five rows (R-525a, R-525b, R-526a, R-526b, R-526c).** The Mac's screen was locked: the session reported ScreenIsLocked and the front app was loginwindow. The synthetic-input guard therefore sent no keys or clicks. They will be re-run once the screen is unlocked.
- **Done:** the build at 5bbe312 succeeded, and the isolated launch ran with a fresh DB at schema 2.
- **Specs mapped for the rerun:**
  - FR-003-24 / AC-003-20 (R-525a, R-525b).
  - FR-005-09 / AC-005-08a, with FR-003-22 and FR-003-02 (R-526a to R-526c).
- **Secure item route for R-526a:** a real copy carrying org.nspasteboard.ConcealedType. A direct insert can't create one, because the DB triggers require secureCiphertext.
- **Snapshot identity:** the real data and the prefs hashes are identical before and after. The real Flotsam never ran. The pasteboard is unchanged, and cleanup is done.

## TASK-525/526 real-OS rows, rerun: main @ 5bbe312 (2026-11-19)

The screen was unlocked for the whole run. Each verdict below was read from AX trees and screenshots.

**Input method caveat.** Synthetic HID input and postToPid events never reached Flotsam, so the run used a workaround:
- The Library was opened from the status-item menu.
- Keys were sent through System Events with Flotsam frontmost.
- Right-clicks were HID clicks with Flotsam frontmost.
- Menu rows were pressed with AXPress.

This means the panel ran activated rather than as a non-activating panel, so the real ⌘K and right-click path is only approximated. The synthetic ⌃⌘V also failed to open the Library. That is a lead, not a confirmed defect, and needs Ryan to try the hotkey by hand.

- **R-525a (AC-003-20): PASS.** With the Library open the whole time, both the visible label and the AX label advanced:
  - 58s → 1m → 2m → 3m
  - 58m → 59m → 1h

  The two rows (now-1m20s and now-58m50s) were seeded by SQL into the isolated DB.
- **R-525b (AC-003-20, "given the panel is hidden, then no refresh is scheduled"): PASS.**
  - Hidden for 122 s: CPU time grew 0.01 s per 8 s, the same as the open baseline, and interrupt wake-ups went from 11 to 12.
  - On show, the labels read 5m / 7m / 1h, matching the DB (5.8 / 7.1 / 64.6 min).
  - The watch cancelling on hide was inferred from those numbers, not observed directly.
- **R-526a (AC-005-08a): PASS.** The secure item came from a real ConcealedType copy and showed as a locked row.
  - ⌘K opened nothing and the Library stayed up.
  - The context menu had no "Shortcut and Trigger…" row.
- **R-526b (AC-005-08a): PASS.**
  - Two ordinary items selected: ⌘K opened nothing and the menu had no row.
  - One ordinary item selected: ⌘K and the menu row each opened the Shortcut and Trigger window and hid the Library.
- **R-526c (probe, no verdict):** with the Note overlay open on an ordinary item, ⌘K did nothing. The Library and the overlay both stayed, and no editor opened.
- **Defects:** none confirmed. **Spec drift:** none.
- **Snapshot identity:** the real data and the prefs hashes are identical before and after. The real Flotsam never ran. The pasteboard was restored, and cleanup is done.

## Full pass A1: health on main @ 59340b9 (2026-11-19)

The run used a clean clone.

| Step | Exit | Time |
|---|---|---|
| bin/bootstrap.sh | 0 | 26 s |
| bin/check-architecture.sh | 0 | 2 s |
| bin/build.sh | 0 | 28 s |
| `swift test --package-path Packages/FlotsamCore` | 1 | 19 s |

- **Build:** BUILD SUCCEEDED, with 1 warning: App/Flotsam/AppContainer.swift:188:13 (the immutable value `presenter` is never used).
- **The suite did not compile, so no tests ran.** The only failing target is FlotsamStorageTests; the other 11 test targets compile clean.
  - The errors are all `FlotsamDatabase has no member 'diagnostics'`, known group 4. They are at StorageOpenTests.swift:22, 47 and 63, and at Task497PreMigrationCopyTests.swift:130.
  - A grep finds 16 call sites in 10 files. The other 8 files will fail next: DataFolderLayoutTests, FRD007ContractTestsReliability, QuarantineByteIdentityTests, ReconcileAndMigrationDestructiveTests, StorageEdgeTests, Unmapped007OpenAndFolderTests, Worf484AdversarialTests and Worf497PreMigrationCopyTests.
- **Known groups that did not break compilation:**
  - LibraryContextMenu.entries compiles, because `targetRows` now defaults to `[]` (LibraryContextMenu.swift:23).
  - The toggle-while-opening tests and Task525RelativeTimeTests are runtime assertions. Their result is unknown until the Storage tests compile.
- **Unexpected errors:** none.

## Full pass A2: real-OS smoke on main @ 59340b9, part 1 (2026-11-19)

Isolated Debug build only. The first agent hit its context cap after rows 1 to 4; rows 5 to 12 go to a fresh agent.

- **Row 1, capture: PASS.** Text, link, image (256 and 512 thumbs) and file rows stored. The file came from a real Finder ⌘C; text, URL and image were put on the pasteboard by a script.
- **Row 2, concealed copy: PASS (AC-001-25).** `isSecure=1`, empty plainText, 92-byte ciphertext. The marker had 0 hits (UTF-8 and UTF-16) in the DB, WAL, blobs and the app log; the row shows the mask.
- **Row 3, Library: PASS with a caveat.** Hotkey and menu open and close; search filters; the first Esc clears the query and the second closes. Paste-back lands in TextEdit with no extra item stored. Four double-presses 20 to 120 ms apart each left the Library hidden (AC-003-60); osascript timing is not a precise 50 ms.
- **Row 4, Shelf: placement PASS, drags needs Ryan.** Frame (460,33) 592x140, centred on a 1512 pt screen under the menu bar (TASK-533). A synthetic HID drag from TextEdit did not drop (count stayed 5), so drag in, drag out and the ignored-app drop are unverified.
- **Row 13, quit: PASS (incidental).** Menu Quit exited 0 with no new crash report.
- **Defects:** none. **Spec drift:** none.
- **Harness notes:** `CFFIXED_USER_HOME` does not redirect `defaults write`, so the suite plist lands in the real Preferences folder; use a unique suite name and delete it after. AppleScript to TextEdit fails with -1743, so drive it through System Events. ScreenshotLocationResolver falls back to `homeDirectoryForCurrentUser` (App/Flotsam/AppContainer.swift:344), so the OCR row needs `screenshots.folderOverride`.
- **Snapshot identity:** real data and prefs hashes unchanged; the real Flotsam never ran; the pasteboard was restored.

## Full pass A2: real-OS smoke on main @ 59340b9, part 2 (2026-11-19)

Rows 5 to 12 ran on a fresh isolated instance.

- **Row 5, Compact Library: PASS (FR-003-06).** The sidebar is 170 pt by AX frame at Standard (760x480) and at Compact (520x520). Resizing clamps at the minimum and nothing collapses.
- **Row 6, Settings: PASS.** It opens from the menu and closes with ⌘W. ⌘, from the open Library opens it and hides the Library.
- **Row 7, Shortcut and Trigger editor: BLOCKED, needs Ryan (FR-005-09, AC-005-08a).** System Events treated TextEdit as frontmost while lsappinfo reported Flotsam, so the synthetic ⌘K, context menu and right-click never reached the panel. The 525/526 run had ⌘K working, so this reads as the harness, not the app. Esc and ⌘W were not reached.
- **Row 8, Add Clip: PASS.** One text item was stored with copyCount=1 and isSecure=0.
- **Row 9, capture cue: PASS (FR-001-30, AC-001-46/47/48).** With `capture.cue` on, an 85x28 cue showed for about 1.6 s. With it off there was no cue across 8 samples over 3.2 s, and the item was still captured.
- **Row 10, OCR: NEEDS RYAN.** A security-scoped bookmark written into `screenshots.folderOverride` did not resolve in the unsigned Debug build (error 259). The app reset the key, and the screenshot with the marker word was never imported. Only the real Choose… panel path can set it.
- **Row 11, onboarding: PASS.** On a fresh profile the 8-step Setup appeared and was walked through with Continue, granting nothing.
- **Row 12, memory: INCONCLUSIVE (AC-003-65).** With only 3 text items, phys_footprint was 58 MB with the Library open and 57 MB 30 s after close; RSS was 140.6 then 140.3 MB. The open value is under the 150 MB budget. The S5 condition (10,000 items, 1,000 images browsed, 10 min idle, RSS ≤ 60 MB) was not run; that is TASK-383's measurement.
- **Quit:** exit 0 on all three runs, with no crash report.
- **Defects:** none.
- **[Spec Drift]:** the 170 pt sidebar is hard-coded at App/Flotsam/Library/LibraryView.swift:20, but no FRD or design doc states a sidebar width.
- **Snapshot identity:** real data and prefs hashes unchanged; both test suites were deleted (`defaults delete` left the plist files, so they were removed by hand); the pasteboard was restored.
- **A2 overall:** 9 rows pass. Needs Ryan: Shelf drags (row 4), the editor (row 7) and OCR (row 10). Row 12 is inconclusive against S5.
- **Correction (A2 part 2):** withdraw the [Spec Drift] on the 170 pt sidebar. It was a false positive. docs/DESIGN.md:118 and :120 specify a sidebar of 170 for both the Standard and the Compact layout, so row 5 matches the design. The docs search used a "170 pt" pattern and missed the bare "170".

## Full pass: swift test on main @ f959507 (2026-11-19)

The run used a clean clone, and its git status was empty both before and after.

- **Result:** `swift test --package-path Packages/FlotsamCore` exited 1 after 238 s.
- **XCTest:** 38 executed, 38 passed.
- **Swift Testing:** 3,976 tests in 12 runs; 7 runs passed and 5 failed (FlotsamBase, FlotsamLibrary, FlotsamStorage, FlotsamAppModel, FlotsamShortcuts). 140 issues were recorded, 7 of them known.
- **67 failing tests, all NEW and deterministic.** The five failing modules were rerun twice with `--filter`, and both reruns gave the identical failure set.
- **Clusters below are grouped by test name; root causes are not yet diagnosed.**

| Cluster | Count (approx.) | Example file:line and assertion |
|---|---|---|
| Error taxonomy: retired ORG-VAL-004/005 | ~9 | ErrorTaxonomyTests.swift:108 `raws.count == 63` (actual 65); :114 `ErrorCode(rawValue: "ORG-VAL-004") == nil`; FRD000ContractTestsCatalogue.swift:101-105 |
| Settings registry / FRD-008 window | ~18 | SettingsRegistryTests.swift:33 `actual.count == expected.count` (`registryEqualsTheFRTable`, 22 issues) |
| Task525 relative-time watch | ~15 | Task525RelativeTimeTests.swift:146 `clock.sleeps.isEmpty`; :154 `clock.sleeps.count == 1` |
| Library menu, sidebar, footer | ~10 | LibraryViewModelTests.swift:299 `h.model.filter == .kind(.text)` |
| Window fronting / Task524 wiring | ~6 | Task521WindowFrontingTests.swift:192 `offenders == []`; Task524AppWiringTests.swift:37 source-text match for `guard let id = ids.first else { return }` |
| Storage schema v2 | 3 | Task498SecureClipStorageTests.swift:110 `try userVersion(s) == 2` (not evaluated, so it threw before the check) |
| Shortcut chords | a few | Worf433bTests.swift:60 `commands == [...]` |

- **Close looks:**
  - **`hidingReleasesStorageMemory`: PASS** (LibraryViewModelTests.swift:330-335). It runs the real PanelResidency: LibraryViewModel.swift:126 builds it when none is injected, :327 calls `residency.closed(.library)`, and PanelResidency.swift:34-39 releases when no panel is left open. Only `releaseMemory()` is a counting stub (LibraryFakes.swift:36). **Coverage gap:** no Library test covers the Shelf-still-open case of AC-003-65, and PanelResidency has no direct test there.
  - **`aHiddenPanelNeverSchedulesAWakeup`: FAIL**, deterministic. Task525RelativeTimeTests.swift:146 shows a sleep was scheduled while the panel was hidden, and :154 shows the wrong sleep count after a hide and a release. This is the relative-time watch, not residency.
  - **`doublePressCapturesOnce`: PASS** (LibraryPanelAdversarialTests.swift:250, FR-003-02).
- **Known noise:**
  - KNOWN-TASK-368 (lint harness): 7 known issues, no failures.
  - KNOWN-TASK-372: its suite (Adversarial372ProbeCopyTests) passed.
  - OC-7132 (Unmapped007TimingTests.swift:110): not in the failure set.
  - The 5 OC-2080 known issues at FRD002AuditBTests.swift:364-368 are marked known in the tests themselves.
  - **None of the 67 failures is known noise.**

## Full pass A3: perf on main @ f959507 (2026-11-19)

Debug build, M1 Max, macOS 27.3. Isolated instance (temp home, data dir and suite, FAKE_SECURE=1); screenshots and triggers off, so the idle numbers exclude the folder watcher and event tap. Debug overstates Release. Real DB, prefs and pasteboard hashes are unchanged; cleanup is done.

| Row | Budget | Measured | Verdict |
|---|---|---|---|
| shelf.reveal, empty DB (menu trigger, n=21) | p95 ≤120 ms | p50 27.1 / p95 36.3 / max 40.7 ms | PASS |
| shelf.reveal, 10k DB (menu trigger, n=25) | p95 ≤120 ms | p50 57.7 / p95 75.0 / max 99.3 ms | PASS |
| Idle wake-ups, empty DB, 9 min | ≤2.5/s | 0.13/s | PASS |
| Idle CPU, empty DB | ≤0.2 % | 0.19–0.26 % (cputime delta) | BORDERLINE, Debug |
| Idle memory, empty DB | ≤60 MB footprint | 23 MB footprint (RSS 89 MB) | PASS |
| Panel open, 10k items / 1,000 images browsed | ≤150 MB footprint | 93 MB footprint peak (RSS 185.5 MB) | PASS |
| After close + 10 min idle, 10k DB | ≤60 MB footprint | 61 MiB = 64.0 MB footprint (RSS 177 MB); CPU 0.098 %; 0.018 wake-ups/s | **FAIL (marginal, Debug)** |

- **Memory after close:** the footprint fell from 84 to 61 MiB when the panel closed, but it didn't return to the 23 MB empty baseline. The cause isn't diagnosed. A seeded DB's idle baseline with no panel opened wasn't measured, so I can't separate retained memory from DB-size cost. Needs a Release re-measure before it's called a defect.
- **[Spec Drift]:** PRD.md:25 states the S5 budgets as physical footprint, while AC-003-65 (FRD-003:152) says RSS. By RSS every memory row fails (Debug RSS includes mapped shared-cache pages); by footprint only the after-close row fails. One home for the metric is needed. Not edited here.
- **TASK-556:** the earlier p95 of 176 ms didn't reproduce, but the trigger was different. Neither the dwell trigger nor the drag trigger fired (likely Accessibility isn't trusted on the Debug build; not confirmed), so the dwell-to-reveal span in AC-006-18 wasn't exercised. Needs Ryan or a trusted build.
- **Side effect:** the Debug build registered itself as a login item (macOS showed "Login Item Added: Flotsam", since Launch at Login defaults to on). The agent turned the in-app toggle off. Legacy login items list no Flotsam, and the `sfltool dumpbtm` capture came back empty, so the background-task store wasn't verified. Ryan should check System Settings > Login Items for a stray Flotsam entry. Separately, launch at login defaulting to on for an unsigned dev build is worth a look.

## swift test at ce3d64a (2026-11-19)

Fresh clone at ce3d64a, full `swift test --package-path Packages/FlotsamCore`, no filter, about 5 min wall. It built clean. The exit code wasn't captured, but all 12 Swift Testing module runs passed and the log has no `✘` line.

- **Swift Testing:** 3,977 tests over 12 module runs (the sizes sum to that), 0 runs failed, 0 distinct failing tests. 12 known issues, all marked known in the tests.
- **XCTest:** 19 tests (2 + 6 + 11 across three bundles), 0 failures.
- **Failure list:** `docs/sessions/S2-ce3d64a-failures.txt` has no entries.
- **Vs f959507 (67 failing tests):** fixed 67, still failing 0, newly failing 0. Only 46 of the 67 names still exist in this log, and each of those passed. The other 21 aren't in the log under their old names: they were renamed or rewritten with the spec changes (e.g. "63 live codes of section 7" is now "65 live codes", the ORG-VAL-004/005 retired-code tests became "reinstated"). "Fixed" for those 21 means the old assertion is gone, not that the same test now passes.
- **New failures:** none, so no clusters. No flaky failures, so no `--filter` re-runs.
- **Known noise:**
  - KNOWN-TASK-368: appeared, 7 known issues (TASK-368 lint suites), 0 failures.
  - KNOWN-TASK-372: Adversarial 372 suite ("TASK-372 adversarial: sidecar-less WAL probe copy") passed.
  - OC-7132 (Unmapped007TimingTests): passed this run, no flake.
  - OC-2080 override-folder test: 5 known issues, marked known in the test itself (FRD002AuditBTests.swift).
- **Odd:** the 12 known issues are 7 from TASK-368 and 5 from OC-2080; the earlier Amos figure of 8 known issues doesn't match.

### Corrections (2026-11-19)
- **XCTest at f959507 was 19/19, not 38/38.** The earlier count added both "Executed 19 tests" summary lines. ce3d64a has the same set: 19 tests (2 + 6 + 11), 0 failures.
- **A3 drift resolved:** S1 ruled the S5 budget is physical footprint, and AC-003-65 was fixed at 02b0ce7.
- **Launch at Login on by default is per spec** (FR-008-12, onboarding step 7). I withdraw the "worth a look" in the A3 entry. Only the stray login item from the dev build needs removing.

## A4: Release perf on main @ 02b0ce7 (2026-11-19)

Release (-O, WMO) build, M1 Max, macOS 27.3, unsigned. **Not a true Release:** Release compiles the `FLOTSAM_*` isolation variables out (`#if DEBUG` in LaunchIsolation), so a true Release launch would have used the real data dir, prefs and Keychain. The measured binary is Release plus `SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG`. Other DEBUG-gated code is in LaunchFakes.swift and FlotsamLog.swift (`trace`); its cost wasn't measured. A plain Release build also built clean (exit 0) but wasn't run. Isolated instance (temp home, data dir, own suite, FAKE_SECURE=1), screenshots and triggers off, so no folder watcher or event tap. Methods as A3: `top` IDLEW deltas for wake-ups, `ps` cputime deltas for CPU, `footprint` phys_footprint (RSS for reference). Seed as A3: 10,000 items, 1,000 of them 640x480 images, with thumbnails. One 600 s window per row after the settle, no input; each row is one launch (n=1), not three.

| Row | Budget | Measured | Verdict |
|---|---|---|---|
| (a) Empty DB, no panel ever opened, 2 min settle + 10 min | CPU ≤0.2 %, ≤2.5 wake-ups/s, ≤60 MB | 0.077 % CPU, 0.018 wake-ups/s, 23 MB footprint (peak 23), RSS 86 MiB | PASS |
| (b) Seeded 10k DB, no panel ever opened, 2 min settle + 10 min | same | 0.080 % CPU, 0.033 wake-ups/s, 41 MB footprint (peak 47 at launch), RSS 118 MiB | PASS |
| (c) Library open, all 1,000 images browsed | ≤150 MB footprint | 67 MB footprint peak (RSS peak 157 MiB) | PASS |
| (c) After close, 1 min settle + 10 min idle | ≤60 MB, ≤0.2 %, ≤2.5/s | 47 MB footprint (peak 67), RSS 149 MiB; 0.082 % CPU; 0.002 wake-ups/s | PASS |

- **Footprint after close:** 60 MB at +1 min, 55 at +2 to +4, 47 from about +4.5 min, flat for the last 7 min. The 10-min window started at +1 min, so its first reading (60) is still draining.
- **Residency or leak:** after close, (c) is 47 MB against 41 MB for (b) and 23 MB for (a). Of the 24 MB above empty, 18 MB (75 %) is there without ever opening a panel, so mostly data residency of the 10k DB. About 6 MB (15 %) remains above (b) after the panel closes. It's flat over 7 minutes, which fits allocator or cache residue and not growth, but I measured one open/close cycle only, so I can't rule out growth over repeated cycles. Confidence medium. A3's Debug failure (64.0 MB after close) doesn't reproduce in Release: 47 MB.
- **Vs A3 Debug:** empty 23 MB both; panel-open peak 93 -> 67 MB; after-close 64.0 -> 47 MB; idle CPU 0.19-0.26 % -> 0.077-0.082 %; wake-ups 0.13/s -> 0.018/s. RSS is not comparable to the budget and isn't used for verdicts (it rose from 118 to 149 MiB, mostly clean mapped pages, not checked).
- **Load average (1 min) at window start / end:** (a) 2.92 / 2.00, (b) 2.84 / 1.94, (c) 2.64 / 3.24. The machine is shared; In the 61 one-second `top` samples at the end of each window, %CPU was 0.0 on all 61 for (b) and on 60 of 61 for (a) and (c) (one 0.1).
- **Not run:** dwell and drag (TASK-556), as instructed.
- **Input:** after opening the Library through the menu, the front app was Finder. I set Flotsam frontmost through System Events (activation, not input), which closed the panel once; I reopened it through the menu. The front app was Flotsam and the screen unlocked before every click and scroll; no input went anywhere else. The browse reached the oldest image (Oct 25) and the thumbnail rows rendered.
- **Closed items:** the footprint-vs-RSS drift from A3 is resolved at 02b0ce7 (S1 ruled footprint; AC-003-65 fixed). Launch at Login defaulting to on is per spec (FR-008-12, onboarding step 7), so I withdraw S1's "worth a look" from the A3 entry.
- **Side effect, unattributed:** a "Login Item Added: Flotsam" banner was on screen at 22:19 and still at 22:23. I can't tell who registered it. This instance never ran onboarding or the Settings toggle (it registers only there), and the suite holds no launch-at-login change. The banner may be A3's, left on screen, but that isn't confirmed. `sfltool dumpbtm` hangs here (killed at 100 s), so the background-task store is unverified. Legacy login items list no Flotsam. Ryan should still check System Settings > Login Items.
- **Real state:** real data dir (16 files), real prefs plist and `defaults` hash all match before and after; no Flotsam diagnostic reports. Pasteboard saved (empty) and restored. Instance quit (exit 0), suite plists deleted, no Flotsam running.

## A5: screenshot round 1 at ca738a8, plus prefs cleanup and BTM check (2026-11-19)

- **Verdict: NOT published.** No s2/shots SHA; the branch was not created. All 16 passes reported ok, but two pairs can't go public.
- **Capture mode:** region (`screencapture -R`) worked for all 16 passes here. The app was prebuilt with bin/build.sh.
- **Blockers:**
  - 05-menu-bar-menu (light and dark): private terminal text from this session shows behind the menu.
  - 04-shelf (light and dark): the "Login Item Added" banner overlays the frame.
- **Other defects:**
  - 01, 02 and 03 library light: a bright white blob behind the glass.
  - Library, onboarding and menu frames: stray pixels at top left.
  - Known issues seen again: the Shelf image card is oversized, and the menu follows the system appearance.
- **Translucency:** real materials in the Library (light and dark), the Shelf and the Menu. Settings, Onboarding and the Shortcut editor are opaque chrome.
- **Harness gap:** bin/shots.sh:95-97 doesn't set CFFIXED_USER_HOME. I ran it through an env wrapper and left the harness unedited (QA reports, doesn't fix).
- **Round 2 needs:** a fixed backdrop or a cleared desktop for the menu shot, and Do Not Disturb or banner suppression. Those are harness or host changes, so I didn't make them.
- **Real state:** real data and prefs hashes match before and after, the pasteboard was untouched, no Flotsam is running, and no new plists were created.
- **Leaked test prefs (S1-approved):**
  - What: 1,224 plists matched by exact name: `flotsam.frd008.(contract|settings|pane|folder|empty|clear|apply).*`, `flotsam-7004-*` and `flotsam.task454.*`. 183 were dated 11-17 and 1,041 were dated 11-18.
  - Action: I listed them first, then moved them to the session scratchpad with `mv -n`, so the move is reversible.
  - Result: only the real Flotsam prefs plist remains.
- **BTM (read-only):**
  - `sfltool dumpbtm` hangs here (240 s, empty output).
  - The backgroundtaskmanagementd log shows one item: identifier `2.Flotsam`, uuid 9D7D2297-0E24-474F-B672-EC0F9EAF34E6. It is registered to the A3 a1-clone Debug build path. Disposition is [disabled, allowed, notified], so it is not enabled.
  - At 22:40:51 the A5 clone's new path was queried right after that item was updated. This supports S1's hypothesis that a stale registration is re-announced at each new app path.
  - BTM was not reset. Ryan can remove the item under Login Items / Allow in the Background.

## A6: screenshot round 1 retake at 534d085 (2026-11-19)

- **Verdict: NOT published.** No s2/shots SHA. The harness reported all 16 passes ok, but 3 of the 8 screens (6 frames) fail inspection.
- **Fails:**
  - **07-onboarding (light and dark):** the frame is the bare gradient backdrop with no onboarding window. The harness reported ok anyway. I confirmed this by eye.
  - **04-shelf (light and dark):** the "Login Item Added" banner is still in frame although a Focus mode was active (Sleep). On this host, Focus doesn't suppress this system banner. In 04-shelf-light, the banner's shadow also greys the top-left pixels.
  - **05-menu-bar-menu (light and dark):**
    - The menu is fully on-screen (check 2 passes), but its left edge sits at x≈0, which clips the rounded corner.
    - The frame includes the host menu bar (Apple, Finder, File, Edit, View, Go). That is host content, though nothing private. I confirmed this by eye.
- **Passes:** 01, 02, 03, 06 and 08, light and dark. Top-left pixels are clean everywhere except 04-shelf-light.
- **Fixed since A5:**
  - The backdrop works: no terminal text anywhere.
  - The white blob behind the light Library glass is gone.
  - The glass shows real translucency over the backdrop.
- **Still open:** the Shelf Preview card image is oversized (it overflows and covers the label). The light and dark menus differ in tint (known: the menu follows the system appearance).
- **Capture mode:** region or full-display plus sips; the harness doesn't log which. A standalone `-R` probe works here.
- **Real state:**
  - The real data and prefs hashes match before and after.
  - The prefs listing is unchanged, with no leftover suite plists.
  - The pasteboard is unchanged, and no Flotsam is running.

## A7: screenshot round 1 retake at 7ab11a8 (2026-11-19)

- **Verdict: NOT published.** No s2/shots SHA.
- **Fails:** 04-shelf and 05-menu-bar-menu, light and dark, both on the banner check. The "Login Item Added" banner sits on the host screen itself, top right, and persists (confirmed in a host screen grab). Focus doesn't suppress it. The single `--only shelf` rerun gave byte-identical frames.
- **Passes:** 01, 02, 03, 06, 07 and 08, light and dark.
  - The onboarding window is now present.
  - The menu crop is complete, with no host menu bar and its corners intact.
- **Capture mode:** `-R` for all 16 passes, per NOTES.txt.
- **Harness note:** `--only` truncates NOTES.txt, so the full-run notes were lost on the rerun.
- **New host path:** the harness created the fixed app path under the user Caches folder. It didn't exist before the run.
- **Needs Ryan:**
  - Dismiss the persistent banner.
  - Remove the stale Flotsam Login Items entries.
  - Then rerun all 16 passes.
- **Real state:** hashes match, the prefs listing is unchanged, the pasteboard is restored, and no Flotsam is running.

## A8: screenshot round 1 at 7ab11a8 (2026-11-20)

- **Verdict: PUBLISHED.** s2/shots = 95530dfa2d8c767669ba26369f31fa4ea9f32bf3 (normal push, no force).
- **Checks:** all 16 passes clean on checks 1–4. Checked 04-shelf and 05-menu-bar-menu by eye in light and dark: no banner, no host content, the menu is complete and its corners are intact.
- **Branch contents:** 17 files (round-1/: 16 PNGs + NOTES.txt). The leak grep on NOTES.txt is clean.
- **Capture mode:** `-R` for all 16, per NOTES.txt.
- **Harness defect:** after the publish, the cleanup step at bin/shots.sh:70 fails with `work: unbound variable`. The push had already landed.
- **Host path:** the fixed app path under the user Caches folder is left over from A7 and still present.
- **Still open:** the Shelf Preview image card is oversized (it overflows and covers the "Preview" label). The menu follows the system appearance (known).
- **Real state:** hashes match, the prefs listing is unchanged, the pasteboard is unchanged, and no Flotsam is running.

## A9: screenshot round 2 at hill-climb-529 0832dd1 (2026-11-20)

- **Verdict: PUBLISHED.** s2/shots = 475c49c7ab5987605964b3d8b0071c9920e7080a (normal push). The tree holds round-1/ and round-2/, 17 files each. The NOTES leak grep is clean.
- **Script:** the branch's bin/shots.sh, which is byte-identical to main 42c8f62. Built from a detached worktree; nothing merged.
- **Runs:** all 16 passes, `-R` capture, every staging pass found its window. Both the run and the publish exited 0, and the cleanup error from A8 is gone.
- **Banner and clipping:** none of the 16 frames shows the banner or host content.
- **Layout notes for the judges, light and dark:**
  - 01 and 03: the last sidebar Tags row ("Work") is cut by the footer.
  - 02: the preview popover covers the list rows (probably intended).
  - 04: the Shelf filter chips cut off at "Phone" at the right edge.
  - 06: the General pane is cut mid-row at the bottom of the capture.
  - 07: onboarding at 560x420 fits cleanly.
  - 08: the recorder field shows the shortcut chips and the clear button.
- **Real state:** hashes match, the prefs listing is unchanged, the pasteboard is unchanged, and no Flotsam is running.

## A10: screenshot round 3 at hill-climb-529 75b7b88 (2026-11-20)

- **Verdict: NOT published.** s2/shots is unchanged at 475c49c.
- **Fail:** 04 and 05, light and dark. A persistent host Calendar alert sits top right on the host screen and is baked into the frames. It contains private event details, so publishing to the public repo is out. It was still on screen when I checked the host after the run.
- **Clean:** 01, 02, 03, 06, 07 and 08, light and dark. `-R` capture on all 16, no missing windows, the run exited 0.
- **Ref:** origin/hill-climb-529 = 75b7b88 (the fetch reported a fast-forward from 0832dd1, not a force-push). Built from a detached scratch worktree; nothing pushed or merged.
- **Layout answers, light and dark:**
  - (a) The sidebar's last Tags row "Work" is still cut by the footer in 01 and 03.
  - (b) The Shelf chips can't be judged: the alert covers the row in 04.
  - (c) Settings General is still cut mid-row at the bottom in 06.
  - (d) 02 compact now shows the preview in place of the list, with no popover over the rows.
  - 07 and 08 are clean.
- **Needs Ryan:** dismiss the Calendar alert, then rerun all 16 passes.
- **Real state:** hashes match, the prefs listing is unchanged, the pasteboard is unchanged, and no Flotsam is running.

## A10 (resumed): screenshot round 3 at hill-climb-529 63f6210 (2026-11-20)

- **Verdict: PUBLISHED.** s2/shots = 9f9cad5ad5c91a01a50d50a7174a6da4dbc0ffd3 (normal push). The tree holds round-1/, round-2/ and round-3/, 17 files each, and the round-3 NOTES leak grep is clean.
- **Capture method:** per S1's ruling, the host Calendar alert stayed up and was not touched.
  - 04 and 05 used the harness's `SHOTS_CAPTURE=window` mode (`screencapture -l <windowID> -o`), which leaves out overlapping windows.
  - The other 12 frames used `-R`.
  - NOTES.txt records the change. Its auto "region capture failed" wording was corrected to the real reason.
- **Alert check:** all 16 PNGs were opened by eye, with no alert content anywhere. I re-checked 01 and 04 myself.
- **Window-capture look:** 04 and 05 lose the backdrop and vibrancy (flat panel, transparent corners). The 05 light menu renders a murky mid-grey; a faithful retake needs the alert gone.
- **Answers, light and dark:**
  - (a) The 01/03 sidebar "Work" row is whole.
  - (b) The 06 General bottom row is whole: it ends at "Show Setup Guide…", and the toolbar has 9 panes.
  - (c) The 04 chips still end in a clipped "Phone" chip at the panel edge.
  - 02 compact still shows the preview in place of the list. 07 and 08 are clean.
  - In 01 the list's last row is sliced at the footer (ordinary scroll edge).
- **Harness note:** in window mode the harness labels the frame "region capture failed" even when window mode was requested.
- **Real state:** hashes match, the prefs listing is unchanged, the pasteboard is unchanged, and no Flotsam is running.

## Harness bug H1: window mode is labelled "region capture failed" (filed 2026-11-20, not fixed)

- **Where:** `bin/shots.sh` at 63f6210, the same text as main 42c8f62. See the `pass()` capture block (about lines 153–167) and the result loop (about lines 197–199).
- **Symptom:** with `SHOTS_CAPTURE=window`, each frame logs `ok (region capture failed; window-only capture, blur is flat)` to the console. NOTES gets `window-only capture (-l); region capture was not available…`. Both are false, because the region capture was never tried.
- **Cause:** `pass()` returns the same `ok-window` result for two different cases: window mode was requested, or -R and the crop both failed and the capture fell back. The loop treats every `ok-window` as a fallback. The real reason is already written to `$OUT/.mode` as "window-only capture (screencapture -l)", but it's never checked against the mode that was asked for.
- **Fix shape (for S1):** give a requested window capture its own result (e.g. `ok-window-requested`), or check `SHOTS_CAPTURE` in the loop. Keep the "region capture failed" wording for a real fallback only. The Screen Recording fallback (`sr=0`) is a third case and should say so.
- **Impact:** NOTES only, and no pixels change. Round 3's NOTES were corrected by hand before publishing.
- **Standing capture rule (S1):** 04 and 05 stay in window mode while the host Calendar alert is up. Once the alert is gone, all 16 go back to -R, and S2 reports the first round where -R works.

## A11: screenshot round 4 at hill-climb-529 8e7794f (2026-11-20)

- **Verdict: PUBLISHED.** s2/shots = 01aab3b8104ba2c789c44042812fa8ac807f8712 (normal push). round-1/ through round-3/ hold 17 files each, and round-4/ holds 19 (18 PNGs including 06b, plus NOTES). The NOTES leak grep is clean.
- **Capture mode:** the host Calendar alert was still up before every pass and was not touched, so -R is not back yet.
  - 04 and 05 used `SHOTS_CAPTURE=window`. All other shots (01, 02, 03, 06, 06b, 07, 08) used -R.
  - All 18 PNGs were checked by eye, and no alert content appears in any of them, so no retakes were needed. I re-checked 01 light and 06b dark myself.
- **H1 fix verified:** the console and NOTES now say window-only capture was requested via SHOTS_CAPTURE=window. No hand correction was needed.
- **Layout, light and dark:**
  - **01:** the sidebar ends at the "Work" row, tight on the footer, and the Apps section is below the fold. The preview's code line is clipped at the right edge.
  - **02 compact:** the last sidebar row (Apps › Notes) is cut by the footer divider, and the code line is truncated.
  - **03 empty:** the empty state is whole. The "Work" row is partly clipped by the footer.
  - **04 Shelf:** the chips (All / Text / Links / More) now render whole. The last card is cut at the scroll edge, and the backdrop is flat because of window mode.
  - **05 menu:** nothing is clipped. Window capture makes the light menu a flat mid-grey, which doesn't represent the real menu; dark looks right.
  - **06 General:** whole.
  - **06b Library (new):** the Library and Capture sections, the Restore Library Defaults button, the toggles and the pickers are all whole, with a normal bottom margin.
  - **07:** clean.
  - **08:** clean; the ellipsis is by design.
- **Real state:** hashes match (DB, prefs, and the screencapture domain). The prefs listing is unchanged, the pasteboard is unchanged, no Flotsam is running, and hill-climb-529 was not pushed to.

## Harness bug H2: --publish skips 06b (filed 2026-11-20, not fixed)

- **Where:** `bin/shots.sh` at 8e7794f, line 53, in the publish glob `[0-9][0-9]-*-light.png` (and its dark twin).
- **Symptom:** `06b-…` doesn't match, because its third character is a letter, so `--publish` silently leaves out both 06b PNGs. The count check expects 16 and finds 16, so it gives no warning.
- **Fix shape:** change the glob to `[0-9][0-9]*-light.png` and its dark twin, and raise the expected count to 18. Better still, derive the count from SCREENS so it can't drift again.
- **Workaround used for round 4:** a temporary copy of the script with the glob widened; it was deleted afterwards, and the worktree is clean at 8e7794f.
