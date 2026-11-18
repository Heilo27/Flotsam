import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

/// FR-005-01 / FR-005-12 / FR-005-22: the stored hotkeys and triggers the registry and the trigger snapshot read, and
/// the change event an exemption edit now publishes.
@Suite struct ItemBindingsTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test func bindingsListsOnlyItemsWithATriggerOrHotkey() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert((1...3).map { Spec(n: $0, ageMs: hourMs) })
        _ = try await s.database.applyExemptionEdit(.setTrigger(";sig"), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setHotkey(Chord(keyCode: 40, modifiers: [.command])), to: Store.id(2)).get()

        let bindings = try await s.database.itemBindings().get()

        #expect(bindings.triggers == [Store.id(1): ";sig"])
        #expect(bindings.hotkeys == [Store.id(2): Chord(keyCode: 40, modifiers: [.command])])
    }

    @Test func clearingABindingRemovesItFromTheList() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: hourMs)])
        _ = try await s.database.applyExemptionEdit(.setTrigger(";sig"), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setTrigger(nil), to: Store.id(1)).get()

        #expect(try await s.database.itemBindings().get() == ItemBindings())
    }

    @Test func exemptionEditPublishesItemsChangedOnlyWhenApplied() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: hourMs)])
        let counter = Counter()
        let unsubscribe = s.database.events.subscribe { event in if event == .itemsChanged { counter.bump() } }
        defer { unsubscribe() }

        _ = try await s.database.applyExemptionEdit(.setTrigger(";x"), to: Store.id(1)).get()
        #expect(counter.count == 1)
        _ = try await s.database.applyExemptionEdit(.setTrigger(";y"), to: Store.id(99)).get()
        #expect(counter.count == 1)
    }
}
