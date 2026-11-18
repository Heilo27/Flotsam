import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-470, FRD-000 OC-0039 (FR-000-11), Storage half: "Scripted session with 5 items eligible for retention; Flotsam
// launches and the retention sweep runs". These run the real emission path (a real FlotsamDatabase in a temp folder, the
// real sweep) and read what reached the LogSink, so deleting a `FlotsamLog.log(...)` call from Storage turns them red.
// They replace the source-grep checks that only proved the call text existed. Expected values are literals.
// The permission-transition half is the real-path oc43221 in FlotsamBaseTests (Worf432bPermissionTests), where its owner lives.

@Suite struct Oc0039ScriptedSessionTests {
    /// OC-0039 (the whole scripted session). given a launch with 5 items eligible for retention, when the database opens
    /// and the sweep runs, then the sink holds, in order, database.migrate, database.integrityCheck, database.open,
    /// retention.swept, each exactly once. Red if any of the four `FlotsamLog.log` calls in Storage is deleted, doubled
    /// or moved out of launch order (the order matters: the sweep line must follow the open line).
    @Test("OC-0039 a launch then a sweep emits the four Storage entries once each, in order")
    func launchThenSweepEmitsFourEntriesInOrder() async throws {
        // given a launched store (the open has already logged) with five eligible items
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert((1...5).map { n in
            var spec = Spec(n: n, ageMs: 31 * dayMs)
            spec.blobs = 1
            spec.repBytes = 100
            return spec
        })
        // when the sweep runs
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        // then the FR-000-11 Storage entries are exactly these four, all info, all Storage category
        let lines = s.logs.records.filter { $0.headline.hasPrefix("database.") || $0.headline == "retention.swept" }
        #expect(lines.map(\.headline) == ["database.migrate", "database.integrityCheck", "database.open", "retention.swept"])
        #expect(lines.last?.publicText == "retention.swept byteSize=500B rows=5")
        #expect(lines.allSatisfy { $0.level == .info && $0.category == .storage })
    }

    /// OC-0039 (retention sweep entry with rows removed and a bytes figure). given 5 items past the 30-day preset
    /// (100 B each) plus one pinned old item and one fresh item, when the sweep runs, then exactly one retention.swept
    /// entry says rows=5 and 500 B, and the pinned and fresh items survive. Red if the `.retentionSwept` call is
    /// deleted, logged per batch instead of per sweep, counts the pinned item, or drops the bytes figure.
    @Test("OC-0039 the retention sweep logs one entry with rows removed = 5 and the bytes removed")
    func sweepLogsRowsAndBytes() async throws {
        // given a launched store holding five eligible items, one aged-but-pinned item and one fresh item
        let s = try await Store.make()
        defer { s.cleanUp() }
        var eligible: [Spec] = []
        for n in 1...5 {
            var spec = Spec(n: n, ageMs: 31 * dayMs)
            spec.blobs = 1
            spec.repBytes = 100
            eligible.append(spec)
        }
        var pinned = Spec(n: 6, ageMs: 31 * dayMs, pinned: true)
        pinned.blobs = 1
        pinned.repBytes = 9_999
        try await s.insert(eligible + [pinned, Spec(n: 7, ageMs: 1 * dayMs)])

        // when the retention sweep runs
        let outcome = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        // then the five went, the other two stayed, and the sink holds exactly one entry with the figures
        #expect(outcome.retentionDeleted == 5)
        #expect(try s.presentIds() == [6, 7])
        let swept = s.logs.records.filter { $0.headline == "retention.swept" }
        #expect(swept.map(\.publicText) == ["retention.swept byteSize=500B rows=5"])
        #expect(swept.first?.privateContext == "")
        #expect(swept.first?.level == .info)
    }
}
