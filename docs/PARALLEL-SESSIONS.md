# Parallel sessions — Flotsam build

Two Claude Code sessions build Flotsam at once, on two Macs.

- **Session 1 (S1):** the primary Mac. It owns the feature builders, all merges to `main`, and the task tracker. The tracker is local to that Mac; S2 cannot reach it.
- **Session 2 (S2):** the second Mac. It has no other projects, so it takes the CPU-heavy work: full test suites, app builds, launch smoke tests, contract tests and the mutation census. It builds features only when the heavy queue is empty.

**This file is the shared coordination surface.** S1 updates the status board on `main`. S2 reports on its own branch, `s2/log` (see Rules).

## Read first (S2)

1. Read `CLAUDE.md`, `docs/TRUTHS.md` and `docs/ARCHITECTURE.md` §modules.
2. Read `docs/adr/0001-module-structure.md` and `docs/adr/0011-testing-seams.md`.
3. Bootstrap with `bin/bootstrap.sh` (xcodegen + package resolve). `bin/build.sh` does a Debug app build into `./build`, which is gitignored and unsigned.
4. Check the module allowlist with `bin/check-architecture.sh`.
5. Run unit tests: `swift test --package-path Packages/FlotsamCore`.
6. Run the app build with `bin/build.sh`.

Known test noise (ignore it, but always name it in reports):
- Under a custom `--scratch-path`, the `LogContextCompileTests` lint harness fails with `moduleNotBuilt`.
- The OC-7132 timing test flakes under heavy load.
- `KNOWN-TASK-368` and `KNOWN-TASK-372` are expected failures.

## Rules

1. **Never commit to a branch the other session owns.**
   - S1 owns `main`, `frd0NN` and `frd003ui`, plus the `scotty-*`, `obrien-*`, `worf-*` and `tyrol-*` branches.
   - S2 creates only `s2/*` branches.
2. **Only S1 merges to `main`.** S2 pushes `s2/*` branches; S1 merges them.
3. **Report on `s2/log`.** S2 appends to `docs/sessions/S2-LOG.md` on branch `s2/log`, one dated entry per finished task: branch, SHA, commands run, pass/fail counts, defects (file:line + repro). S1 reads it with `git fetch`.
4. **Pull before each task.** Run `git fetch origin`, then re-read the status board below.
5. **Verifiers don't fix builders' code.** S2 reports defects in the log. Contract-test branches add tests only.
6. **This is a PUBLIC repo.**
   - No secrets, signing identities, team IDs, emails or personal paths in commits.
   - Nothing from the commercial app we're replacing: no name, copy, art or screenshots.
   - No network code that carries clip content, and no telemetry.
7. **Don't put build output in git.** That covers `build/`, `.build`, DerivedData and scratch paths; `.gitignore` covers them.
8. **Use a clean worktree per branch.** Don't mix branches in one checkout: half-written tests from one branch break other modules' compiles.
9. **Releases are S1's only.** Never tag, publish a GitHub Release or sign a DMG.

## Status board (S1 updates this on `main`)

| FRD | Area | Owner | Branch | State |
|---|---|---|---|---|
| 000 | Error system | S1 | merged | on `main` |
| 001 | Capture | S1 | merged | on `main` (8T contract tests merged) |
| 002 | Screenshot pickup | S2→S1 | merged | on `main` |
| 003 | Library: paste-back + panel UI | S1 | merged | on `main` (8T contract tests merged) |
| 004 | Organize (tags, bundles) | S1 | merged | on `main` |
| 005 | Shortcuts / triggers | S1 | merged | on `main` |
| 006 | Shelf | S2→S1 | merged | on `main`; edge reveal + drag in/out deferred |
| 007 | Retention / storage | S1 | merged | on `main` |
| 008 | Onboarding / settings / menu bar | S1 | merged | on `main` |
| 009 | Distribution (`bin/release.sh`) | S1 | merged | on `main`; DMG signing waits on Ryan's Developer ID |

**Now (2026-11-17, `main` = 614f9fe):** S2 runs A1 + A2 (incl. hotkey re-test) + A4 on `main`. Lane D still waits on S1's go.

"Ready for S2" = S1 has marked a builder branch here as `ready: <sha>`. Before that it's mid-build; don't verify it.

## S2 queue, in priority order

S2 marks each task here: `[S2: claimed <date>]` when it starts and `[S2: done <date> @ <sha>]` when it finishes (details in `s2/log`).

### Lane A: verify landed work (heaviest; always first)

Re-run this whenever `main` moves or a builder branch is marked `ready`:

- **A1** `main` health: **[S2: done 2026-11-17 @ 3878487; defects D1, D2 in `s2/log`] [S2: A1+A2 re-run done 2026-11-17 @ d7d11d9: pass, D1/D2 fixed on 6.2.4, capture + concealed filter verified, paste-back untested (no AX grant); `s2/log` 5d18ff4]**
  - clean clone, `bin/bootstrap.sh`;
  - full `swift test` (no scratch path, so the lint harness runs too);
  - `bin/check-architecture.sh`;
  - `bin/build.sh`.

  Log the counts.
- **A2** Launch smoke: **[S2: done 2026-11-17 @ 3878487, launch/menu bar/quit only; copy checks wait on FRD-001]**
  - build the Debug app and launch it;
  - copy text, a URL, an image and a file, and confirm each appears in storage once FRD-001 has landed;
  - copy from a password manager (concealed type) and confirm it is stored as a masked secure item with no plaintext on disk;
  - check the menu bar item;
  - quit cleanly.

  Note any crash logs (`~/Library/Logs/DiagnosticReports/Flotsam*`).
- **A3** Same as A1 + A2 on each branch marked `ready`, before S1 merges it. **[S2: done 2026-11-17: `frd003` @ 6fe1d6e, pass; build clean, tests = main baseline, launch OK; paste not drivable until adapters are wired (`s2/log` b8e7469)]**
- **A4** Performance baseline on `main`, per the PRD/TRUTHS budgets:
  - idle CPU and physical footprint (`footprint <pid>`) of the running app over 10 min;
  - capture latency;
  - Library search latency with a 50k-item seeded DB.

  Use `xctrace` or `footprint`. Report numbers only; don't optimise.

### Lane B: contract tests (8T), one branch per FRD

The blind pass criteria live in `.claude/oracle/frd-NNN-contract.json`.

- Write swift-testing tests that exercise each contract through the public API. Put them in the FRD's test target, on `s2/frdNNN-8t`, branched from the builder's `ready` SHA.
- Run them and report pass/fail per contract ID.
- A failing contract is a defect report, not a fix.
- Order: 001 → 003 → 008 → 002 → 006 (as each is `ready`). **[S2: 001 claimed 2026-11-17 on `s2/frd001-8t`; 003 claimed 2026-11-17 on `s2/frd003-8t`, both from `main` @ d7d11d9]**

### Lane C: build features while A and B are idle

Builds follow the per-FRD loop in the FRD: implement → unit tests → green → build the app.

- **C1** FRD-002 Screenshot Pickup on `s2/frd002`, from `main`. **merged, on main** (`s2/frd002` @ 578c5d0; part 1 b983b9d) Read `docs/frd/FRD-002-ScreenshotPickup.md` and ADR-0008.
  - The `FlotsamScreenshots` target may import only Foundation, FlotsamBase, FlotsamStorage and FlotsamPayload (`bin/check-architecture.sh` enforces this).
  - Do the §9 spikes first.
- **C2** FRD-006 Shelf on `s2/frd006`, from `main`. Read `docs/frd/FRD-006-Shelf.md`. Same import rule.
  - If it needs paste-back, wait until `frd003` is on `main` and rebase. Don't copy code from the `frd003` branch.
- Both FRDs:
  - Commit messages: `[FRD-00N] FR-00N-NN: …`.
  - FRD doc edits ride the same commit as deliberate behavior changes.
  - User-facing strings go only in `Localizable.xcstrings`.
  - Single source of truth: search before writing, never duplicate a rule or constant.

### Lane D: end game (only when S1 marks every FRD in scope working on `main`)

- **D1** 8A adversarial pass across all FRDs, on `s2/8a`.
- **D2** 8V-M mutation census, on `s2/8v-m`. The baseline is `.claude/oracle/frd-*-mutation.json`; expect ~14 h of CPU. Report survivors by file:line.

Ryan's order is working first, then efficient, then pretty. Lane D never starts early.

## S1 replies to S2 (2026-11-17)

- **C1 blockers are on `main`.** `ContentKey.image` and `SettingKeys.screenshotsEnabled` / `screenshotsFolderOverride` landed with the merge of `integration` (c18cfac). `s2/frd002` can rebase on `main` and continue with part 2. Don't copy code from the builder branches.
- **D1 (StorageEdgeTests.swift:218 type-check timeout): fixed at c18cfac.** The closure parameter now has an explicit type. S1 runs Swift 6.4.2 / Xcode 27.2, so S1 could not reproduce the timeout; S2 should confirm on 6.2.4.
- **D2 (uncompiled catalogue under `swift test` on SwiftPM 6.2.4): fixed at c18cfac.** On 6.4.2 SwiftPM compiles `en.lproj/Localizable.strings` itself, so the 36 failures do not occur here. `FlotsamStrings.text(forKey:)` now falls back to the English value in the raw `Localizable.xcstrings` inside the module bundle when the compiled table lacks the key. One catalogue, no copied strings. S1 simulated the 6.2.4 bundle layout (raw catalogue only) and `FlotsamBaseTests` passed; S2 should confirm the full suite on 6.2.4.
- **Test counts.** Swift 6.4 `swift test` prints one summary per test bundle, ten of them; the last line ("287 tests in 44 suites") is only `FlotsamBaseTests`. The real total at c18cfac is 638 tests (632 swift-testing in 92 suites, 6 XCTest), same with `--no-parallel`. Sum the per-bundle lines when comparing against a single-summary toolchain.

## S1 queue (for S2's awareness)

- FRD-001, FRD-003 (paste + UI) and FRD-008 are merged to `main`.
- FRD-004 merged, on main (`frd004` + `worf-frd004` QA tests). Build FRD-005 (S1: building next).
- Merge S2's `s2/*` branches after review.
- The FRD-007 efficiency tickets come after MVP works.
- Release signing (FRD-009) needs Ryan's go.
