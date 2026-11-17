import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T gap batch, what renews an item for retention (FR-007-09, FRD-007 section 5). Age is measured from
// lastCopiedAt only. Copying again renews it; creating it long ago, pasting it, opening it or editing it does not.
//
// Layer note (OC-7070): pasting, opening the preview and editing text belong to the Library and Paste FRDs and have no
// Storage entry point yet, so those actions are arranged as the column writes they would leave behind (pasteCount,
// lastUsedAt, updatedAt, plainText). What is under test is that the sweep predicate ignores those columns. The wiring
// of the real actions is GAP-blocked on those FRDs.

@Suite struct RetentionRenewalTests {
    /// OC-7069. Given retention 30 days and item O created 45 days ago, last copied 31 days ago, when O's content is
    /// copied again and a sweep runs, then O is present with the same id and lastCopiedAt now; a twin that was not
    /// re-copied is deleted, and an item copied 29 days ago stays.
    @Test("OC-7069 a re-copy renews: age counts from lastCopiedAt, not createdAt")
    func oc7069_recopyRenews() async throws {
        // given O, a twin of identical age, and a younger item
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.store.insert([
            Spec(n: 1, ageMs: 29 * dayMs),
            Spec(n: 2, ageMs: 31 * dayMs, createdAgeMs: 45 * dayMs),
            Spec(n: 3, ageMs: 31 * dayMs, createdAgeMs: 45 * dayMs),
            Spec(n: 4, ageMs: hourMs),
        ])
        let now = rig.store.clock.millis
        #expect(try rig.row(Store.id(2)).lastCopiedAt == now - 31 * dayMs)

        // when O's content is copied again, then a 30 day sweep runs
        let again = try await rig.ingest.ingest(rig.text("key-2", "item 2")).get()
        let outcome = try await rig.store.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        // then O is the same item, renewed to now; only the untouched twin was deleted
        guard case .bumped(let id) = again.outcome else {
            Issue.record("expected the re-copy to bump O")
            return
        }
        #expect(id == Store.id(2))
        #expect(outcome.retentionDeleted == 1)
        #expect(try rig.store.presentIds() == [1, 2, 4])
        let o = try rig.row(Store.id(2))
        #expect(o.lastCopiedAt == now)
        #expect(o.copyCount == 2)
        #expect(o.createdAt == now - 45 * dayMs)
        #expect(try rig.itemCount() == 3)
    }

    /// OC-7069 boundary. Given an item created 45 days ago that was last copied 1 ms over 30 days ago and one exactly 30
    /// days ago, when a sweep runs, then only the first goes: createdAt plays no part either way.
    @Test("OC-7069 boundary: 30 days from lastCopiedAt is kept, 1 ms more goes, whatever createdAt says")
    func oc7069_boundaryIgnoresCreatedAt() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.store.insert([
            Spec(n: 1, ageMs: 30 * dayMs + 1, createdAgeMs: 45 * dayMs),
            Spec(n: 2, ageMs: 30 * dayMs, createdAgeMs: 45 * dayMs),
            Spec(n: 3, ageMs: 5 * dayMs, createdAgeMs: 400 * dayMs),
        ])

        let outcome = try await rig.store.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        #expect(outcome.retentionDeleted == 1)
        #expect(try rig.store.presentIds() == [2, 3])
    }

    /// OC-7070. Given retention 30 days and items X, Y, Z last copied 31 days ago (with a fourth, W, that nothing
    /// touches, and S copied recently), when X is pasted, Y is opened in the preview and Z's text is edited, then a
    /// sweep runs, then none of X, Y, Z remains, W is gone too, and only S survives.
    @Test("OC-7070 pasting, opening and editing do not renew an item")
    func oc7070_useDoesNotRenew() async throws {
        // given X, Y, Z, W all last copied 31 days ago and S an hour ago
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let old = 31 * dayMs
        try await rig.store.insert([
            Spec(n: 1, ageMs: old), Spec(n: 2, ageMs: old), Spec(n: 3, ageMs: old), Spec(n: 4, ageMs: old),
            Spec(n: 5, ageMs: hourMs),
        ])
        let now = rig.store.clock.millis
        #expect(try rig.itemCount() == 5)

        // when X is pasted (paste count and last-used), Y is opened (last-used), Z is edited (text and updatedAt)
        try await rig.store.database.pool.write { db in
            try db.execute(
                sql: "UPDATE item SET pasteCount = pasteCount + 1, lastUsedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, Store.id(1).uuidString])
            try db.execute(
                sql: "UPDATE item SET lastUsedAt = ? WHERE id = ?", arguments: [now, Store.id(2).uuidString])
            try db.execute(
                sql: "UPDATE item SET plainText = 'edited', searchText = 'edited', updatedAt = ? WHERE id = ?",
                arguments: [now, Store.id(3).uuidString])
        }
        #expect(try rig.row(Store.id(1)).pasteCount == 1)
        #expect(try rig.row(Store.id(1)).lastUsedAt == now)
        #expect(try rig.row(Store.id(3)).plainText == "edited")
        let outcome = try await rig.store.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        // then none of the three remains, nor the untouched one; the recent item is the only survivor
        #expect(outcome.retentionDeleted == 4)
        #expect(try rig.store.presentIds() == [5])
        #expect(try rig.itemCount() == 1)
    }
}
