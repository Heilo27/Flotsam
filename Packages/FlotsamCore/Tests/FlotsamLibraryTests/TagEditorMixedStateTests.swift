import FlotsamBase
import Foundation
import GRDB
import Testing
@testable import FlotsamLibrary
@testable import FlotsamStorage

// TASK-238 / AC-004-04 (FR-004-03): "Given 3 items selected and a tag on only one of them, then the editor shows mixed
// state, toggling applies to all 3, toggling again removes from all 3."
//
// What the editor draws is decided from two numbers: how many selected items carry the tag (`tagMembershipOfSelection`,
// public API of the view model) and how many are selected (`model.selection.count`). In App/OrganizeOverlays.swift (TagRow)
// none = 0, all = applied >= total, mixed = anything between. That mapping lives in a SwiftUI view in the App target, which no
// package test can reach; it is reported as a gap, not tested here. These tests pin the two numbers the mapping consumes, on a
// real FlotsamDatabase, with literal expectations and state read back through a second read-only connection.

@MainActor
@Suite struct TagEditorMixedStateTests {
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    private func tagged(_ rig: Rig, tag: Int64) throws -> [Int] {
        try rig.fresh { db in
            try String.fetchAll(db, sql: "SELECT itemId FROM itemTag WHERE tagId = ?", arguments: [tag])
                .map { Int(String($0.suffix(12)))! }.sorted()
        }
    }

    // Red if membership counts rows of other items, ignores the selection, or reports a full tag for a partial one.
    @Test("OC-4004 given 3 selected items with the tag on only item 1 (and on unselected item 4), when the editor opens, then the tag counts 1 of 3, not 2 of 3 and not 3")
    func mixedMembership() async throws {
        let rig = try await Rig((1...4).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        let tag = try await rig.database.createTag(name: "Work").get()
        _ = try await rig.database.toggleTag(id: tag, on: [Self.id(1), Self.id(4)]).get()
        rig.select(1, 2, 3)
        #expect(rig.model.selection.count == 3)

        let membership = await rig.model.tagMembershipOfSelection()

        #expect(membership == [tag: 1])
        #expect(try tagged(rig, tag: tag) == [1, 4])
    }

    // Red if toggling a mixed tag removes it (it must go on all 3), or touches the unselected item, or toggles back wrongly.
    @Test("OC-4004 given a mixed tag on a selection of 3, when toggled, then it is on all 3 (applied); when toggled again, it is on none of the 3 and the unselected item keeps it")
    func toggleAppliesThenRemoves() async throws {
        let rig = try await Rig((1...4).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        let tag = try await rig.database.createTag(name: "Work").get()
        _ = try await rig.database.toggleTag(id: tag, on: [Self.id(1), Self.id(4)]).get()
        rig.select(1, 2, 3)
        #expect(try rig.count("itemTag") == 2)

        let first = await rig.model.toggleTagOnSelection(tag)

        #expect(first == true)
        #expect(await rig.model.tagMembershipOfSelection() == [tag: 3])
        #expect(try tagged(rig, tag: tag) == [1, 2, 3, 4])
        #expect(try rig.count("itemTag") == 4)

        let second = await rig.model.toggleTagOnSelection(tag)

        #expect(second == false)
        #expect(await rig.model.tagMembershipOfSelection() == [:])
        #expect(try tagged(rig, tag: tag) == [4])
        #expect(try rig.count("itemTag") == 1)
        #expect(rig.reported.errors.isEmpty)
    }

    // Boundary: all 3 carry it, which is "checked", not "mixed": the count equals the selection size, and one toggle removes it from all.
    // Red if membership under-counts a fully tagged selection, or toggling a full tag applies instead of removes.
    @Test("OC-4004 given the tag on all 3 selected items, when the editor opens and the tag is toggled, then it counts 3 of 3 and toggling removes it from all 3")
    func fullTagIsNotMixed() async throws {
        let rig = try await Rig((1...3).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        let tag = try await rig.database.createTag(name: "All").get()
        _ = try await rig.database.toggleTag(id: tag, on: (1...3).map(Self.id)).get()
        rig.select(1, 2, 3)

        #expect(await rig.model.tagMembershipOfSelection() == [tag: 3])
        #expect(await rig.model.toggleTagOnSelection(tag) == false)
        #expect(await rig.model.tagMembershipOfSelection() == [:])
        #expect(try rig.count("itemTag") == 0)
    }

    // Boundary: none of the 3 carry it, so the tag is absent from the counts (unchecked); one toggle applies it to all 3.
    // Red if an absent tag shows up as a phantom count, or if toggling a none-state tag removes instead of applies.
    @Test("OC-4004 given a tag on none of the 3 selected items, when the editor opens and the tag is toggled, then it is absent from the counts and toggling applies it to all 3")
    func noneThenApplies() async throws {
        let rig = try await Rig((1...3).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        let tag = try await rig.database.createTag(name: "Fresh").get()
        rig.select(1, 2, 3)

        #expect(await rig.model.tagMembershipOfSelection() == [:])
        #expect(await rig.model.toggleTagOnSelection(tag) == true)
        #expect(await rig.model.tagMembershipOfSelection() == [tag: 3])
        #expect(try rig.count("itemTag") == 3)
    }

    // Boundary: a selection of 1 and 2 of 3 selected. 2 of 3 is mixed too (count strictly between 0 and the selection size).
    // Red if membership is clamped to 0/total (2 would collapse to 3 or 1).
    @Test("OC-4004 given the tag on 2 of 3 selected items, when the editor opens, then it counts exactly 2, and toggling applies to the third")
    func twoOfThreeIsMixed() async throws {
        let rig = try await Rig((1...3).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        let tag = try await rig.database.createTag(name: "Two").get()
        _ = try await rig.database.toggleTag(id: tag, on: [Self.id(1), Self.id(2)]).get()
        rig.select(1, 2, 3)

        #expect(await rig.model.tagMembershipOfSelection() == [tag: 2])
        #expect(await rig.model.toggleTagOnSelection(tag) == true)
        #expect(try tagged(rig, tag: tag) == [1, 2, 3])
    }

    // Empty selection: the editor has nothing to show and a toggle is a no-op that writes nothing.
    // Red if an empty selection counts every item as selected or toggles the tag onto the whole library.
    @Test("OC-4004 given no selection, when membership is read and a toggle is attempted, then the counts are empty, the toggle returns nil, and no link is written")
    func emptySelection() async throws {
        let rig = try await Rig((1...3).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        let tag = try await rig.database.createTag(name: "Idle").get()
        _ = try await rig.database.toggleTag(id: tag, on: [Self.id(1)]).get()
        rig.select(1)
        rig.model.toggle(id: Self.id(1))
        #expect(rig.model.selection.isEmpty)

        #expect(await rig.model.tagMembershipOfSelection() == [:])
        #expect(await rig.model.toggleTagOnSelection(tag) == nil)
        #expect(try rig.count("itemTag") == 1)
    }
}
