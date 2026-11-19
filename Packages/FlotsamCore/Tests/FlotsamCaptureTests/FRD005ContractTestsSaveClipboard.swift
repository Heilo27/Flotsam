import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture
@testable import FlotsamShortcuts

// FRD-005 8T contract tests, slice S4 (Save Clipboard: FR-005-06, OC-5034..OC-5040), written from the blind oracle
// contract (.claude/oracle/frd-005-contract.json). Each test asserts the contract's "then" with literal numbers and
// literal HUD text.
//
// Layering: the REAL `ClipboardCapture.saveClipboardNow` (classifier gates, ingest actor, a real database in a temp
// folder) is driven through the REAL `SaveClipboardAction` that the chord runs, so the HUD under test is what the user
// reads. Only the pasteboard, source-app lookup, clock, settings store and timer are fakes (ContractRig). Every count
// and every row is read back through a FRESH database instance on the same folder, never an in-memory array. The
// target FlotsamCaptureTests lists FlotsamShortcuts as a test-only dependency for this file (no target imports both;
// production Shortcuts still never imports Capture, ADR-0001).
//
// The press of the chord itself (Carbon registration, the chord reaching the action) is slice S2/S3; here the action
// the chord runs is invoked directly. "Copied in TextEdit" is the pasteboard fake holding that text.
// Analogues that stay as they are: SaveClipboardWorfTests (OC-WSC-*) and SaveClipboardActionWorfTests (OC-WSA-*).
//
// Drift D1: TriggerExpanderAdversarialTests carries the OC-5036/5037 tags on tests that assert OC-5108 behaviour. The
// tests below are the real 5036/5037.

private let hudSaved = "Saved to Flotsam"
private let hudPrivate = "Not saved: the app that copied it marked it private"
private let hudIgnored = "Not saved: that app is on your ignored list"
private let hudEmpty = "Nothing on the clipboard Flotsam can save"

private final class HUDBox {
    var shown: [String] = []
}

@MainActor
private func pressSaveClipboard(_ rig: ContractRig) async -> [String] {
    let box = HUDBox()
    await SaveClipboardAction(saver: rig.capture, hud: { box.shown.append($0) }).run()
    return box.shown
}

/// Copies `text` and saves it, advancing the manual clock first so Recent order is decided by time, not by tie-break.
@MainActor
private func seed(_ rig: ContractRig, _ text: String) async {
    rig.clock.advance(by: 10)
    rig.pasteboard.copyText(text)
    _ = await pressSaveClipboard(rig)
}

private struct FreshRow: Equatable {
    let id: UUID
    let text: String
    let copyCount: Int
}

/// Library "Recent" order (newest copy first), read through a fresh database instance.
@MainActor
private func freshRecent(_ rig: ContractRig) async throws -> [FreshRow] {
    let fresh = try await FlotsamDatabase.open(folder: rig.folder).get()
    let order = try await fresh.items(matching: LibraryQuery(sort: .recent)).get().rows.map(\.id)
    let counts: [String: Int] = try await fresh.pool.read { db in
        var map: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, copyCount FROM item") { map[row["id"]] = row["copyCount"] }
        return map
    }
    let texts: [String: String] = try await fresh.pool.read { db in
        var map: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, plainText FROM item") { map[row["id"]] = row["plainText"] ?? "" }
        return map
    }
    return order.map { FreshRow(id: $0, text: texts[$0.uuidString] ?? texts[$0.uuidString.lowercased()] ?? "?", copyCount: counts[$0.uuidString] ?? counts[$0.uuidString.lowercased()] ?? -1) }
}

@MainActor
private func freshCount(_ rig: ContractRig) async throws -> Int {
    try await freshRecent(rig).count
}

@MainActor
private func withCuratedRig(
    frontmost: SourceApp? = ContractRig.writerApp, withVault: Bool = false, _ body: (ContractRig) async throws -> Void
) async throws {
    try await withRig(frontmost: frontmost, withVault: withVault, scheduleTimer: inertTimer) { rig in
        rig.settings.set(CaptureMode.curated, for: SettingKeys.captureMode)
        try await body(rig)
    }
}

@MainActor @Suite("FRD-005 contract: Save Clipboard (S4)", .serialized, .timeLimit(.minutes(2)))
struct FRD005ContractTestsSaveClipboard {
    @Test("OC-5034 Curated: Save Clipboard adds one item, it is the top of Recent, and the saved HUD appears")
    func oc5034CuratedSavesToTopOfRecent() async throws {
        try await withCuratedRig { rig in
            // given Curated mode, two items already stored (N = 2), and 'curated-xyz' copied but not in history
            await seed(rig, "seed-a")
            await seed(rig, "seed-b")
            rig.clock.advance(by: 10)
            rig.pasteboard.copyText("curated-xyz")
            await rig.process()
            let before = try await freshRecent(rig)
            #expect(before.count == 2)
            #expect(!before.map(\.text).contains("curated-xyz"))
            // when the user presses the Save Clipboard chord
            let hud = await pressSaveClipboard(rig)
            // then the count is N+1, 'curated-xyz' tops Recent (copied once), the older items survive, one saved HUD
            let after = try await freshRecent(rig)
            #expect(after.count == 3)
            #expect(after.first?.text == "curated-xyz")
            #expect(after.first?.copyCount == 1)
            #expect(Set(after.dropFirst().map(\.id)) == Set(before.map(\.id)))
            #expect(hud == [hudSaved])
        }
    }

    @Test("OC-5035 Paused: Save Clipboard still saves, the mode stays Paused, and the next copy is not captured")
    func oc5035PausedSavesAndStaysPaused() async throws {
        try await withRig(scheduleTimer: inertTimer) { rig in
            // given Paused mode, one item stored (N = 1) and 'paused-xyz' copied
            rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
            await seed(rig, "paused-seed")
            rig.pasteboard.copyText("paused-xyz")
            await rig.process()
            #expect(try await freshCount(rig) == 1)
            // when the user presses the chord, then copies 'paused-2'
            let hud = await pressSaveClipboard(rig)
            rig.pasteboard.copyText("paused-2")
            await rig.process()
            // then the count is N+1 with 'paused-xyz' present, the saved HUD showed, Paused holds, 'paused-2' is absent
            let after = try await freshRecent(rig)
            #expect(after.count == 2)
            #expect(after.map(\.text).contains("paused-xyz"))
            #expect(!after.map(\.text).contains("paused-2"))
            #expect(hud == [hudSaved])
            #expect(rig.settings.value(SettingKeys.captureMode) == .paused)
        }
    }

    /// OC-5036 (FR-005-06 / AC-005-06 as amended in TASK-503). Mutation: restore the old drop for Concealed in the
    /// capture gate: the count stays N, the HUD is the private one and no secure row exists, so each expectation is red.
    @Test("OC-5036 Concealed content is saved as a secure item: count N+1, no item holds the plain text, the saved HUD appears")
    func oc5036ConcealedIsSavedAsSecureItem() async throws {
        try await withCuratedRig(withVault: true) { rig in
            // given one item stored (N = 1) and Concealed content on the clipboard
            await seed(rig, "kept-before")
            rig.clock.advance(by: 10)
            rig.pasteboard.copyText("conceal-secret-xyz", extra: [(PasteboardMarkers.concealed, Data())])
            let readsBefore = rig.pasteboard.bytesRequested.count
            // when the user presses the chord
            let hud = await pressSaveClipboard(rig)
            // then count is N+1 with one secure row, no item holds the plain text (the new row has none), the saved HUD
            // shows, and only the plain text of the concealed copy was read
            let after = try await freshRecent(rig)
            #expect(after.count == 2)
            #expect(after.map(\.text).contains("kept-before"))
            #expect(!after.contains { $0.text.contains("conceal-secret-xyz") })
            try #expect(await rig.secureRows().count == 1)
            try #expect(await rig.secureRows().first?.plainText == nil)
            #expect(rig.allDataBytes().range(of: Data("conceal-secret-xyz".utf8)) == nil)
            #expect(hud == [hudSaved])
            #expect(Array(rig.pasteboard.bytesRequested.dropFirst(readsBefore)) == [PB.text])
        }
    }

    @Test("OC-5037 Transient content is not saved: count stays N, no item holds it, a CAP HUD appears")
    func oc5037TransientIsRejected() async throws {
        try await withCuratedRig { rig in
            // given one item stored (N = 1) and Transient content on the clipboard
            await seed(rig, "kept-before")
            rig.clock.advance(by: 10)
            rig.pasteboard.copyText("transient-secret-xyz", extra: [(PasteboardMarkers.transient, Data())])
            let readsBefore = rig.pasteboard.bytesRequested.count
            // when the user presses the chord
            let hud = await pressSaveClipboard(rig)
            // then count stays N, no item holds the content, the private-content CAP-POL-001 HUD shows, bytes unread
            let after = try await freshRecent(rig)
            #expect(after.count == 1)
            #expect(after.map(\.text) == ["kept-before"])
            #expect(!after.contains { $0.text.contains("transient-secret-xyz") })
            #expect(hud == [hudPrivate])
            #expect(rig.pasteboard.bytesRequested.count == readsBefore)
        }
    }

    @Test("OC-5038 An ignored app's copy is not saved (CAP-POL-002 HUD); the same copy saves once the app is not ignored")
    func oc5038IgnoredAppIsRejected() async throws {
        let keychain = SourceApp(bundleId: "com.apple.keychainaccess", name: "Keychain Access")
        try await withCuratedRig(frontmost: keychain) { rig in
            // given Keychain Access on the ignored list, one item stored (N = 1), and text copied from it
            await seed(rig, "kept-before")
            rig.ignored = ["com.apple.keychainaccess"]
            rig.clock.advance(by: 10)
            rig.pasteboard.copyText("from-keychain-xyz")
            // when the user presses the chord
            let hud = await pressSaveClipboard(rig)
            // then the count stays N and the ignored-app HUD appears, with no saved HUD
            let after = try await freshRecent(rig)
            #expect(after.count == 1)
            #expect(after.map(\.text) == ["kept-before"])
            #expect(hud == [hudIgnored])
            // and with the app taken off the list, the very same clipboard saves (the rejection was the list's doing)
            rig.ignored = []
            let hudAfterUnignore = await pressSaveClipboard(rig)
            #expect(hudAfterUnignore == [hudSaved])
            #expect(try await freshRecent(rig).map(\.text) == ["from-keychain-xyz", "kept-before"])
        }
    }

    @Test("OC-5039 An empty clipboard is not saved: count stays N, the empty-content HUD appears, no saved HUD")
    func oc5039EmptyClipboardIsRejected() async throws {
        try await withCuratedRig { rig in
            // given one item stored (N = 1) and an empty clipboard
            await seed(rig, "kept-before")
            rig.pasteboard.clear()
            // when the user presses the chord
            let hud = await pressSaveClipboard(rig)
            // then the count stays N, the empty-content HUD is the only HUD, and the saved HUD never shows
            let after = try await freshRecent(rig)
            #expect(after.count == 1)
            #expect(after.map(\.text) == ["kept-before"])
            #expect(hud == [hudEmpty])
            #expect(!hud.contains(hudSaved))
        }
    }

    @Test("OC-5040 Saving a clip already in history adds no row: it moves to the top of Recent, copy count +1, saved HUD")
    func oc5040DuplicateBumpsToTop() async throws {
        try await withCuratedRig { rig in
            // given 'dup-xyz' stored first, then two newer items, so it is not the top of Recent (N = 3)
            await seed(rig, "dup-xyz")
            await seed(rig, "newer-a")
            await seed(rig, "newer-b")
            let before = try await freshRecent(rig)
            #expect(before.map(\.text) == ["newer-b", "newer-a", "dup-xyz"])
            let dupBefore = try #require(before.first { $0.text == "dup-xyz" })
            #expect(dupBefore.copyCount == 1)
            // when 'dup-xyz' is copied again and the user presses the chord
            rig.clock.advance(by: 100)
            rig.pasteboard.copyText("dup-xyz")
            let hud = await pressSaveClipboard(rig)
            // then the count stays N, the same row is on top with copy count 2, the others are untouched, saved HUD
            let after = try await freshRecent(rig)
            #expect(after.count == 3)
            #expect(after.map(\.text) == ["dup-xyz", "newer-b", "newer-a"])
            #expect(after.first?.id == dupBefore.id)
            #expect(after.first?.copyCount == 2)
            #expect(after.dropFirst().map(\.copyCount) == [1, 1])
            #expect(hud == [hudSaved])
        }
    }
}
