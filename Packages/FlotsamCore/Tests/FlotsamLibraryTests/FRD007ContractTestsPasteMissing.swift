import FlotsamBase
import FlotsamStorage
import Foundation
import Testing

// FRD-007 8T contract test, slice S3b (Library half): OC-7127. A paste whose stored data is gone raises LIB-IO-001,
// which deletes the item through the one deletion path (FR-007-15); the HUD shows the catalogue text. Real
// PasteService, LibraryViewModel and FlotsamDatabase over a scratch folder (PasteRig, RealLibrary). The HUD text is
// what the real ErrorReporter hands its presenter for the error the Library reported, origin userInitiated.
// Counts and identity are read through the database; blob files are checked on disk.
//
// [Contract note] The contract's Given says "a files item whose referenced file has been moved away so pasting it
// raises LIB-IO-001". The FRDs split this in two: FR-003-20 / FRD-000 make LIB-IO-001 "stored data missing" (the
// item's own blob files; the item is deleted), while a files item whose referenced files are gone is LIB-DAT-001
// (FR-003-08 path; the item is kept and shows Missing). Both halves are asserted separately below; neither is
// weakened. The Shelf half (Shelf paste of the same item) needs the Shelf and Library targets together: see
// FRD007ContractTestsGaps.swift.

@MainActor
private final class MissingPresenter: ErrorPresenter {
    private(set) var huds: [String] = []
    func showHUD(message: String) { huds.append(message) }
    func noticesChanged(_ notices: [Notice]) {}
    func presentFatal(_ error: FlotsamError) {}
}

private final class MissingSink: LogSink, @unchecked Sendable {
    func write(_ record: LogRecord) {}
}

private final class MissingClock: WallClock, @unchecked Sendable {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(for duration: Duration) async {}
}

@MainActor
@Suite("FRD-007 contract: paste of missing data (Library)", .serialized, .timeLimit(.minutes(2)))
struct FRD007ContractPasteMissingTests {
    private static let libIo001Text = "This item's data is missing, so it was removed."
    private static let libDat001Text = "The original file or folder has moved or been deleted."

    /// What the user reads: the real reporter's HUD for each error the Library reported.
    private func huds(for errors: [FlotsamError]) async -> [String] {
        let presenter = MissingPresenter()
        let reporter = ErrorReporter(presenter: presenter, clock: MissingClock(), sink: MissingSink())
        for error in errors { await reporter.report(error, origin: .userInitiated) }
        return presenter.huds
    }

    private func blobFiles(of id: UUID, in root: URL) -> [String] {
        let base = root.appendingPathComponent("blobs")
        let paths = FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String] ?? []
        return paths.filter { $0.contains(id.uuidString) }.sorted()
    }

    /// OC-7127 (deleting half). The item's blob files are gone: pasting it shows the LIB-IO-001 HUD, pastes nothing,
    /// and deletes exactly that item; the other two items and their blobs are untouched.
    /// Red if the missing-data paste leaves the item, deletes another item, pastes anyway, or shows another text.
    @Test("OC-7127 a paste of an item whose stored data is missing: LIB-IO-001 HUD, that item removed (-1), the others unchanged")
    func oc7127_missingStoredDataDeletesOnlyThatItem() async throws {
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        // given three items: D (rich, blobs removed from disk), S (rich, blobs intact), F (files, file present)
        let html = PasteboardRepresentation(uti: "public.html", data: Data("<i>x</i>".utf8))
        let doomed = try await rig.lib.add(.richText, key: "d", text: "MARK-DOOMED", secondsAgo: 5, representations: [html]).itemId
        let survivor = try await rig.lib.add(.richText, key: "s", text: "MARK-SURVIVOR", secondsAgo: 50, representations: [html]).itemId
        let realFile = rig.lib.root.appendingPathComponent("present.txt")
        try Data("x".utf8).write(to: realFile)
        let filesItem = try await rig.lib.add(
            .file, key: "f", secondsAgo: 90,
            members: [IngestMember(path: realFile.path, bookmark: nil, isDirectory: false)]).itemId
        let survivorBlobs = blobFiles(of: survivor, in: rig.lib.root)
        let doomedBlobs = blobFiles(of: doomed, in: rig.lib.root)
        try #require(!doomedBlobs.isEmpty, "the fixture stored no blob for D; the test would be vacuous")
        #expect(!survivorBlobs.isEmpty)
        for name in doomedBlobs { try FileManager.default.removeItem(at: rig.lib.root.appendingPathComponent("blobs/\(name)")) }
        await rig.reopen()
        #expect(try await rig.lib.allRows().count == 3)

        // when D is pasted with Return
        rig.model.select(id: doomed)
        await rig.press(.returnKey)

        // then the HUD shows the LIB-IO-001 text and nothing was pasted
        #expect(rig.reported.errors.map(\.code) == [.libIo001])
        #expect(await huds(for: rig.reported.errors) == [Self.libIo001Text])
        #expect(rig.pasteboard.written.isEmpty)
        #expect(rig.keys.posts == 0)
        // and D is gone (3 -> 2), S and F remain by identity, S's blobs are intact
        let remaining = try await rig.lib.allRows().map(\.id)
        #expect(remaining.count == 2)
        #expect(Set(remaining) == [survivor, filesItem])
        #expect(!remaining.contains(doomed))
        #expect(blobFiles(of: survivor, in: rig.lib.root) == survivorBlobs)
    }

    /// OC-7127 (kept half). A files item whose referenced file moved away is not the LIB-IO-001 path: the HUD shows
    /// the LIB-DAT-001 text and the item is NOT deleted (delta 0), no other item changes, nothing is pasted.
    /// Red if a moved referenced file deletes the item or any other item, or pastes an empty payload.
    @Test("OC-7127 a files item whose file moved away: LIB-DAT-001 HUD, nothing removed (delta 0), nothing pasted")
    func oc7127_movedReferencedFileKeepsTheItem() async throws {
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        // given a files item whose only member was moved away (no bookmark, so it cannot be found), plus a bystander
        let moved = rig.lib.root.appendingPathComponent("moved-away.txt")
        try Data("x".utf8).write(to: moved)
        let filesItem = try await rig.lib.add(
            .file, key: "f-moved", secondsAgo: 5,
            members: [IngestMember(path: moved.path, bookmark: nil, isDirectory: false)]).itemId
        let bystander = try await rig.lib.add(.text, key: "b", text: "MARK-BYSTANDER", secondsAgo: 50).itemId
        try FileManager.default.moveItem(at: moved, to: rig.lib.root.appendingPathComponent("elsewhere.txt"))
        await rig.reopen()
        #expect(Set(try await rig.lib.allRows().map(\.id)) == [filesItem, bystander])

        // when the files item is pasted with Return
        rig.model.select(id: filesItem)
        await rig.press(.returnKey)

        // then the LIB-DAT-001 HUD, no paste, and both items are still there
        #expect(rig.reported.errors.map(\.code) == [.libDat001])
        #expect(await huds(for: rig.reported.errors) == [Self.libDat001Text])
        #expect(rig.pasteboard.written.isEmpty)
        #expect(rig.keys.posts == 0)
        let rows = try await rig.lib.allRows()
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)) == [filesItem, bystander])
        #expect(rows.first { $0.id == bystander }?.primaryLine == "MARK-BYSTANDER")
    }
}
