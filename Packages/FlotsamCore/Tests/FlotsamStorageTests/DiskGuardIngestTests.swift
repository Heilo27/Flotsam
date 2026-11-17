import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T batch 2, the disk guard (FR-007-14) driven through the real IngestActor with a file system whose free
// space the test sets. Thresholds are literals: images stop below 500 MiB free, everything stops below 50 MiB.
// "Below" is strict, so exactly the threshold still saves and one byte under does not.
//
// Layer note: Storage raises STO-IO-001 / STO-LIM-002. Capture wraps the write failure as CAP-IO-001 above this
// layer, so that wrapping is not asserted here.

@Suite struct DiskGuardIngestTests {
    private let png = TestImage.make(width: 16, height: 16, format: .png)
    private let mebi: Int64 = 1_048_576

    private func code(_ result: FlotsamResult<IngestResult>) -> ErrorCode? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    private func isCreated(_ result: FlotsamResult<IngestResult>) -> Bool {
        if case .success(let value) = result, case .created = value.outcome { return true }
        return false
    }

    /// A one-file drop onto the Shelf: the same payload as a file copy, a different origin.
    private func shelfDrop(_ rig: Rig, _ key: String) -> IngestCandidate {
        IngestCandidate(
            kind: .bundle, contentKey: key,
            members: [IngestMember(path: "/tmp/flotsam-8t/dropped.txt", bookmark: nil, isDirectory: false)],
            origin: .shelfDrop, occurredAt: Date(timeIntervalSince1970: Double(rig.store.clock.millis) / 1000))
    }

    /// OC-7117. 400 MiB free: the image is skipped with STO-LIM-002 and nothing is stored; text still saves.
    /// Red if the image tier is removed, applied to text too, or the skip leaves a row or blob behind.
    @Test("OC-7117 at 400 MiB free an image is skipped with STO-LIM-002 and text still saves")
    func oc7117_imageSkippedTextSaved() async throws {
        // given 400 MiB free and an empty library
        let rig = try await Rig.make(capacity: 400 * mebi)
        defer { rig.cleanUp() }

        // when an image is copied
        let image = try await rig.ingest.ingest(rig.image("k-img", png))

        // then it is refused as a warning, no item or blob exists, and the code carries the free space
        guard case .failure(let error) = image else { Issue.record("expected the image to be skipped"); return }
        #expect(error.code == .stoLim002)
        #expect(error.severity == .warning)
        #expect(error.context[.byteSize] == .bytes(419_430_400))
        #expect(try rig.itemCount() == 0)
        #expect(rig.blobFiles().isEmpty)

        // when text is copied next
        let text = try await rig.create(rig.text("k-text", "still saved"))

        // then it is saved: one item, with its text
        #expect(try rig.itemCount() == 1)
        #expect(try rig.row(text).plainText == "still saved")
    }

    /// OC-7119. 200 MiB free: a three-file copy creates one files item with its three members.
    @Test("OC-7119 at 200 MiB free a three-file copy still creates one files item")
    func oc7119_filesSavedAt200MiB() async throws {
        // given 200 MiB free
        let rig = try await Rig.make(capacity: 200 * mebi)
        defer { rig.cleanUp() }

        // when three files are copied
        let id = try await rig.create(rig.files("k-files", count: 3))

        // then exactly one item exists and it holds all three
        #expect(try rig.itemCount() == 1)
        #expect(try rig.memberCount(id) == 3)
    }

    /// OC-7120. 40 MiB free: text, a file copy and a Shelf drop are all refused with STO-IO-001, nothing is stored.
    /// Red if the hard tier is missing, skips an origin or kind, or leaves a partial row or blob.
    @Test("OC-7120 at 40 MiB free text, files and a Shelf drop all fail with STO-IO-001 and add nothing")
    func oc7120_hardFailEverything() async throws {
        // given 40 MiB free
        let rig = try await Rig.make(capacity: 40 * mebi)
        defer { rig.cleanUp() }

        // when text, a file copy and a Shelf drop are each attempted
        let text = try await rig.ingest.ingest(rig.text("k-text", "no room"))
        let files = try await rig.ingest.ingest(rig.files("k-files", count: 2))
        let drop = try await rig.ingest.ingest(shelfDrop(rig, "k-drop"))

        // then each fails with STO-IO-001 at error severity, and the library is unchanged
        for result in [text, files, drop] {
            guard case .failure(let error) = result else { Issue.record("expected a failure"); return }
            #expect(error.code == .stoIo001)
            #expect(error.severity == .error)
            #expect(error.context[.byteSize] == .bytes(41_943_040))
        }
        #expect(try rig.itemCount() == 0)
        #expect(try rig.store.count("bundleMember") == 0)
        #expect(try rig.store.count("representation") == 0)
        #expect(rig.blobFiles().isEmpty)

        // when space comes back, the same three go through: the refusal was not sticky
        rig.fileSystem.setCapacity(10 * 1024 * mebi)
        _ = try await rig.create(rig.text("k-text", "no room"))
        _ = try await rig.create(rig.files("k-files", count: 2))
        _ = try await rig.create(shelfDrop(rig, "k-drop"))
        #expect(try rig.itemCount() == 3)
    }

    /// FR-007-14 boundary, image tier: exactly 500 MiB free saves, one byte less skips, one byte more saves.
    /// Red if the comparison becomes `<=` (500 MiB would skip) or the threshold moves.
    @Test("FR-007-14 image tier boundary at 500 MiB free is strict")
    func imageTierBoundary() async throws {
        let rig = try await Rig.make(capacity: 500 * mebi)
        defer { rig.cleanUp() }

        // exactly at the threshold the image is saved
        let exact = try await rig.ingest.ingest(rig.image("k-a", png))
        #expect(isCreated(exact))
        #expect(try rig.itemCount() == 1)

        // one byte under it is skipped and the count does not move
        rig.fileSystem.setCapacity(500 * mebi - 1)
        let under = try await rig.ingest.ingest(rig.image("k-b", png))
        #expect(code(under) == .stoLim002)
        #expect(try rig.itemCount() == 1)

        // one byte over it is saved again
        rig.fileSystem.setCapacity(500 * mebi + 1)
        let over = try await rig.ingest.ingest(rig.image("k-c", png))
        #expect(isCreated(over))
        #expect(try rig.itemCount() == 2)
    }

    /// FR-007-14 boundary, hard tier: exactly 50 MiB free saves text and files, one byte less fails both with
    /// STO-IO-001, and an image just under 50 MiB gets STO-IO-001 rather than the milder STO-LIM-002.
    @Test("FR-007-14 hard tier boundary at 50 MiB free is strict and outranks the image skip")
    func hardTierBoundary() async throws {
        let rig = try await Rig.make(capacity: 50 * mebi)
        defer { rig.cleanUp() }

        // exactly at the threshold text and files are saved
        #expect(isCreated(try await rig.ingest.ingest(rig.text("k-t1", "at the line"))))
        #expect(isCreated(try await rig.ingest.ingest(rig.files("k-f1", count: 1))))
        #expect(try rig.itemCount() == 2)

        // one byte under it all three kinds fail with STO-IO-001 and the count does not move
        rig.fileSystem.setCapacity(50 * mebi - 1)
        #expect(code(try await rig.ingest.ingest(rig.text("k-t2", "under"))) == .stoIo001)
        #expect(code(try await rig.ingest.ingest(rig.files("k-f2", count: 1))) == .stoIo001)
        #expect(code(try await rig.ingest.ingest(rig.image("k-i2", png))) == .stoIo001)
        #expect(try rig.itemCount() == 2)

        // one byte over it text is saved again
        rig.fileSystem.setCapacity(50 * mebi + 1)
        #expect(isCreated(try await rig.ingest.ingest(rig.text("k-t3", "back"))))
        #expect(try rig.itemCount() == 3)
    }

    /// FR-007-14: the image tier does not touch text one byte under 500 MiB, and a volume that cannot report free
    /// space is not guarded at all.
    @Test("FR-007-14 text is unaffected under 500 MiB, and unknown free space disables the guard")
    func textTierAndUnknownCapacity() async throws {
        // given one byte under the image threshold
        let rig = try await Rig.make(capacity: 500 * mebi - 1)
        defer { rig.cleanUp() }

        // then text and files save (only images are held back at this tier)
        #expect(isCreated(try await rig.ingest.ingest(rig.text("k-t", "fine"))))
        #expect(isCreated(try await rig.ingest.ingest(rig.files("k-f", count: 1))))
        #expect(try rig.itemCount() == 2)

        // when the volume cannot report free space, even an image saves (nothing to guard on)
        rig.fileSystem.setCapacity(nil)
        #expect(isCreated(try await rig.ingest.ingest(rig.image("k-i", png))))
        #expect(try rig.itemCount() == 3)
    }
}
