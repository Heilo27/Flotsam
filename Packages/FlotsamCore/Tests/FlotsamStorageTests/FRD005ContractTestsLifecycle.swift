import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

/// FRD-005 8T slice S9 (Lifecycle), storage half: what the database keeps and reports after a bound item is deleted,
/// ungrouped, cleared or swept. Bindings are read through a FRESH database instance (the layer the registry and the
/// trigger snapshot read). Expected values are literals.
private let ctrlOpt1 = Chord(keyCode: 18, modifiers: [.control, .option])
private let ctrlOpt2 = Chord(keyCode: 19, modifiers: [.control, .option])
private let ctrlOpt8 = Chord(keyCode: 28, modifiers: [.control, .option])
private let ctrlOpt9 = Chord(keyCode: 25, modifiers: [.control, .option])

private let lifecycleClassifiers = ItemClassifiers(
    editedText: { text in ItemClassification(kind: .text, contentKey: "edit:" + text) },
    fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) })

private func freshBindings(_ s: Store) async throws -> ItemBindings {
    let fresh = try await FlotsamDatabase.open(folder: s.root).get()
    return try await fresh.itemBindings().get()
}

@Suite struct FRD005ContractTestsLifecycle {
    // Red if delete(ids:) leaves the trigger or hotkey of the deleted item in the stored bindings, or touches the survivor.
    @Test("OC-5133 deleting the item with hotkey ⌃⌥1 and trigger ';del' removes both bindings and keeps the other item's")
    func oc5133_deleteDropsBindings() async throws {
        // given: two bound items, the one to delete holds ⌃⌥1 and ';del'
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: hourMs), Spec(n: 2, ageMs: 2 * hourMs)])
        _ = try await s.database.applyExemptionEdit(.setHotkey(ctrlOpt1), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setTrigger(";del"), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setHotkey(ctrlOpt2), to: Store.id(2)).get()
        _ = try await s.database.applyExemptionEdit(.setTrigger(";keep"), to: Store.id(2)).get()
        let events = EventCollector(s.database.events)
        #expect(try await freshBindings(s).triggers.count == 2)
        // when: the user deletes item 1
        let deleted = try await s.database.delete(ids: [Store.id(1)]).get()
        // then: one row left, it is the survivor; a fresh read holds only the survivor's bindings; the bus announced exactly item 1
        #expect(deleted == [Store.id(1)])
        #expect(try s.presentIds() == [2])
        let bindings = try await freshBindings(s)
        #expect(bindings.triggers == [Store.id(2): ";keep"])
        #expect(bindings.hotkeys == [Store.id(2): ctrlOpt2])
        #expect(events.deletedBatches == [[Store.id(1)]])
    }

    // Red if deleting an id that is not stored removes or announces anything.
    @Test("OC-5133 negative: deleting an id that does not exist keeps every row and binding and announces no deletion of it")
    func oc5133_deleteMissingId() async throws {
        // given: one bound item
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: hourMs)])
        _ = try await s.database.applyExemptionEdit(.setHotkey(ctrlOpt1), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setTrigger(";del"), to: Store.id(1)).get()
        let events = EventCollector(s.database.events)
        // when: an unknown id is deleted
        _ = try await s.database.delete(ids: [Store.id(99)]).get()
        // then: the item and its bindings are untouched
        #expect(try s.presentIds() == [1])
        #expect(try await freshBindings(s) == ItemBindings(hotkeys: [Store.id(1): ctrlOpt1], triggers: [Store.id(1): ";del"]))
        #expect(!events.deletedIds.contains(Store.id(1)))
    }

    // Red if a deleted item's trigger or chord stays in the stored bindings (the lists the validators read), or if the
    // storage layer refuses to bind them to another item afterwards.
    @Test("OC-5134 after the holder is deleted, ';del' and ⌃⌥1 are free: a fresh bindings read lacks them and another item can take both")
    func oc5134_reassignAfterDelete() async throws {
        // given: item 1 holds ⌃⌥1 and ';del', item 2 holds nothing
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: hourMs), Spec(n: 2, ageMs: 2 * hourMs)])
        _ = try await s.database.applyExemptionEdit(.setHotkey(ctrlOpt1), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setTrigger(";del"), to: Store.id(1)).get()
        #expect(try await freshBindings(s).triggers == [Store.id(1): ";del"])
        // when: item 1 is deleted and item 2 is given the same trigger and chord
        _ = try await s.database.delete(ids: [Store.id(1)]).get()
        #expect(try await freshBindings(s) == ItemBindings())
        _ = try await s.database.applyExemptionEdit(.setTrigger(";del"), to: Store.id(2)).get()
        _ = try await s.database.applyExemptionEdit(.setHotkey(ctrlOpt1), to: Store.id(2)).get()
        // then: item 2 alone holds both, read through a fresh instance
        #expect(try await freshBindings(s) == ItemBindings(hotkeys: [Store.id(2): ctrlOpt1], triggers: [Store.id(2): ";del"]))
        #expect(try s.presentIds() == [2])
    }

    // Red if Clear History (exempt kept) removes a bound item or its binding, or keeps the unbound one.
    @Test("OC-5135 Clear History with exempt items kept removes only U; B keeps its trigger and C its hotkey in a fresh read")
    func oc5135_clearHistoryKeepsBound() async throws {
        // given: B with a trigger, C with a hotkey, U with neither, all recent
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 2, ageMs: hourMs), Spec(n: 3, ageMs: 2 * hourMs), Spec(n: 4, ageMs: 3 * hourMs)])
        _ = try await s.database.applyExemptionEdit(.setTrigger(";b"), to: Store.id(2)).get()
        _ = try await s.database.applyExemptionEdit(.setHotkey(ctrlOpt2), to: Store.id(3)).get()
        // when: Clear History runs over all time without the exempt items
        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: false).get()
        // then: one deleted (U), B and C stay with their bindings
        #expect(outcome.deletedCount == 1)
        #expect(try s.presentIds() == [2, 3])
        let bindings = try await freshBindings(s)
        #expect(bindings.triggers == [Store.id(2): ";b"])
        #expect(bindings.hotkeys == [Store.id(3): ctrlOpt2])
    }

    // Red if the "keep exempt items" switch is ignored: with it off the bound items go too, and so do their bindings.
    @Test("OC-5135 boundary: Clear History that includes exempt items removes B and C and every binding")
    func oc5135_clearIncludingExempt() async throws {
        // given: the same three items
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 2, ageMs: hourMs), Spec(n: 3, ageMs: 2 * hourMs), Spec(n: 4, ageMs: 3 * hourMs)])
        _ = try await s.database.applyExemptionEdit(.setTrigger(";b"), to: Store.id(2)).get()
        _ = try await s.database.applyExemptionEdit(.setHotkey(ctrlOpt2), to: Store.id(3)).get()
        // when: Clear History includes the exempt items
        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: true).get()
        // then: all three are gone and no binding remains
        #expect(outcome.deletedCount == 3)
        #expect(try s.presentIds().isEmpty)
        #expect(try await freshBindings(s) == ItemBindings())
    }

    // Red if ungrouping leaves the bundle's chord bound, hands a binding to a created member, or disturbs another
    // item's chord.
    @Test("OC-5136 ungrouping the bundle bound to ⌃⌥8 leaves no binding on it or on any member; another item's ⌃⌥9 stays")
    func oc5136_ungroupDropsBundleBinding() async throws {
        // given: a bundle with four members holding ⌃⌥8, and a control item holding ⌃⌥9
        let s = try await Store.make()
        defer { s.cleanUp() }
        var bundle = Spec(n: 1, kind: .bundle, ageMs: hourMs)
        bundle.members = [("/a/one.txt", false), ("/a/two", true), ("/a/three.png", false), ("/a/four.pdf", false)]
        try await s.insert([bundle, Spec(n: 2, ageMs: 2 * hourMs)])
        _ = try await s.database.applyExemptionEdit(.setHotkey(ctrlOpt8), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setHotkey(ctrlOpt9), to: Store.id(2)).get()
        #expect(try await freshBindings(s).hotkeys == [Store.id(1): ctrlOpt8, Store.id(2): ctrlOpt9])
        // when: the bundle is ungrouped
        let members = try await s.database.ungroup(bundle: Store.id(1), classifiers: lifecycleClassifiers).get()
        // then: four members exist, the bundle is gone, and the only binding left is the control item's
        #expect(members.count == 4)
        let storedIds = try await s.reader().read { try String.fetchAll($0, sql: "SELECT id FROM item") }
        #expect(!storedIds.contains(Store.id(1).uuidString))
        #expect(storedIds.contains(Store.id(2).uuidString))
        #expect(try s.count("item") == 5)
        let bindings = try await freshBindings(s)
        #expect(bindings.hotkeys == [Store.id(2): ctrlOpt9])
        #expect(bindings.triggers.isEmpty)
        #expect(members.allSatisfy { bindings.hotkeys[$0] == nil && bindings.triggers[$0] == nil })
    }

    // Red if an item with a trigger can be removed by the retention sweep (the exempt rule is lost).
    @Test("OC-5137 first sweep: an unpinned item older than the window that holds ';old' is kept")
    func oc5137_firstSweepKeeps() async throws {
        // given: an item 31 days old with a trigger, plus an unbound old item that must go
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: 31 * dayMs), Spec(n: 2, ageMs: 31 * dayMs)])
        _ = try await s.database.applyExemptionEdit(.setTrigger(";old"), to: Store.id(1)).get()
        // when: the 30-day retention sweep runs
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        // then: the bound item remains with its trigger, the unbound one is gone
        #expect(try s.presentIds() == [1])
        #expect(try await freshBindings(s).triggers == [Store.id(1): ";old"])
    }

    // The contract: "after the second [sweep] it is gone". Production (FR-007-10 / FR-007-08) keeps a released item for
    // a 24-hour grace, so the immediate second sweep keeps it. Spec conflict, recorded as a known issue.
    @Test("OC-5137 contract: clearing the trigger and sweeping again removes the item (immediately, as the contract says)")
    func oc5137_secondSweepRemovesImmediately() async throws {
        // given: the item from the first sweep, trigger now cleared
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: 31 * dayMs)])
        _ = try await s.database.applyExemptionEdit(.setTrigger(";old"), to: Store.id(1)).get()
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        #expect(try s.presentIds() == [1])
        _ = try await s.database.applyExemptionEdit(.setTrigger(nil), to: Store.id(1)).get()
        // when: the sweep runs again right away
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        // then: the contract says it is gone
        let remaining = try s.presentIds()
        withKnownIssue("FRD-005 OC-5137: contract says the item is gone after the second sweep; FR-007-10 keeps a released item for a 24-hour grace") {
            #expect(remaining.isEmpty)
        }
    }

    // Red if the grace is dropped or never ends: the item must survive exactly 24h after release and go after it.
    @Test("OC-5137 companion: after the trigger is cleared the item survives a sweep at exactly 24h and is gone 1 ms later")
    func oc5137_graceBoundary() async throws {
        // given: an old item whose trigger was released at the clock's current time
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: 31 * dayMs)])
        _ = try await s.database.applyExemptionEdit(.setTrigger(";old"), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setTrigger(nil), to: Store.id(1)).get()
        #expect(try s.exemptReleasedAt(1) != nil)
        // when: a sweep runs at 24h exactly, then 1 ms after
        s.clock.advance(ms: dayMs)
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        let atBoundary = try s.presentIds()
        s.clock.advance(ms: 1)
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        let afterBoundary = try s.presentIds()
        // then: kept at the boundary, gone past it
        #expect(atBoundary == [1])
        #expect(afterBoundary.isEmpty)
    }

    // Red if an edit of the text re-keys the row so that the item loses its identity, trigger or chord.
    @Test("OC-5138 editing the text of the item holding ';e' and ⌃⌥E keeps one row, the same id and both bindings; the stored text is 'two'")
    func oc5138_editKeepsBindings() async throws {
        // given: an item 'one' with trigger ';e' and chord ⌃⌥E (key code 14), and a bystander
        let s = try await Store.make()
        defer { s.cleanUp() }
        let chordE = Chord(keyCode: 14, modifiers: [.control, .option])
        try await s.insert([Spec(n: 1, ageMs: hourMs, text: "one"), Spec(n: 2, ageMs: 2 * hourMs, text: "other")])
        _ = try await s.database.applyExemptionEdit(.setTrigger(";e"), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setHotkey(chordE), to: Store.id(1)).get()
        // when: the user edits the text to 'two'
        _ = try await s.database.editText(id: Store.id(1), to: "two", classifiers: lifecycleClassifiers).get()
        // then: still two rows, id 1 holds 'two' and both bindings, the bystander is unchanged
        #expect(try s.presentIds() == [1, 2])
        let texts = try await s.reader().read { try String.fetchAll($0, sql: "SELECT plainText FROM item ORDER BY plainText") }
        #expect(texts == ["other", "two"])
        let bindings = try await freshBindings(s)
        #expect(bindings.triggers == [Store.id(1): ";e"])
        #expect(bindings.hotkeys == [Store.id(1): chordE])
    }
}
