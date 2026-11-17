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
