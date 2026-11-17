import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T gap suite for deletion and re-copy (FR-007-15, FRD-007 section 5 business rule "dedupe after retention").
// Expected values are literals; rows and files are read back through a second connection and the disk.
//
// Layer note, OC-7128: the ungroup action belongs to FRD-004 and is not built (the only mention in the code is a
// comment on `delete(ids:)`). Ungroup's storage effect is `delete(ids:)` on the bundle item, so that is exercised with
// a bundle (the existing OC-7087 test covers a files item). The "ungroup" UI step is GAP, blocked on FRD-004.

@Suite struct DeletionGapTests {
    /// OC-7128. Given bundle B referencing files F1..F3, when B is deleted (what ungroup does to B), then B and its
    /// member rows are gone, the other item survives, and F1..F3 still exist byte-identical.
    /// Red if deletion follows a bundle member path and removes the file, or leaves member rows behind.
    @Test("OC-7087 OC-7128 deleting a bundle leaves every referenced file byte-identical and both neighbours present")
    func oc7128_deletingBundleKeepsReferencedFiles() async throws {
        // given a bundle of three real files held by reference (one is binary) sitting between two unrelated items
        let store = try await Store.make()
        let refs = References()
        defer { store.cleanUp(); refs.cleanUp() }
        let files = [try refs.make("f1.txt", "first file"), try refs.make("f2.txt", "second\nfile"), try refs.make("f3.bin", "\u{0}\u{1}third")]
        var bundle = Spec(n: 2, kind: .bundle, ageMs: 2 * hourMs)
        bundle.members = files.map { ($0.path, false) }
        try await store.insert([Spec(n: 1, ageMs: hourMs), bundle, Spec(n: 3, ageMs: 3 * hourMs)])
        #expect(try store.presentIds() == [1, 2, 3], "precondition")
        #expect(try store.count("bundleMember") == 3)

        // when the middle item (the bundle) is deleted
        let removed = try await store.database.delete(ids: [Store.id(2)]).get()

        // then only the bundle is absent, its member rows are gone, both neighbours stay, and each file is untouched
        #expect(removed == [Store.id(2)])
        #expect(try store.presentIds() == [1, 3])
        #expect(try store.count("bundleMember") == 0)
        #expect(files.map { refs.read($0) } == ["first file", "second\nfile", "\u{0}\u{1}third"])
        #expect(files.allSatisfy { store.exists($0) })
    }

    /// OC-7148. Given MARK-RT1 deleted by retention, when MARK-RT1 is copied again, then a new item exists with a
    /// different id, copyCount 1 and createdAt now; the old row is gone and search finds only the new one.
    /// Red if dedupe still matches a deleted item (the copy bumps nothing and is lost), the new row inherits the old
    /// copyCount or createdAt, or the retention sweep does not delete the item.
    @Test("OC-7148 a text deleted by retention is stored as a new item when copied again")
    func oc7148_recopyAfterRetentionIsNew() async throws {
        // given MARK-RT1 stored, copied once more inside its window (a bump), then aged 8 days past a 7-day preset
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let first = try await rig.create(rig.text("key-rt1", "MARK-RT1"))
        let bump = try await rig.ingest.ingest(rig.text("key-rt1", "MARK-RT1")).get()
        #expect(bump.outcome == .bumped(first))
        #expect(try rig.row(first).copyCount == 2)
        rig.store.clock.advance(ms: 8 * dayMs)

        // when the retention sweep runs and the same text is copied again
        let swept = try await rig.store.database.runRetentionSweep(preset: .d7, budget: .unlimited).get()
        #expect(swept.retentionDeleted == 1)
        #expect(try rig.itemCount() == 0)
        let now = rig.store.clock.millis
        let second = try await rig.create(rig.text("key-rt1", "MARK-RT1"))

        // then it is a new item: different id, copyCount 1, createdAt now; the old row stays gone
        #expect(second != first)
        #expect(try rig.itemCount() == 1)
        let row = try rig.row(second)
        #expect(row.copyCount == 1)
        #expect(row.createdAt == now)
        #expect(row.lastCopiedAt == now)
        let found = try await rig.store.database.matches("MARK-RT1")
        #expect(found.unique == [second] && found.ids.count == 1)
        let oldRows = try await rig.store.reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE id = ?", arguments: [first.uuidString])! }
        #expect(oldRows == 0)
    }

    /// OC-7148, negative. An item still inside its window is not deleted by the same sweep, so the copy is a bump and
    /// no new item appears. Red if the sweep deletes by creation date or ignores the preset.
    @Test("OC-7148 a text still inside the retention window is bumped, not recreated")
    func oc7148_insideWindowIsBumped() async throws {
        // given MARK-RT1 stored, 6 days old against a 7-day preset
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let first = try await rig.create(rig.text("key-rt1", "MARK-RT1"))
        rig.store.clock.advance(ms: 6 * dayMs)

        // when the sweep runs and the text is copied again
        let swept = try await rig.store.database.runRetentionSweep(preset: .d7, budget: .unlimited).get()
        let again = try await rig.ingest.ingest(rig.text("key-rt1", "MARK-RT1")).get()

        // then nothing was deleted, the copy bumped the same item, and the count is still 1
        #expect(swept.retentionDeleted == 0)
        #expect(again.outcome == .bumped(first))
        #expect(try rig.itemCount() == 1)
        #expect(try rig.row(first).copyCount == 2)
    }
}
