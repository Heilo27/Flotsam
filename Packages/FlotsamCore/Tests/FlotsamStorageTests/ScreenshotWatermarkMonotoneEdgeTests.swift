import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-511 QA (Worf), FRD-002 FR-002-08 / AC-002-16: edge cases of the monotone watermark write that the happy-path
// suite does not reach: a first insert, a damaged stored value, and the stored text staying a plain integer.
@Suite struct ScreenshotWatermarkMonotoneEdgeTests {
    private func rawStored(_ rig: Rig) async throws -> String? {
        try await rig.store.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'screenshots.lastScanAt'")
        }
    }

    @Test("OC-WORF511-01 AC-002-16 given no stored watermark, when the first write lands, then a row exists holding that exact time")
    func firstInsertCreatesTheRow() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let database = rig.store.database
        #expect(try await database.screenshotsLastScanAt().get() == nil)
        #expect(try await rawStored(rig) == nil)

        try await database.setScreenshotsLastScanAt(Date(epochMillis: 1_800_000_000_123)).get()

        #expect(try await rawStored(rig) == "1800000000123")
        #expect(try await database.screenshotsLastScanAt().get() == Date(epochMillis: 1_800_000_000_123))
    }

    @Test("OC-WORF511-02 AC-002-16 given a damaged non-numeric stored value, when a real time is written, then it replaces the damage")
    func garbageStoredValueIsReplaced() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let database = rig.store.database
        try await database.pool.write { db in
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES('screenshots.lastScanAt', 'garbage')")
        }

        try await database.setScreenshotsLastScanAt(Date(epochMillis: 5_000)).get()

        #expect(try await rawStored(rig) == "5000")
        #expect(try await database.screenshotsLastScanAt().get() == Date(epochMillis: 5_000))
    }

    @Test("OC-WORF511-03 AC-002-16 given a stored time, when an older one is written, then the stored text is untouched and a plain integer")
    func staleWriteLeavesStoredTextByteIdentical() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let database = rig.store.database
        try await database.setScreenshotsLastScanAt(Date(epochMillis: 1_800_000_003_000)).get()

        try await database.setScreenshotsLastScanAt(Date(epochMillis: 1_800_000_001_000)).get()
        #expect(try await rawStored(rig) == "1800000003000")

        try await database.setScreenshotsLastScanAt(Date(epochMillis: 1_800_000_004_000)).get()
        #expect(try await rawStored(rig) == "1800000004000")
    }

    @Test("OC-WORF511-04 AC-002-16 given only one row for the key, when many writes land, then the meta table holds exactly one screenshots row")
    func upsertNeverDuplicatesTheRow() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let database = rig.store.database
        for ms in [3_000, 1_000, 2_000] as [Int64] { try await database.setScreenshotsLastScanAt(Date(epochMillis: ms)).get() }

        let count = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM meta WHERE key LIKE 'screenshots.%'")
        }
        #expect(count == 1)
    }
}
