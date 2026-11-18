import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

/// FR-005-22: every applied exemption edit (pin, trigger, hotkey) publishes `.itemsChanged` exactly once after the
/// commit, so the hotkey registry and the trigger snapshot rebuild; an edit that matched no item publishes nothing.
@Suite("FR-005-22 worf: exemption edits publish itemsChanged")
struct ExemptionEditEventsWorfTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private static let edits: [(String, ExemptionEdit)] = [
        ("pin", .setPinned(true)),
        ("unpin", .setPinned(false)),
        ("set trigger", .setTrigger(";sig")),
        ("clear trigger", .setTrigger(nil)),
        ("set hotkey", .setHotkey(Chord(keyCode: 40, modifiers: .command))),
        ("clear hotkey", .setHotkey(nil)),
    ]

    /// OC-WEE-001. given an existing item, when each edit kind is applied, then the call reports applied (true) and
    /// exactly one `.itemsChanged` is published per edit (count delta 1 each). Red if any edit kind stops publishing
    /// (a rebuild consumer would miss it) or publishes twice.
    @Test("OC-WEE-001 each applied edit publishes exactly one itemsChanged")
    func appliedEditsPublishOnce() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: hourMs)])
        let counter = Counter()
        let unsubscribe = s.database.events.subscribe { event in if event == .itemsChanged { counter.bump() } }
        defer { unsubscribe() }

        for (index, (name, edit)) in Self.edits.enumerated() {
            let applied = try await s.database.applyExemptionEdit(edit, to: Store.id(1)).get()
            #expect(applied, "\(name) was not applied")
            #expect(counter.count == index + 1, "\(name): itemsChanged count")
        }
    }

    /// OC-WEE-002. given no item with that id, when each edit kind is applied, then the call reports not applied (false)
    /// and publishes nothing (count delta 0). Red if an edit on a missing item publishes a spurious rebuild.
    @Test("OC-WEE-002 an edit on a missing item publishes nothing", arguments: [0, 1, 2, 3, 4, 5])
    func missingItemPublishesNothing(index: Int) async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: hourMs)])
        let counter = Counter()
        let unsubscribe = s.database.events.subscribe { event in if event == .itemsChanged { counter.bump() } }
        defer { unsubscribe() }

        let applied = try await s.database.applyExemptionEdit(Self.edits[index].1, to: Store.id(99)).get()

        #expect(!applied, "\(Self.edits[index].0) on a missing id")
        #expect(counter.count == 0)
    }

    /// OC-WEE-003. given a trigger edit, when the event reaches a subscriber, then the bindings read through a FRESH
    /// reader already show the new trigger (published after the commit, not before). Red if the publish moves before the
    /// transaction commits.
    @Test("OC-WEE-003 the event is published after the commit: a subscriber reading on it sees the edit")
    func publishedAfterCommit() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: hourMs)])
        let database = s.database
        let seen = SeenTriggers()
        let unsubscribe = database.events.subscribe { event in
            guard event == .itemsChanged else { return }
            Task { seen.set(try? await database.itemBindings().get().triggers) }
        }
        defer { unsubscribe() }

        _ = try await database.applyExemptionEdit(.setTrigger(";after"), to: Store.id(1)).get()
        for _ in 0..<200 where seen.value == nil { try await Task.sleep(for: .milliseconds(10)) }

        #expect(seen.value == [Store.id(1): ";after"])
    }

    private final class SeenTriggers: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UUID: String]?
        func set(_ v: [UUID: String]?) { lock.withLock { stored = v } }
        var value: [UUID: String]? { lock.withLock { stored } }
    }
}
