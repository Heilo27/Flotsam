import FlotsamBase
import Foundation
import Testing
@testable import FlotsamStorage

// TASK-413 blind QA (Worf), branch worf-413. FRD-003 FR-003-14: ItemContent carries first-copied, copy count, note and
// tags for the preview's metadata block. Real database, real ingest, content read back through a fresh query.
// Expected side is literals. Each test names its red-making change.

@Suite struct Worf413ItemContentTests {
    private func ingest(_ rig: Rig, _ key: String, _ text: String, atMillis: Int64) async throws -> UUID {
        let result = try await rig.ingest.ingest(rig.text(key, text, at: atMillis)).get()
        switch result.outcome {
        case .created(let id), .bumped(let id), .unchanged(let id): return id
        }
    }

    private func content(_ rig: Rig, _ id: UUID) async throws -> ItemContent {
        try await rig.store.database.content(of: id).get()
    }

    // Red if copyCount is not selected (stays default 1) or firstCopiedAt reads lastCopiedAt instead of createdAt.
    @Test("OC-3061 W413-S1 first copied stays at the first copy; copy count counts every copy (1 -> 3)")
    func w413_firstCopiedAndCount() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp() }
        // given: one text copied at t=1,000,000 ms, again at 2,000,000, again at 3,000,000
        let id = try await ingest(rig, "k", "hello", atMillis: 1_000_000)
        let once = try await content(rig, id)
        #expect(once.copyCount == 1)
        #expect(once.firstCopiedAt == Date(timeIntervalSince1970: 1_000))
        _ = try await ingest(rig, "k", "hello", atMillis: 2_000_000)
        _ = try await ingest(rig, "k", "hello", atMillis: 3_000_000)
        // when
        let thrice = try await content(rig, id)
        // then
        #expect(thrice.copyCount == 3)
        #expect(thrice.firstCopiedAt == Date(timeIntervalSince1970: 1_000))
    }

    // Red if tags are not loaded, are unsorted, ignore case in the sort, or lose their colour.
    @Test("OC-3105 W413-S2 tags load alphabetically (case-insensitive) with their colours; note loads")
    func w413_tagsAndNote() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp() }
        let id = try await ingest(rig, "k", "hello", atMillis: 1_000_000)
        let db = rig.store.database
        // given: tags created out of order, mixed case (an upper-case Z must sort last), different colours, and a note
        _ = await db.createTagAndApply(name: "work", color: .blue, to: [id])
        _ = await db.createTagAndApply(name: "Archive", color: .purple, to: [id])
        _ = await db.createTagAndApply(name: "home", color: .green, to: [id])
        _ = await db.createTagAndApply(name: "Zeta", color: .red, to: [id])
        _ = await db.setNote("hero shot", for: id)
        // when
        let loaded = try await content(rig, id)
        // then
        #expect(loaded.tags == [ItemTag(name: "Archive", color: .purple), ItemTag(name: "home", color: .green), ItemTag(name: "work", color: .blue), ItemTag(name: "Zeta", color: .red)])
        #expect(loaded.note == "hero shot")
    }

    // Red if the tag join is not filtered by item (tags leak across items) or an untagged item gets a default.
    @Test("OC-3105 W413-S3 an untagged item has no tags and no note; a tagged neighbour's tags do not leak")
    func w413_isolation() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp() }
        let tagged = try await ingest(rig, "a", "alpha", atMillis: 1_000_000)
        let bare = try await ingest(rig, "b", "beta", atMillis: 2_000_000)
        let db = rig.store.database
        _ = await db.createTagAndApply(name: "work", color: .blue, to: [tagged])
        _ = await db.setNote("only on alpha", for: tagged)
        let bareContent = try await content(rig, bare)
        let taggedContent = try await content(rig, tagged)
        #expect(bareContent.tags.isEmpty)
        #expect(bareContent.note == nil)
        #expect(bareContent.plainText == "beta")
        #expect(taggedContent.tags.map(\.name) == ["work"])
        #expect(taggedContent.plainText == "alpha")
    }

    // Red if content is cached or read from an in-memory copy: after a recolour, rename, note clear and tag delete a fresh
    // read reflects the stored state (B4).
    @Test("OC-3105 W413-S4 edits show on a fresh read: recolour, rename, clear note, delete tag")
    func w413_editsRoundTrip() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp() }
        let id = try await ingest(rig, "k", "hello", atMillis: 1_000_000)
        let db = rig.store.database
        let work = try await db.createTagAndApply(name: "work", color: .blue, to: [id]).get()
        let home = try await db.createTagAndApply(name: "home", color: .green, to: [id]).get()
        _ = await db.setNote("n1", for: id)
        _ = await db.recolorTag(id: work, to: .red)
        _ = await db.renameTag(id: home, to: "zzz")
        let afterEdit = try await content(rig, id)
        #expect(afterEdit.tags == [ItemTag(name: "work", color: .red), ItemTag(name: "zzz", color: .green)])
        _ = await db.setNote(nil, for: id)
        _ = await db.deleteTag(id: work)
        let afterClear = try await content(rig, id)
        #expect(afterClear.note == nil)
        #expect(afterClear.tags == [ItemTag(name: "zzz", color: .green)])
    }

    // Red if a missing item no longer reports LIB-IO-001 after the query widened.
    @Test("W413-S5 content of an unknown id is still LIB-IO-001")
    func w413_missing() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp() }
        let result = await rig.store.database.content(of: UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!)
        guard case .failure(let error) = result else { Issue.record("expected a failure"); return }
        #expect(error.code.rawValue == "LIB-IO-001")
    }

    // The init defaults are what every non-DB caller relies on. Red if a default moves (copyCount 1, no note, no tags).
    @Test("W413-S6 ItemContent defaults: copy count 1, no first-copied, no note, no tags")
    func w413_defaults() {
        let item = ItemContent(kind: .text, plainText: "x", representations: [], members: [])
        #expect(item.copyCount == 1)
        #expect(item.firstCopiedAt == nil)
        #expect(item.note == nil)
        #expect(item.tags.isEmpty)
    }

    // Red if the rich-type drop list or the shared constants drift from the system identifiers (one home, FR-007-06).
    @Test("W413-S7 PasteboardUTI rtf/html are the system identifiers and the ingest rich list is exactly them")
    func w413_utiConstants() {
        #expect(PasteboardUTI.rtf == "public.rtf")
        #expect(PasteboardUTI.html == "public.html")
        #expect(PasteboardUTI.plainText == "public.utf8-plain-text")
        #expect(IngestLimits.richTypeIdentifiers == ["public.rtf", "public.html"])
    }
}
