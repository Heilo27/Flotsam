import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T contract tests, slice S3 (Storage half): OC-7115 (reconcile of 20,000 orphan blobs never holds the main
// actor) and OC-7116 (migrate is logged before the post-migration integrity check). Expected values are literals.
// The "Library opens within its FRD-003 target" and `log show` halves need the running app; see
// FRD007ContractTestsGaps.swift.

/// Main-actor heartbeat: ticks every 5 ms and remembers the longest time the main actor was unavailable.
@MainActor
private final class MainActorHeartbeat {
    private(set) var ticks = 0
    private(set) var longestStallMs = 0.0
    private var task: Task<Void, Never>?

    func start() {
        task = Task { @MainActor in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = clock.now
                let gap = last.duration(to: now)
                let ms = Double(gap.components.seconds) * 1000 + Double(gap.components.attoseconds) / 1e15
                longestStallMs = max(longestStallMs, ms - 5)
                ticks += 1
                last = now
            }
        }
    }

    func stop() { task?.cancel() }
}

@Suite("FRD-007 contract: reliability (Storage)", .serialized, .timeLimit(.minutes(5)))
struct FRD007ContractReliabilityTests {
    private func dbLines(_ logs: RecordingLogSink) -> [String] {
        logs.records.filter { $0.headline.hasPrefix("database.") }.map(\.publicText)
    }

    /// A healthy database file at user_version 0 with one row in a legacy table, as an older build would leave it.
    private func makeV0(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: root.appendingPathComponent("flotsam.sqlite").path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE legacy (x TEXT)")
            try db.execute(sql: "INSERT INTO legacy VALUES ('keep-me')")
        }
    }

    /// OC-7116. Given a v0 fixture database, when Flotsam opens it, then the storage log reads: the pre-open integrity
    /// check, the migrate entry, the post-migration integrity check, then open. The post-migration check is the one
    /// FR-007-13 says is logged after the migrate entry; the pre-open check precedes any migration by design (AC-007-15).
    /// Red if the post-migration check is logged before the migrate entry (or the migrate entry is dropped).
    @Test("OC-7116 a v0 database logs migrate before the post-migration integrity check")
    func oc7116_migrateEntryPrecedesPostMigrationIntegrityCheck() async throws {
        // given a v0 fixture
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-7116-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeV0(at: root)
        let logs = RecordingLogSink()

        // when it opens
        let database = try await FlotsamDatabase.openBaseline(folder: root, logSink: logs).get()

        // then the exact order, with the migrate entry between the two integrity checks
        #expect(dbLines(logs) == [
            "database.integrityCheck outcome=passed", "database.migrate outcome=migrated",
            "database.integrityCheck outcome=passed", "database.open outcome=opened",
        ])
        // and the migration really ran: version 1, the legacy row kept, a v0 copy taken before it
        let diagnostics = try await database.pragmaFacts()
        #expect(diagnostics.userVersion == 1)
        let legacy = try await database.pool.read { try String.fetchAll($0, sql: "SELECT x FROM legacy") }
        #expect(legacy == ["keep-me"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("pre-migration/flotsam-v0.sqlite").path))
    }

    /// OC-7116 (negative). Given the same folder opened a second time, when nothing needs migrating, then no migrate
    /// entry is logged: the entry in the first test is caused by the migration, not by every open.
    /// Red if the migrate entry is logged on every open.
    @Test("OC-7116 reopening an already migrated database logs no migrate entry")
    func oc7116_reopenLogsNoMigrate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-7116b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeV0(at: root)
        _ = try await FlotsamDatabase.openBaseline(folder: root, logSink: RecordingLogSink()).get()
        let logs = RecordingLogSink()

        _ = try await FlotsamDatabase.openBaseline(folder: root, logSink: logs).get()

        #expect(dbLines(logs) == [
            "database.integrityCheck outcome=passed", "database.integrityCheck outcome=passed", "database.open outcome=opened",
        ])
    }

    /// OC-7115 (storage half). Given a data folder with 20,000 orphan blobs older than 10 minutes, one orphan younger
    /// than that, and one referenced blob, when reconcile runs while the main actor is kept busy by a 5 ms heartbeat,
    /// then all 20,000 old orphans are gone, the young orphan and the referenced blob survive, and the main actor was
    /// never unavailable for more than 250 ms.
    /// Red if reconcile stops removing orphans past the grace, removes the young or referenced blob, or runs on the
    /// main actor (the stall then exceeds 250 ms).
    @MainActor
    @Test("OC-7115 reconcile of 20,000 orphan blobs removes them all and never stalls the main actor over 250 ms")
    func oc7115_manyOrphansReconcileOffMainActor() async throws {
        // given 20,000 old orphans, 1 young orphan, 1 referenced blob (item 1)
        let s = try await Store.make(migrations: Migrations.baseline)
        defer { s.cleanUp() }
        var kept = Spec(n: 1, kind: .image, ageMs: 60_000)
        kept.blobs = 1
        kept.repBytes = 10
        try await s.insert(kept)
        let keptBlob = s.blobURL(1, 1)
        let orphanCount = 20_000
        for n in 0..<orphanCount { try s.plantOrphanBlob(1000 + n, ageMs: 11 * 60_000) }
        let young = try s.plantOrphanBlob(900_000, ageMs: 2 * 60_000)
        let listedBefore = s.names(in: s.blobsDir.appendingPathComponent("00")).count
        #expect(listedBefore == orphanCount + 2, "precondition: every planted file is on disk")

        // when reconcile runs with the main actor heartbeat going
        // The stall is load-normalized (TASK-481): a main thread the scheduler did not run for 300 ms at load average 250 is
        // not a main actor held by reconcile. Reconcile on the main actor holds it for the whole run, and a run that
        // holds the thread keeps the CPU it is given, so the share stays near 1 and the stall still reads in full.
        let heartbeat = MainActorHeartbeat()
        let probe = CPUShareProbe()
        defer { _ = probe.stop() }
        heartbeat.start()
        let outcome = try await s.database.reconcile().get()
        heartbeat.stop()
        let share = probe.stop()
        let stallMs = heartbeat.longestStallMs * max(share, 0.02)

        // then all old orphans removed, the young orphan and the referenced blob stay
        #expect(outcome.orphanBlobsRemoved == orphanCount)
        #expect(s.names(in: s.blobsDir.appendingPathComponent("00")).count == 2)
        #expect(s.exists(keptBlob))
        #expect(s.exists(young))
        #expect(try s.presentIds() == [1])
        // and the main actor kept ticking and was never held for more than 250 ms
        #expect(heartbeat.ticks >= 5, "the heartbeat must have run for the check to mean anything: \(heartbeat.ticks)")
        #expect(stallMs < 250, "main actor stalled \(heartbeat.longestStallMs) ms (CPU share \(share), load-normalized \(stallMs) ms) during reconcile")
    }

    /// OC-7115 (boundary). Given exactly one old orphan and nothing else, reconcile removes exactly that one and the
    /// outcome says so (0, 1 boundary beside the 20,000 case).
    /// Red if the count reported differs from files removed.
    @Test("OC-7115 a single old orphan is removed and counted once; a folder with none removes nothing")
    func oc7115_zeroAndOneOrphan() async throws {
        let s = try await Store.make(migrations: Migrations.baseline)
        defer { s.cleanUp() }
        let none = try await s.database.reconcile().get()
        #expect(none.orphanBlobsRemoved == 0)
        let orphan = try s.plantOrphanBlob(5, ageMs: 11 * 60_000)

        let one = try await s.database.reconcile().get()

        #expect(one.orphanBlobsRemoved == 1)
        #expect(!s.exists(orphan))
    }
}
