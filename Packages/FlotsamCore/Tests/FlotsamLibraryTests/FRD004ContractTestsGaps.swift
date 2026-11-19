import Testing

// FRD-004 8T gap list (oracle .claude/oracle/frd-004-contract.json). Same arrangement as Frd003ContractGapTests.swift:
// the contract ids the package tests cannot fully see, each reported as "no seam: manual". Every UNTESTABLE entry below is
// a disabled test, so the run reports it as skipped with the missing seam named; none of them passes silently.
//
// Why: the OrganizeCoordinator confirm overlays (OrganizeOverlays), the tag popover, the tag menu in LibraryView and the
// hotkey registry live in the App target, which has no test target. The decisions below them are tested in
// FRD004ContractTests* (Storage and Library slices); what is listed here is the half above the package line.
//
// CITED (an earlier suite already asserts the behaviour; named here so the id has a covering test, not re-tested):
//   OC-4002: WorfFRD004IntegrationTests.swift (pinThroughModel: toggling again unpins both) and WorfFRD004StorageTests.swift (pinDoesNotReorderAndCountsMove: an all-pinned selection unpins both)
//   OC-4008: WorfFRD004StorageTests.swift (pinDoesNotReorderAndCountsMove)
//   OC-4010: WorfFRD004StorageTests.swift (tagNameBoundary: 32 accepted, 33, control characters and blanks rejected)
//   OC-4079: WorfFRD004StorageTests.swift (ungroupKeepsFilesAndDoesNotDedupe)
//   OC-4103: WorfFRD004StorageTests.swift (organisePerformance: tagging 500 in under 1 s)
//
// UNTESTABLE halves: the @Test list below. Ids whose other half is tested (OC-4021-4024, 4027, 4030, 4040, 4047,
// 4059, 4062, 4069, 4075, 4077, 4099) say which half in the title; OC-4026, 4028, 4041, 4042, 4052 and 4054 have no tested half.
//
// OC-4073 is not here: its confirmation rule and its key (ui.organize.confirmUngroup, FR-004-11) are tested in
// FRD004ContractTestsLibrary.swift.

@Suite struct FRD004ContractTestsGaps {

    // OC-4026. Seam needed: an App test target (or a popover-dismiss decision extracted into FlotsamLibrary).
    @Test("OC-4026 Esc closes the tag popover and the tag stays [no seam: manual]", .disabled("no seam: manual. the tag popover is a SwiftUI popover in the App target's LibraryView; no seam below it takes a key event"))
    func oc4026_0() {}

    // OC-4028. Seam needed: a LibraryContextMenu-style entry builder for tags in FlotsamLibrary, like the item menu has.
    @Test("OC-4028 the tag context menu is exactly Rename, Colour (eight values) and Delete [no seam: manual]", .disabled("no seam: manual. the menu is built inline in LibraryView.tagMenu (App target); only the eight colours (storage) are tested"))
    func oc4028_1() {}

    // OC-4041. Seam needed: an App test target, or a pure key-to-action mapping in FlotsamLibrary.
    @Test("OC-4041 Return inserts a newline in the note and Command-Return saves [no seam: manual]", .disabled("no seam: manual. key handling is the SwiftUI NoteCard overlay (OrganizeOverlays, App target)"))
    func oc4041_2() {}

    // OC-4042. Seam needed: an App test target, or a pure key-to-action mapping in FlotsamLibrary.
    @Test("OC-4042 Esc in the note keeps the old note [no seam: manual]", .disabled("no seam: manual. the Esc handler is the NoteCard overlay (App target); the stored note is only changed by setNote, which Esc never calls"))
    func oc4042_3() {}

    // OC-4052. Seam needed: an App test target, or a pure key-to-action mapping in FlotsamLibrary.
    @Test("OC-4052 Esc in the editor keeps the stored text [no seam: manual]", .disabled("no seam: manual. the Esc handler is the EditCard overlay (App target); the stored text is only changed by saveEdit, which Esc never calls"))
    func oc4052_4() {}

    // OC-4054. Seam needed: a pure `LibraryOrganizer.editShowsFormattingNotice(kind:)` in FlotsamLibrary.
    @Test("OC-4054 no formatting notice for plain text [no seam: manual]", .disabled("no seam: manual. the notice is `if isRichText` inside EditCard (App target)"))
    func oc4054_5() {}

    // OC-4030. Seam needed: an App test target, or the coordinator's decision extracted into FlotsamLibrary.
    @Test("OC-4030 (cancel path) deleting tag T and cancelling leaves T and its 5 items [no seam: manual]", .disabled("no seam: manual. Cancel is the OrganizeCoordinator confirm overlay (App target); the prompt text and the confirmed delete are tested"))
    func oc4030_6() {}

    // OC-4062. Seam needed: an App test target.
    @Test("OC-4062 (dialog and keystroke UI) Command-Delete on a plain item shows no dialog [no seam: manual]", .disabled("no seam: manual. the keystroke and the dialog are the OrganizeCoordinator and LibraryView key handling (App target); deleteNeedsConfirmation and the delete itself are tested"))
    func oc4062_8() {}

    // OC-4075. Seam needed: an App test target, or the coordinator's decision extracted into FlotsamLibrary.
    @Test("OC-4075 (cancel button) cancelling the Ungroup confirmation keeps B with its note and members [no seam: manual]", .disabled("no seam: manual. the Cancel button is the OrganizeCoordinator overlay (App target); the stale-selection guard and the confirmation rule are tested"))
    func oc4075_9() {}

    // OC-4077. Seam needed: an App test target, or a registry protocol with a fake in FlotsamLibrary.
    @Test("OC-4077 (hotkey goes dead) after a confirmed Ungroup, pressing H pastes nothing [no seam: manual]", .disabled("no seam: manual. the hotkey registry lives in the App target; the storage half (no member keeps the hotkey, no badge) is tested"))
    func oc4077_10() {}

    // OC-4021. Seam needed: an App test target.
    @Test("OC-4021 (popover anchoring) the tag popover opens anchored on the Tag command [no seam: manual]", .disabled("no seam: manual. SwiftUI popover placement (App target); the tag table and Create semantics are tested in Storage"))
    func oc4021_11() {}

    // OC-4022. Seam needed: an App test target, or a pure popover-rows builder in FlotsamLibrary.
    @Test("OC-4022 (Create row UI) the Create row appears for an unknown name [no seam: manual]", .disabled("no seam: manual. the Create row is rendered by the tag popover (App target); createTag is tested"))
    func oc4022_12() {}

    // OC-4023. Seam needed: an App test target, or a pure key-to-action mapping in FlotsamLibrary.
    @Test("OC-4023 (Return in the popover) Return applies the highlighted row [no seam: manual]", .disabled("no seam: manual. key handling in the tag popover (App target); applying and creating are tested"))
    func oc4023_13() {}

    // OC-4024. Seam needed: a pure popover-rows builder in FlotsamLibrary.
    @Test("OC-4024 (first-match pick UI) the first matching tag is highlighted [no seam: manual]", .disabled("no seam: manual. highlight is SwiftUI state in the popover (App target); the match rule is tested in Storage"))
    func oc4024_14() {}

    // OC-4027. Seam needed: an App test target.
    @Test("OC-4027 (popover UI half) the tag popover reflects the chosen tag state [no seam: manual]", .disabled("no seam: manual. SwiftUI rendering of check marks (App target); the stored check state and counts are tested"))
    func oc4027_15() {}

    // OC-4040. Seam needed: a pure `IngestLimits.noteCounterVisible(length:)` or LibraryOrganizer wrapper.
    @Test("OC-4040 (counter label) the note counter shows from 1800 characters [no seam: manual]", .disabled("no seam: manual. the counter label renders in NoteCard as `length >= noteCounterThreshold` (App target); the 2000 and 1800 limits and scalar counting are tested"))
    func oc4040_16() {}

    // OC-4047. Seam needed: an App test target.
    @Test("OC-4047 (in-panel editor) the editor opens in the panel for editable kinds [no seam: manual]", .disabled("no seam: manual. EditCard is an App-target overlay; which kinds save, and ORG-VAL-003 for the rest, are tested"))
    func oc4047_17() {}

    // OC-4059. Seam needed: none in the package: manual, with the running app and TextEdit.
    @Test("OC-4059 (TextEdit expansion) the trigger and the hotkey still expand in TextEdit after an edit [no seam: manual]", .disabled("no seam: manual. expansion happens in another process (TextEdit); only that trigger and hotkey survive the edit is tested"))
    func oc4059_18() {}

    // OC-4069. Seam needed: an App test target.
    @Test("OC-4069 (undo UI) Command-Z does nothing and no trash view exists [no seam: manual]", .disabled("no seam: manual. the key and the absent view are App-target UI; the storage fact (no row, no table named trash, deleted or undo) is tested"))
    func oc4069_19() {}

    // OC-4099. The arrival wiring and the no-timer path are tested in Task257LiveCountsTests.swift (the model subscribes
    // to the storage change feed while shown). Only the wall-clock number is left.
    @Test("OC-4099 (200 ms wall clock) the sidebar and footer update within 200 ms of a capture arriving, measured on the running panel [no seam: manual]", .disabled("no seam: manual. the 200 ms is a wall-clock observation of the running panel (TASK-505). The package asserts the parts that make it true: the change starts a reload at once with no timer on the path, and the reload applies the counts and footer with no further call"))
    func oc4099_20() {}
}
