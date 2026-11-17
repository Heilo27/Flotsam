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
