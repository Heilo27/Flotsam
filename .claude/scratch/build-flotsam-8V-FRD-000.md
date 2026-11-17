# Flotsam FRD-000 8V test validation (Data, independent auditor)

Head 57d65d7, branch frd000. 89 tests green at start. Mutation run is mine (33 counted mutants, M31 discarded as equivalent), after O'Brien's lint fixes. Worf's 19/19 file is superseded.

## Verdict: FAIL
Survivors 5 of 33 (gate requires 0, no waiver). Two root causes. 20 of 33 would be a poor ratio to quote; the real picture is that reporter, throttle, ring, notice, strings, diagnostics and lint are strongly asserted, and the log layer is unobserved.

## Survivors
| id | target | OC | root cause | fix (tests/seam only) |
|----|--------|----|-----------|-----------------------|
| M14 | ErrorReporter.report: delete FlotsamLog.log(error) | OC-0013, 0014, 0040 | FlotsamLog.log has no injectable sink and no test reads OSLogStore, so "every raised code is logged, even when throttled" is unasserted | add a LogSink seam in FlotsamLog (default OSLog), inject a recorder in the reporter rig, assert one entry per raise incl. throttled and Info |
| M22 | log(error): message/cause privacy .private to .public | OC-0033, 0035 | same seam gap; only pure render()/level(for:) are tested | assert the sink receives message and cause as private |
| M23 | log(error): level fixed .info | OC-0032, 0013 | same; level(for:) is tested alone, its call site is not | assert level per severity at the sink |
| M34 | log(error): cause drops domain | OC-0035 | same | assert cause string "domain:code" at the sink |
| M30 | check-architecture.sh public throws rule drops `package` | OC-0003 | LintHarnessTests publicThrowsMutants inject only `public func ... throws` (2 mutants); `package`/`open` shapes never injected | add `package func x() throws` and `open func` mutants to publicThrowsMutants |

Discarded as equivalent: M31 (`(as!` cannot occur in valid Swift).
M14/M22/M23/M34 are one defect (no log seam), listed separately because each is a distinct behaviour a regression could break.

## Killed (28)
M01-M13, M15-M21, M24-M29, M32, M33 (ids and killing tests in frd-000-mutation.json). Boundaries killed: exact 60 s per-code (M02), exact 60 s HUD prune (M03), 3 vs 4 HUDs (M04), window 59 (M05), rejected-does-not-reset (M06), ring 100/101 and oldest-first (M07, M08), Info not recorded (M01), binary units (M16), SYS-INT-001 fallback (M18, M19), privacy split (M20, M21), 255-byte bundle id (M27), force-unwrap shapes and print/NSLog/dump (M28, M29).

## Banned-pattern findings (grep sweep over all 1753 test lines; full read of ErrorReporterTests, ErrorCatalogueTests, SettingsAndModelTests; other files by grep and mutation evidence only)
No B-finding on an OC-mapped test blocks the gate. Minor:
- B3 SettingsAndModelTests.swift:55 `LogCategory.allCases.count == 9` checks a count, not that each module maps to its category. Rewrite: assert the code-to-category table for one code per module (the OC-0037..39 LogLevelAndPrivacyTests already do this for events; add it for ErrorCode.logCategory).
- B3 ErrorCatalogueTests.swift:50 `!FlotsamStrings.message(for: .sysInt001).isEmpty` is an existence check. Rewrite: `== "<verbatim SYS-INT-001 text from the contract>"` (OC-0051 in ErrorTaxonomyTests already does; delete or tighten this one).
- B5 DiagnosticsTests.swift:161-162 positional `written[0]`/`written[1]`. Acceptable only if write order is the contract; otherwise assert by content.
- Untagged tests (SettingsAndModelTests.swift SettingsTests/SearchNormalizerTests/LogSafetyTests) are FRD-008/other scope, not FRD-000 evidence; do not count them toward mapping.
- B1, B2, B4, B6, B7: none found in what I read. ErrorTaxonomyTests derives expectations from the contract table, not from the implementation.

## Contract mapping (76 must_verify ids)
54 ids carry a passing OC tag. I mutation-verified the destructive/state/error subset listed above; remaining tagged ids are MAPPED on assertion text only (not individually mutated).
22 ids have no test tag:

GAP-unit (to Worf; unit-testable):
- 0013, 0014, 0040 (log entry per raise, level, category, throttled code still logged): needs the LogSink seam above, then unit tests. Runtime `log show` half is GAP-journey.
- 0021 (5 mutated catalogue copies all red): ErrorCatalogueTests reads a fixed path; needs a path parameter so mutated copies can be fed.
- 0017 (plural 1 vs 2): candidate for a catalogue plural-variant unit test; I did not inspect the catalogue for plural variants.

GAP-journey / blocked (needs running app, Instruments, VoiceOver or Release build):
- 0008, 0009, 0010, 0069, 0070 (STO-IO-002 / STO-DB-003 alerts and Reveal behaviour)
- 0015 (pseudo-language), 0025 (secondary-display HUD), 0054 (VoiceOver HUD), 0055 (Notice row single line), 0056 (tag editor inline error, FRD-008-adjacent)
- 0033 (Release vs Debug log level), 0035 (no marker leak in logs), 0041, 0042 (signposts), 0048 (idle: no pasteboard/network), 0074 (runtime part), 0075 (Release binary string scan)

Worf's list verified: all 14 are unmapped (confirmed). Additional unmapped ids Worf did not list: 0013, 0014, 0021, 0040, 0048, 0074, 0075.

## Confidence
High on the 33 mutation results (each reverted, git status clean of source after every run). Medium on the B audit (not every test body read). Medium on MAPPED for tagged-but-not-mutated ids.

## Required to flip to PASS
1. Add LogSink seam in FlotsamLog (production code change, goes to O'Brien) and tests killing M14, M22, M23, M34.
2. Add `package`/`open` throws mutants to LintHarnessTests (kills M30).
3. Worf: GAP-unit ids; journey ids routed to the journey phase.

## Re-run 2026-11-16

Head 101b947, branch frd000. Baseline 105 tests green in FlotsamBaseTests. One mutant at a time, `swift test --package-path Packages/FlotsamCore --filter FlotsamBaseTests`, `git checkout` of the file after each, `git status` clean after each (checked by script, all 23 runs).

### Verdict: FAIL (3 survivors, one defect: SystemClock.sleep has no runtime test)

### Step 1: my five first-pass survivors, re-applied
| id | mutant | result | killed by |
|----|--------|--------|-----------|
| M14 | delete the log call in ErrorReporter.report | KILLED | everySeverityWritesOneRecord, throttled and cap-suppressed still logged (23 issues) |
| M22 | message moved into LogRecord.publicText | KILLED | OC-0013 OC-0035 private-text test (5 issues) |
| M23 | record level fixed .info | KILLED | OC-0032 OC-0013 level and category test |
| M34 | privateText cause drops domain | KILLED | OC-0013 OC-0035 private-text test |
| M30 | lint throws rule drops `package` | KILLED | OC-0003 injected throws lint test, package case |

### Step 2: 18 new mutants, 15 killed, 3 survived
- LogRecord split: N1 publicText gains privateContext, N2 privateText drops cause, N3 privateText drops message. All KILLED.
- ErrorReporter: N4 log after the throttle (Warning/Error), N9 wrong category passed, N11 log written twice. All KILLED (AC-000-04 throttled-still-logged tests, OC-0032, exactly-one-record tests).
- N10 record category fixed .core. KILLED (OC-0032 OC-0013).
- Catalogue parsing: N5a reads `de`, N5b missing table returns success, N5c non-JSON returns success, N5d reads `state` not `value`. All KILLED (OC-0021 reader tests, OC-0016, OC-0018, OC-0057..59).
- shippedURL: N6a drops a path component, N6b `Resource` typo. KILLED (26 issues each).
- Lint `open` branch: N7 drops `open` from the regex. KILLED by the "open throws in a module file" mutant under OC-0003. Worf's `open` coverage is real.
- SystemClock.sleep: N8a `try?` to `try!` KILLED, but by the lint's no-`try!` rule over shipped sources, not by a runtime test. N8b sleeps `.zero`, N8c sleeps the full duration again on cancellation, N8d body is a no-op: all three SURVIVED.

### Survivors
N8b, N8c, N8d: Packages/FlotsamCore/Sources/FlotsamBase/Ports/Ports.swift:17-20 (`SystemClock.sleep`). No test calls SystemClock at all (`git grep SystemClock Tests` is empty); the test clock double returns immediately. No contract id maps to it: OC-0003 only asserts the signature does not throw, which the protocol enforces at compile time. This is a contract gap plus a test gap, not a mapped-test defect, but doctrine says any survivor is FAIL and none may be called acceptable. Fix (tests only, no production change): a SystemClock test that (1) sleeps 50 ms and asserts elapsed >= 50 ms, (2) cancels a task sleeping 10 s and asserts it returns promptly without trapping. Also add an OC id for it to the contract (paste's 40 ms delay, ADR-0004, depends on this adapter).

### Step 3: B-findings
- SettingsAndModelTests.swift:55 (was B3 count check): RESOLVED. `everyModuleHasALogCategory` asserts the category for one code in each of eight modules; `core` is asserted in LogLevelAndPrivacyTests.swift:173.
- ErrorCatalogueTests.swift:50 (was B3 non-empty check): RESOLVED. SYS-INT-001 is compared to the verbatim FRD section 7 text, and the fallback for an unfilled template is asserted too.
- DiagnosticsTests.swift:161-162 (was B5 positional): RESOLVED. Compares `Set` of UTIs and looks entries up by UTI. Write order is not asserted. One write is asserted by count.

### Step 4: OC-0021
Contract text: given "Five separate mutated copies: (1) key error.SYS-INT-001 removed; (2) a 141-character message on one code; (3) a message added for Info code CAP-POL-001; (4) orphan key error.XXX-INT-999 with no code; (5) two enum cases sharing one raw value", when "The catalogue unit test runs against each", then "The test FAILS in all 5 cases (5 of 5 red)".
Verdict: MET as written. The id requires a unit test that goes red on each of five mutated inputs; it does not say where the checker lives. `CatalogueConsistency` in TestSupport is the checker, `ErrorCatalogueTests` feeds it all five mutations (plus a 140-character pass control and a clean baseline) and each yields exactly the expected violation tag. Case 5 uses a synthetic code list, because Swift will not compile an enum with two equal raw values; the compiler is a stronger guard and the checker still proves it would flag it. The production parser it reads through (`FlotsamCatalogue`) is mutation-covered by N5a-d and N6a-b. Residual note: the checker is test-only, so a shipped build has no consistency check; FR-000-07 and AC-000-02 are met by tests, not at runtime, and nothing in the contract asks otherwise.

### Counts
Run 23 (5 re-applied + 18 new), killed 20, survived 3. Survivor total for the gate: 3 (N8b, N8c, N8d). Mutation log updated in .claude/oracle/frd-000-mutation.json.
