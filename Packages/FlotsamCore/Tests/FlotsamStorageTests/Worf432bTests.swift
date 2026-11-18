import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-432 blind QA (FR-000-11 callsites in Storage): retention.swept and database.* lines. Expected values are
// literals. Each test names the production change that turns it red. Selection (which items go) is asserted by
// identity through a second connection so the evictedBytes / deleteItemsWhileEligible plumbing cannot change it.

@Suite struct Worf432bTests {
    private func imageSpecs(_ range: ClosedRange<Int>) -> [Spec] {
        range.map { n in
            var spec = Spec(n: n, kind: .image, ageMs: Int64(range.upperBound - n + 1) * dayMs)  // n = 1 oldest
            spec.blobs = 1
            spec.repBytes = 100 * mib
            return spec
        }
    }

    private func sweepLines(_ s: Store) -> [LogRecord] { s.logs.records.filter { $0.headline == "retention.swept" } }

    /// OC-432-01. Given two aged items (1000 B and 2 x 500 B), one aged pinned item (7777 B) and six 100 MiB images
    /// over a 500 MiB budget, when a sweep runs, then exactly one retention.swept line says rows=4 and 209717200 B,
    /// and the survivors are the pinned item and the four newest images. Red if the byte total drops either pass,
    /// the pinned item is counted, rows ignores the budget pass, or the selection changes.
    @Test func oc43201_sweepLogsRowsAndBytesFromBothPasses() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        var a = Spec(n: 101, ageMs: 31 * dayMs); a.blobs = 1; a.repBytes = 1000
        var b = Spec(n: 102, ageMs: 31 * dayMs); b.blobs = 2; b.repBytes = 500
        var pinned = Spec(n: 103, ageMs: 31 * dayMs, pinned: true); pinned.blobs = 1; pinned.repBytes = 7777
        try await s.insert([a, b, pinned] + imageSpecs(1...6))

        let outcome = try await s.database.runRetentionSweep(preset: .d30, budget: .mib500).get()

        #expect(outcome.retentionDeleted == 2)
        #expect(outcome.budget.evictedCount == 2)
        #expect(try s.presentIds() == [103, 3, 4, 5, 6])
        let lines = sweepLines(s)
        #expect(lines.count == 1)
        #expect(lines.first?.publicContext == "byteSize=209717200B rows=4")
        #expect(lines.first?.level == .info)
        #expect(lines.first?.category == .storage)
    }

    /// OC-432-02. Given an item with no blob (a text row) aged out, when swept, then rows=1 and 0 B (LEFT JOIN null
    /// byteSize counts as 0, not a crash and not a dropped row). Red if the null is coalesced wrongly or the row is lost.
    @Test func oc43202_itemWithoutRepresentationCountsRowZeroBytes() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: 31 * dayMs), Spec(n: 2, ageMs: 1 * dayMs)])

        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        #expect(try s.presentIds() == [2])
        #expect(sweepLines(s).map(\.publicContext) == ["byteSize=0B rows=1"])
    }

    /// OC-432-03 (empty/zero boundary). Given nothing eligible, when swept, then one line rows=0 / 0 B (FRD: a sweep
    /// that removes nothing logs 0 and 0). Red if the callsite is skipped when nothing was removed.
    @Test func oc43203_emptySweepStillLogsZeroAndZero() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: 1 * dayMs)])

        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .mib500).get()

        #expect(try s.presentIds() == [1])
        #expect(sweepLines(s).map(\.publicContext) == ["byteSize=0B rows=0"])
    }

    /// OC-432-04. Given Forever retention (no time pass) and an over-budget image set, when swept, then only the budget
    /// pass counts: rows=2, 209715200 B. Red if the time pass total is double counted or the budget bytes are lost.
    @Test func oc43204_foreverPresetCountsOnlyTheBudgetPass() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(imageSpecs(1...6))

        _ = try await s.database.runRetentionSweep(preset: .forever, budget: .mib500).get()

        #expect(try s.presentIds() == [3, 4, 5, 6])
        #expect(sweepLines(s).map(\.publicContext) == ["byteSize=209715200B rows=2"])
    }

    /// OC-432-05 (privacy). Given items whose text and trigger are distinctive, when swept and opened, then no log
    /// line anywhere (public or private) contains that text, the trigger, or the data-folder path.
    @Test func oc43205_noClipContentOrPathInAnyLogLine() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        var secret = Spec(n: 1, ageMs: 31 * dayMs, text: "SECRETCLIPzqx-9f3")
        secret.blobs = 1; secret.repBytes = 10
        try await s.insert([secret, Spec(n: 2, ageMs: 31 * dayMs, trigger: ";zqxtrig")])

        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .mib500).get()

        let all = s.logs.records.map { "\($0.publicText) \($0.privateText)" }.joined(separator: "\n")
        #expect(!all.contains("SECRETCLIPzqx"))
        #expect(!all.contains(";zqxtrig"))
        #expect(!all.contains(s.root.lastPathComponent))
        #expect(!sweepLines(s).isEmpty)
    }

    /// OC-432-06. The deletion helpers' return contract is unchanged: `delete(ids:)` still returns exactly the removed
    /// ids (missing ids left out) and removes rows+blobs. Red if the `.map(\.id)` returned all requested ids or none.
    @Test func oc43206_deleteStillReturnsOnlyRemovedIds() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        var a = Spec(n: 1); a.blobs = 1; a.repBytes = 10
        try await s.insert([a, Spec(n: 2)])

        let removed = try await s.database.delete(ids: [Store.id(1), Store.id(999)]).get()

        #expect(removed == [Store.id(1)])
        #expect(try s.presentIds() == [2])
        #expect(!s.exists(s.blobURL(1, 1)))
    }

    // MARK: database.*

    private func dbLines(_ logs: RecordingLogSink) -> [String] {
        logs.records.filter { $0.headline.hasPrefix("database.") }.map(\.publicText)
    }

    /// OC-432-07. Given a fresh folder, when opened, then the lines are, in order: migrate migrated, integrityCheck
    /// passed, open opened. Red if any of the three callsites is dropped or reordered.
    @Test func oc43207_freshOpenLogsMigrateIntegrityThenOpen() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }

        #expect(dbLines(s.logs) == [
            "database.migrate outcome=migrated", "database.integrityCheck outcome=passed", "database.open outcome=opened",
        ])
        #expect(s.logs.records.allSatisfy { $0.level == .info })
    }

    /// OC-432-08. Given an existing healthy file at the newest version, when reopened, then the probe integrity check
    /// and the post-open check both log `passed`, no migrate line is logged, and open logs `opened`.
    @Test func oc43208_reopenLogsTwoIntegrityChecksAndNoMigrate() async throws {
        let first = try await Store.make()
        defer { first.cleanUp() }
        let logs = RecordingLogSink()

        let db = try await FlotsamDatabase.open(folder: first.root, clock: first.clock, logSink: logs).get()
        _ = db

        #expect(dbLines(logs) == [
            "database.integrityCheck outcome=passed", "database.integrityCheck outcome=passed", "database.open outcome=opened",
        ])
    }

    /// OC-432-09. Given a file that is not a database, when opened, then an integrityCheck `failed` line precedes the
    /// quarantine, and the recreated database logs migrate/passed/opened. Red if the damaged branch logs nothing or
    /// logs `passed`.
    @Test func oc43209_damagedFileLogsIntegrityFailedThenRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-432b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 8192).write(to: root.appendingPathComponent("flotsam.sqlite"))
        let logs = RecordingLogSink()

        let db = try await FlotsamDatabase.open(folder: root, logSink: logs).get()
        _ = db

        let lines = dbLines(logs)
        #expect(lines.first == "database.integrityCheck outcome=failed")
        #expect(lines.last == "database.open outcome=opened")
        #expect(lines.filter { $0 == "database.open outcome=failed" }.isEmpty)
    }

    /// OC-432-10. Given a database written by a newer version, when opened, then open is refused and exactly one
    /// `database.open failed` line is logged and no `opened` line. Red if the failure return skips the callsite.
    @Test func oc43210_newerVersionRefusalLogsOpenFailed() async throws {
        let first = try await Store.make()
        defer { first.cleanUp() }
        let url = first.root.appendingPathComponent("flotsam.sqlite")
        try await first.database.pool.write { db in try db.execute(sql: "PRAGMA user_version = 9999") }
        let logs = RecordingLogSink()
        _ = first  // keep the first pool alive no longer than needed

        let result = await FlotsamDatabase.open(folder: first.root, logSink: logs)

        guard case .failure = result else { Issue.record("expected refusal for a newer database at \(url.lastPathComponent)"); return }
        let lines = dbLines(logs)
        #expect(lines.filter { $0 == "database.open outcome=failed" }.count == 1)
        #expect(!lines.contains("database.open outcome=opened"))
    }
}
