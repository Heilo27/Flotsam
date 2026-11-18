import Testing

// FRD-000 8T gap list (oracle .claude/oracle/frd-000-contract.json). Same arrangement as FRD004ContractTestsGaps.swift:
// the contract ids, or halves of ids, that the package tests cannot see. Each UNTESTABLE entry is a disabled test, so
// the run reports it as skipped with the missing seam named; none of them passes silently.
//
// Why: the fatal alert, the HUD panel, the menu-bar Notices rows and the tag editor's inline error are App-target AppKit
// and SwiftUI, and the Release build, the unified log, the network monitor and Finder need a launched app. The decisions
// below them are tested in FRD000ContractTestsFatal (FlotsamAppModelTests) and FRD000ContractTestsCatalogue (FlotsamBaseTests).
//
// CITED (an earlier suite already names the id in an @Test or @Suite title and asserts the behaviour; listed here so every
// id has one covering test, not re-tested). Format: id: covering test files.
//   OC-0001: LintHarnessTests.swift
//   OC-0002: LintHarnessTests.swift
//   OC-0003: LintHarnessTests.swift
//   OC-0004: LogLevelAndPrivacyTests.swift, Survivors377Tests.swift
//   OC-0005: ErrorTaxonomyTests.swift, Survivors377Tests.swift
//   OC-0006: ErrorTaxonomyTests.swift
//   OC-0007: ErrorTaxonomyTests.swift
//   OC-0011: ErrorReporterTests.swift
//   OC-0012: ErrorReporterTests.swift
//   OC-0013: ErrorReporterTests.swift
//   OC-0014: ErrorReporterTests.swift
//   OC-0015: StringsSurvivorTests.swift
//   OC-0016: ErrorTaxonomyTests.swift
//   OC-0018: ErrorTaxonomyTests.swift, StringsSurvivorTests.swift
//   OC-0019: ErrorTaxonomyTests.swift, ShelfDropAcceptanceBlindTests.swift
//   OC-0020: ErrorTaxonomyTests.swift
//   OC-0021: ErrorCatalogueTests.swift, StringsSurvivorTests.swift
//   OC-0022: ErrorReporterTests.swift
//   OC-0023: ErrorReporterTests.swift
//   OC-0024: ErrorReporterTests.swift
//   OC-0026: ErrorReporterTests.swift
//   OC-0027: ErrorReporterTests.swift
//   OC-0028: ErrorReporterTests.swift
//   OC-0029: ErrorReporterTests.swift
//   OC-0030: ErrorReporterTests.swift
//   OC-0031: LogLevelAndPrivacyTests.swift
//   OC-0032: ErrorReporterTests.swift, LogLevelAndPrivacyTests.swift
//   OC-0034: LintHarnessTests.swift, LoggingMutationTests.swift
//   OC-0035: ErrorReporterTests.swift
//   OC-0036: LogLevelAndPrivacyTests.swift, LoggingMutationTests.swift
//   OC-0037: Frd000PasteboardCallsiteTests.swift, LogLevelAndPrivacyTests.swift
//   OC-0038: Frd000CallsiteChecklistTests.swift, LogLevelAndPrivacyTests.swift
//   OC-0039: Frd000CallsiteChecklistTests.swift, LogLevelAndPrivacyTests.swift
//   OC-0040: ErrorReporterTests.swift
//   OC-0041: LoggingMutationTests.swift
//   OC-0042: LoggingMutationTests.swift
//   OC-0043: DiagnosticsTests.swift, ErrorReporterTests.swift
//   OC-0044: ErrorReporterTests.swift
//   OC-0045: DiagnosticsTests.swift
//   OC-0046: DiagnosticsTests.swift, Survivors377Tests.swift
//   OC-0047: DiagnosticsTests.swift
//   OC-0049: LintHarnessTests.swift
//   OC-0050: ErrorTaxonomyTests.swift
//   OC-0051: ErrorTaxonomyTests.swift
//   OC-0052: ErrorReporterTests.swift
//   OC-0053: ErrorTaxonomyTests.swift
//   OC-0057: ErrorTaxonomyTests.swift
//   OC-0058: ErrorTaxonomyTests.swift
//   OC-0059: ErrorTaxonomyTests.swift
//   OC-0060: ErrorTaxonomyTests.swift
//   OC-0061: ErrorTaxonomyTests.swift
//   OC-0062: ErrorTaxonomyTests.swift
//   OC-0063: ErrorTaxonomyTests.swift
//   OC-0064: ErrorTaxonomyTests.swift
//   OC-0065: ErrorTaxonomyTests.swift
//   OC-0066: ErrorReporterTests.swift
//   OC-0067: ErrorReporterTests.swift
//   OC-0068: DiagnosticsTests.swift, ErrorReporterTests.swift
//   OC-0071: LogLevelAndPrivacyTests.swift
//   OC-0072: LogLevelAndPrivacyTests.swift, LoggingMutationTests.swift
//   OC-0073: LintHarnessTests.swift, LogLevelAndPrivacyTests.swift, LoggingMutationTests.swift
//   OC-0076: DiagnosticsTests.swift, Survivors377Tests.swift
//   OC-0077: SystemClockTests.swift
//
// OC-0077 is cited by the suite "SystemClock runtime (OC-0077)" in SystemClockTests.swift (three tests: live sleep takes at
// least the duration, cancelled before and cancelled during return early without throwing).
//
// Halves that are tested elsewhere are named in each entry below. OC-0025, OC-0054 and OC-0055 have no tested half.

@Suite struct FRD000ContractTestsGaps {

    // OC-0008.
    @Test("OC-0008 the modal alert is shown, offers exactly 2 buttons and the process exits after Quit [no seam: manual]", .disabled("no seam: manual. the alert is an NSAlert.runModal() inside FatalAlert.present, which also calls NSApplication.terminate; a seam would be an injectable alert runner and terminator. Text, button titles and the folder choice are tested in FRD000ContractTestsFatal"))
    func oc0008_0() {}

    // OC-0009.
    @Test("OC-0009 clicking Reveal Data Folder brings Finder forward on the nearest existing ancestor [no seam: manual]", .disabled("no seam: manual. NSWorkspace.activateFileViewerSelecting is called inline in FatalAlert.present; a seam would be an injectable reveal closure. The folder chosen is tested in FRD000ContractTestsFatal"))
    func oc0009_1() {}

    // OC-0010.
    @Test("OC-0010 a user_version 99 database launches into the Fatal alert and the process exits after Quit [no seam: manual]", .disabled("no seam: manual. needs a launched app against a fixture database; the STO-DB-003 text and Fatal severity are tested in FRD000ContractTestsFatal"))
    func oc0010_2() {}

    // OC-0025.
    @Test("OC-0025 the HUD appears top-centre of the display holding the pointer for 2.5 s without taking focus [no seam: manual]", .disabled("no seam: manual. ErrorPresenterAdapter.topCentre reads NSEvent.mouseLocation and NSScreen.screens inline and the panel timing is a Task.sleep in showHUD; a seam would be a pure placement function taking the pointer point and screen frames, and an injectable clock"))
    func oc0025_3() {}

    // OC-0033.
    @Test("OC-0033 a Release log holds 0 Debug entries from the subsystem and a Debug log at least 1 [no seam: manual]", .disabled("no seam: manual. needs a Release build and `log show --debug`; the source gate (the only .debug emitter sits inside #if DEBUG) is tested in FRD000ContractTestsCatalogue and the Release branch of trace() is asserted by OC-0034 traceRecord when the package is tested with -c release"))
    func oc0033_4() {}

    // OC-0048.
    @Test("OC-0048 idle for 5 minutes opens 0 network connections and leaves the pasteboard changeCount unchanged [no seam: manual]", .disabled("no seam: manual. needs a live app with a network monitor; the no-network-API source scan is tested in FRD000ContractTestsCatalogue and the pasteboard-write rule by OC-0037"))
    func oc0048_5() {}

    // OC-0054.
    @Test("OC-0054 VoiceOver announces the HUD text and keyboard focus does not move [no seam: manual]", .disabled("no seam: manual. ErrorPresenterAdapter.announceToVoiceOver posts through NSAccessibility inline; a seam would be an injectable announcer"))
    func oc0054_6() {}

    // OC-0055.
    @Test("OC-0055 a CAP-LIM-001 Notice shows as one menu line, message then ' · CAP-LIM-001', with Dismiss all present [no seam: manual]", .disabled("no seam: manual. the row title is built inline in StatusItemController; a seam would be a pure Notice.menuTitle in FlotsamBase"))
    func oc0055_7() {}

    // OC-0056.
    @Test("OC-0056 the tag editor shows red text with an icon and VoiceOver announces ORG-VAL-001 for a 33-character name [no seam: manual]", .disabled("no seam: manual. the inline error view is SwiftUI in the App target; the data half (33 characters rejected, tag count delta 0, ORG-VAL-001 text) is cited from WorfFRD004StorageTests.tagNameBoundary"))
    func oc0056_8() {}

    // OC-0069.
    @Test("OC-0069 with the parent writable again, clicking Reveal Data Folder reveals in Finder and the process exits after dismissal [no seam: manual]", .disabled("no seam: manual. same seams as OC-0009 plus the process exit; the never-created rule is tested in FRD000ContractTestsFatal"))
    func oc0069_9() {}

    // OC-0070.
    @Test("OC-0070 clicking Reveal Data Folder shows the data folder itself in Finder and the process exits after dismissal [no seam: manual]", .disabled("no seam: manual. same seams as OC-0009; the folder chosen is tested in FRD000ContractTestsFatal"))
    func oc0070_10() {}

    // OC-0074.
    @Test("OC-0074 `log show` holds 0 ORG-VAL-004 and 0 ORG-VAL-005 entries and no HUD shows the retired texts after every organize path is driven [no seam: manual]", .disabled("no seam: manual. needs a launched app and the unified log; the absence from ErrorCode, the catalogue and the sources is tested in FRD000ContractTestsCatalogue"))
    func oc0074_11() {}

    // OC-0075.
    @Test("OC-0075 the built Release executable and compiled catalogue hold 0 occurrences of the retired codes and texts [no seam: manual]", .disabled("no seam: manual. needs a Release build and a binary search; the source and catalogue halves are tested in FRD000ContractTestsCatalogue"))
    func oc0075_12() {}
}
