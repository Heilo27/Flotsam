import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// FRD-005 8T contract tests, slice S9 (lifecycle), OC-5060 (FR-005-09): the Library list marks an item that has a hotkey,
// an item that has a trigger, and leaves an unbound item bare. Real Library over a real database; the bindings are seeded
// through `applyExemptionEdit` (the one writer, FR-007-10) and the rows are what the shipping query returns, run through
// `LibraryRowPresentation`, the pure value the row view draws. UNTESTABLE-AT-PACKAGE: the SwiftUI badge glyph itself
// (the view renders `hasShortcut` / `hasTrigger`; there is no package seam below the view for pixels). Expected values
// are literals.

private let b60Chord = Chord(keyCode: 18, modifiers: [.control, .option])
private let b60Now = Date(timeIntervalSince1970: 2_000_000)

@MainActor
private func badges(_ lib: RealLibrary) async -> [UUID: (hotkey: Bool, trigger: Bool)] {
    await lib.model.open(target: nil)
    var result: [UUID: (hotkey: Bool, trigger: Bool)] = [:]
    for (position, row) in lib.model.visibleRows.enumerated() {
        let presentation = LibraryRowPresentation(row: row, position: position, now: b60Now)
        result[presentation.id] = (presentation.hasShortcut, presentation.hasTrigger)
    }
    return result
}

@MainActor
@Suite struct FRD005ContractTestsLifecycleBadges {
    // Red if hasShortcut and hasTrigger are swapped, derived from the wrong column, or set on an unbound row.
    @Test("OC-5060 A (hotkey only) shows the hotkey badge, B (trigger only) the trigger badge, C (neither) no badge")
    func oc5060_badgesFollowBindings() async throws {
        // given: three text items; A bound to a hotkey only, B to a trigger only, C to nothing
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let a = try await lib.add(.text, key: "a5060", text: "A item", secondsAgo: 1).itemId
        let b = try await lib.add(.text, key: "b5060", text: "B item", secondsAgo: 2).itemId
        let c = try await lib.add(.text, key: "c5060", text: "C item", secondsAgo: 3).itemId
        #expect(try await lib.database.applyExemptionEdit(.setHotkey(b60Chord), to: a).get())
        #expect(try await lib.database.applyExemptionEdit(.setTrigger(";b"), to: b).get())
        // when: the Library list is shown
        let shown = await badges(lib)
        // then: three rows, each with exactly its own badge (identity, not position)
        #expect(shown.count == 3)
        #expect(shown[a]?.hotkey == true && shown[a]?.trigger == false)
        #expect(shown[b]?.hotkey == false && shown[b]?.trigger == true)
        #expect(shown[c]?.hotkey == false && shown[c]?.trigger == false)
    }

    // Red if an item with both bindings shows only one badge, or a cleared binding keeps its badge on the next list.
    @Test("OC-5060 boundary: an item with both shows both badges; clearing the hotkey drops only the hotkey badge")
    func oc5060_bothAndCleared() async throws {
        // given: one item with a hotkey and a trigger, and a bystander with neither
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let both = try await lib.add(.text, key: "both5060", text: "both", secondsAgo: 1).itemId
        let plain = try await lib.add(.text, key: "plain5060", text: "plain", secondsAgo: 2).itemId
        _ = try await lib.database.applyExemptionEdit(.setHotkey(b60Chord), to: both).get()
        _ = try await lib.database.applyExemptionEdit(.setTrigger(";both"), to: both).get()
        let withBoth = await badges(lib)
        #expect(withBoth[both]?.hotkey == true && withBoth[both]?.trigger == true)
        // when: the hotkey is cleared and the list shown again
        _ = try await lib.database.applyExemptionEdit(.setHotkey(nil), to: both).get()
        let cleared = await badges(lib)
        // then: the trigger badge stays, the hotkey badge is gone, the bystander is still bare, still two rows
        #expect(cleared.count == 2)
        #expect(cleared[both]?.hotkey == false && cleared[both]?.trigger == true)
        #expect(cleared[plain]?.hotkey == false && cleared[plain]?.trigger == false)
    }
}
