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
| 007 | Retention / storage | S1 | merged | on `main` |
| 009 | Distribution (`bin/release.sh`) | S1 | merged | on `main`; DMG signing waits on Ryan's Developer ID |
| 001 | Capture | S1 | `frd001` | building |
| 003 | Library: paste-back | S1 | `frd003` | **ready: 6fe1d6e** — S2: A3 app build + launch (S1 machine overloaded; app target never built here). Package tests 21/21 Paste. |
| 003 | Library: panel UI | S1 | `frd003ui` | building |
| 008 | Onboarding / settings / menu bar | S1 | `frd008` | building |
| 002 | Screenshot pickup | **S2** | `s2/frd002` | open: S2 lane C |
| 006 | Shelf | **S2** | `s2/frd006` | open: S2 lane C, after 002 |
| 004 | Organize (tags, bundles) | S1 | `frd004` | after 003 merges |
| 005 | Shortcuts / triggers | S1 | `frd005` | after 003 merges |

"Ready for S2" = S1 has marked a builder branch here as `ready: <sha>`. Before that it's mid-build; don't verify it.

## S2 queue, in priority order

### Lane A: verify landed work (heaviest; always first)

Re-run this whenever `main` moves or a builder branch is marked `ready`:

- **A1** `main` health:
  - clean clone, `bin/bootstrap.sh`;
  - full `swift test` (no scratch path, so the lint harness runs too);
  - `bin/check-architecture.sh`;
  - `bin/build.sh`.

  Log the counts.
- **A2** Launch smoke:
  - build the Debug app and launch it;
  - copy text, a URL, an image and a file, and confirm each appears in storage once FRD-001 has landed;
  - copy from a password manager (concealed type) and confirm nothing is stored;
  - check the menu bar item;
  - quit cleanly.

  Note any crash logs (`~/Library/Logs/DiagnosticReports/Flotsam*`).
- **A3** Same as A1 + A2 on each branch marked `ready`, before S1 merges it.
- **A4** Performance baseline on `main`, per the PRD/TRUTHS budgets:
  - idle CPU and RSS of the running app over 10 min;
  - capture latency;
  - Library search latency with a 50k-item seeded DB.

  Use `xctrace` or `footprint`. Report numbers only; don't optimise.

### Lane B: contract tests (8T), one branch per FRD

The blind pass criteria live in `.claude/oracle/frd-NNN-contract.json`.

- Write swift-testing tests that exercise each contract through the public API. Put them in the FRD's test target, on `s2/frdNNN-8t`, branched from the builder's `ready` SHA.
- Run them and report pass/fail per contract ID.
- A failing contract is a defect report, not a fix.
- Order: 001 → 003 → 008 → 002 → 006 (as each is `ready`).

### Lane C: build features while A and B are idle

Builds follow the per-FRD loop in the FRD: implement → unit tests → green → build the app.

- **C1** FRD-002 Screenshot Pickup on `s2/frd002`, from `main`. Read `docs/frd/FRD-002-ScreenshotPickup.md` and ADR-0008.
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

## S1 queue (for S2's awareness)

- Finish the FRD-001, FRD-003 (paste + UI) and FRD-008 builders, then merge them to `main`.
- Build FRD-004 and FRD-005 once FRD-003 is on `main`.
- Merge S2's `s2/*` branches after review.
- The FRD-007 efficiency tickets come after MVP works.
- Release signing (FRD-009) needs Ryan's go.
