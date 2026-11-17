import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-002 support in Storage: the screenshot watermark (FR-002-08) and the backfill exception to the bump rule
// (FR-002-12, FRD-001 FR-001-15).
@Suite struct ScreenshotStorageTests {
    @Test("FR-002-08 a fresh library has no watermark; a set watermark reads back to the millisecond")
    func watermarkRoundTrip() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        #expect(try await rig.store.database.screenshotsLastScanAt().get() == nil)

        let at = Date(timeIntervalSince1970: 1_800_000_000.123)
        try await rig.store.database.setScreenshotsLastScanAt(at).get()
        #expect(try await rig.store.database.screenshotsLastScanAt().get() == at)

        let later = Date(timeIntervalSince1970: 1_800_000_060)
        try await rig.store.database.setScreenshotsLastScanAt(later).get()
        #expect(try await rig.store.database.screenshotsLastScanAt().get() == later)
    }

    @Test("FR-002-12 a backfill match leaves the existing item fully untouched and reports unchanged")
    func backfillMatchIsUntouched() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let png = TestImage.make(width: 64, height: 48, format: .png)
        let id = try await rig.create(rig.image("image:abc", png, origin: .screenshotFile, at: 1_000))
        let before = try rig.row(id)

        var backfill = rig.image("image:abc", png, kind: .screenshot, origin: .screenshotFile, at: 9_000)
        backfill = IngestCandidate(
            kind: backfill.kind, contentKey: backfill.contentKey, representations: backfill.representations,
            origin: backfill.origin, occurredAt: backfill.occurredAt, countsAsCopy: false)
        let result = try await rig.ingest.ingest(backfill).get()

        #expect(result.outcome == .unchanged(id))
        let after = try rig.row(id)
        #expect(after.lastCopiedAt == before.lastCopiedAt)
        #expect(after.copyCount == before.copyCount)
        #expect(after.kind == before.kind)
        #expect(try rig.itemCount() == 1)
    }

    @Test("FR-001-15 a live screenshot match still bumps (countsAsCopy defaults to true)")
    func liveMatchStillBumps() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let png = TestImage.make(width: 64, height: 48, format: .png)
        let id = try await rig.create(rig.image("image:abc", png, at: 1_000))
        let result = try await rig.ingest.ingest(
            rig.image("image:abc", png, kind: .screenshot, origin: .screenshotFile, at: 9_000)).get()
        #expect(result.outcome == .bumped(id))
        #expect(try rig.row(id).copyCount == 2)
        #expect(try rig.row(id).lastCopiedAt == 9_000)
    }
}
