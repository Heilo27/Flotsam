import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-511, FRD-002 FR-002-08: the persisted screenshot watermark never decreases, whatever order the writes land in.
@Suite struct ScreenshotWatermarkMonotoneTests {
    private func at(_ millis: Int64) -> Date { Date(epochMillis: millis) }

    @Test("FR-002-08 given writes T3, T1, T2 landing in that order, when read, then the watermark is T3 after every write")
    func outOfOrderWritesNeverLowerTheWatermark() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let database = rig.store.database
        let (t1, t2, t3) = (at(1_800_000_001_000), at(1_800_000_002_000), at(1_800_000_003_000))

        try await database.setScreenshotsLastScanAt(t3).get()
        try await database.setScreenshotsLastScanAt(t1).get()
        #expect(try await database.screenshotsLastScanAt().get() == t3)
        try await database.setScreenshotsLastScanAt(t2).get()
        #expect(try await database.screenshotsLastScanAt().get() == t3)
        try await database.setScreenshotsLastScanAt(t3).get()
        #expect(try await database.screenshotsLastScanAt().get() == t3)
    }

    @Test("FR-002-08 given 24 concurrent writes of shuffled times, when all finish, then the watermark is the latest of them")
    func concurrentWritesEndAtTheMaximum() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let database = rig.store.database
        let base: Int64 = 1_800_000_000_000
        let offsets = (0..<24).map { Int64(($0 * 7) % 24) * 1_000 }  // a permutation of 0...23 s, not sorted
        #expect(offsets != offsets.sorted())

        await withTaskGroup(of: Void.self) { group in
            for offset in offsets {
                group.addTask { _ = await database.setScreenshotsLastScanAt(Date(epochMillis: base + offset)) }
            }
        }

        #expect(try await database.screenshotsLastScanAt().get() == at(base + 23_000))
    }

    @Test("FR-002-08 the larger time wins by number, not by text: 10000 ms is later than 9999 ms")
    func comparisonIsNumericNotLexicographic() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let database = rig.store.database

        try await database.setScreenshotsLastScanAt(at(9_999)).get()
        try await database.setScreenshotsLastScanAt(at(10_000)).get()
        #expect(try await database.screenshotsLastScanAt().get() == at(10_000))
        try await database.setScreenshotsLastScanAt(at(9_999)).get()
        #expect(try await database.screenshotsLastScanAt().get() == at(10_000))
    }

    @Test("FR-002-08 the other meta writers keep overwriting: the same key written lower through setInt64 goes down")
    func plainOverwriteIsUnchangedForOtherCallers() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let pool = rig.store.database.pool
        try await pool.write { db in
            try MetaStore.setInt64(db, MetaKey.retentionLastSweepAt, 2_000)
            try MetaStore.setInt64(db, MetaKey.retentionLastSweepAt, 1_000)
        }
        let stored = try await pool.read { db in try MetaStore.int64(db, MetaKey.retentionLastSweepAt) }
        #expect(stored == 1_000)
    }
}
