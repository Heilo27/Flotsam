import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8V remediation B, the log halves of OC-7023, OC-7113, OC-7123 and OC-7076.
//
// Lines are read from the store's own `RecordingLogSink`, not from the process-wide unified log. FRD-000 (FR-000-10)
// logs the item id, the static message and the cause `.private`, which the unified log shows as `<private>`, so a
// probe on it can no longer see them. The sink keeps the public and the private text of every record, per store, so a
// line count is exact and no parallel suite can supply or hide a line. Each test that asserts "no leak" reads the
// public text on its own: that is exactly what a release build writes in the clear.

@Suite struct Unmapped007LogTests {
    // MARK: OC-7123 (log half)

    /// OC-7123 log half. Red if the stuck-blob line is dropped, carries another code, or loses the item id.
    @Test("OC-7123 a blob that cannot be removed after delete is logged STO-IO-003 with its own item id and nobody else's")
    func oc7123_stuckBlobIsLoggedWithItsItem() async throws {
        // given two items whose blobs exist, one of which cannot be removed (item numbers are unique to this test)
        let stuckItem = 7_123_501, cleanItem = 7_123_502
        var faulty = FaultyFileSystem()
        let stuckName = Store.id(stuckItem).uuidString + ".1"
        faulty.failRemove = { $0.lastPathComponent == stuckName }
        let s = try await Store.make(fileSystem: faulty)
        defer { s.cleanUp() }
        try await s.insert([
            Spec(n: stuckItem, ageMs: hourMs, blobs: 1, repBytes: 10), Spec(n: cleanItem, ageMs: 2 * hourMs, blobs: 1, repBytes: 10),
        ])

        // when both are deleted together
        let removed = try await s.database.delete(ids: [Store.id(stuckItem), Store.id(cleanItem)]).get()

        // then the delete succeeded for both and the stuck blob is the only file left behind
        #expect(Set(removed) == [Store.id(stuckItem), Store.id(cleanItem)])
        #expect(try s.presentIds() == [])
        #expect(s.exists(s.blobURL(stuckItem, 1)))
        #expect(!s.exists(s.blobURL(cleanItem, 1)))
        // and exactly one line says so, with the exact code, static text and the stuck item's id
        let stuckId = Store.id(stuckItem).uuidString
        let lines = s.logs.lines(containing: ["itemId=\(stuckId)"])
        #expect(lines.count == 1, "one line for the stuck item: saw \(lines)")
        #expect(lines.first.map { $0.contains("STO-IO-003") && $0.contains("Blob could not be removed after delete; left for reconcile") } == true,
                "wrong code or text: \(lines)")
        // and the item whose blob was removed has no line at all
        let cleanLines = s.logs.lines(containing: ["itemId=\(Store.id(cleanItem).uuidString)"])
        #expect(cleanLines.isEmpty, "a clean delete must not log: \(cleanLines)")
        // and nothing in the clear (what a release build writes) holds the item id, the blob's file name or any path
        let inTheClear = s.logs.publicLines().joined(separator: "\n")
        #expect(!inTheClear.contains(stuckId) && !inTheClear.contains(stuckName) && !inTheClear.contains(s.root.path))
        #expect(lines.allSatisfy { !$0.contains(stuckName) && !$0.contains(s.root.path) })
    }

    // MARK: OC-7023 (log half)

    /// OC-7023 log half. Orphan lines carry no context, so the test removes twelve orphans in one pass and asks for at
    /// least twelve lines with the exact code and text. Red if the line is dropped or recoded (twelve is more than the
    /// handful any single other test supplies at the same moment, and with the line gone no test supplies any).
    @Test("OC-7023 every orphan blob that reconcile removes is logged STO-IO-003")
    func oc7023_reconcileLogsEachOrphanRemoval() async throws {
        // given twelve orphan blobs older than the 10 minute grace, one referenced blob, and one young orphan
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(Spec(n: 1, kind: .image, blobs: 1, repBytes: 10))
        let orphans = try (0..<12).map { try s.plantOrphanBlob(7_023_100 + $0, ageMs: 11 * 60_000) }
        let young = try s.plantOrphanBlob(7_023_200, ageMs: 2 * 60_000)

        // when reconcile runs
        let outcome = try await s.database.reconcile().get()

        // then exactly the twelve old orphans are gone and the referenced blob and young orphan stay
        #expect(outcome.orphanBlobsRemoved == 12)
        #expect(orphans.allSatisfy { !s.exists($0) })
        #expect(s.exists(young))
        #expect(s.exists(s.blobURL(1, 1)))
        #expect(try s.presentIds() == [1])
        // and at least twelve log lines carry the code and static text
        let lines = s.logs.lines(containing: ["STO-IO-003", "Orphan blob removed by reconcile"])
        #expect(lines.count == 12, "orphan removals logged: saw \(lines.count)")
        // and no line leaks a path or file name
        #expect(lines.allSatisfy { !$0.contains(s.root.path) && !$0.contains(".blob") })
    }

    // MARK: OC-7113 (log half)

    /// OC-7113 log half. The scheduled pass, not a direct call, removes the orphans, and the removals are logged.
    @Test("OC-7113 the launch pass of the scheduler logs each orphan it removes as STO-IO-003")
    func oc7113_scheduledPassLogsOrphanRemovals() async throws {
        // given a gated store with twelve old orphans and one young orphan
        let (s, clock) = try await makeGatedStore()
        defer { s.cleanUp() }
        let orphans = try (0..<12).map { try s.plantOrphanBlob(7_113_100 + $0, ageMs: 11 * 60_000) }
        let young = try s.plantOrphanBlob(7_113_200, ageMs: 2 * 60_000)
        let scheduler = ReconcileScheduler(database: s.database)

        // when the scheduler starts and its 15 second wait ends
        await scheduler.start()
        #expect(await waitUntil { clock.sleeps.count == 1 })
        #expect(orphans.allSatisfy { s.exists($0) }, "nothing is repaired during the wait")
        clock.release()

        // then the old orphans are removed by the pass, the young one is not, and the removals are logged
        #expect(await waitUntil { orphans.allSatisfy { !s.exists($0) } })
        #expect(s.exists(young))
        let removalLine = ["STO-IO-003", "Orphan blob removed by reconcile"]
        #expect(await waitUntil { s.logs.lines(containing: removalLine).count >= 12 })
        let lines = s.logs.lines(containing: removalLine)
        #expect(lines.count == 12, "scheduled orphan removals logged: saw \(lines.count)")
        await scheduler.stop()
    }

    // MARK: OC-7076 (log half)

    /// OC-7076 log half. 1,237 is a count no other test in the suite deletes, so the line can only be this sweep's.
    @Test("OC-7076 a sweep that deletes 1,237 items logs STO-POL-001 with count=1237 and no item content")
    func oc7076_sweepLogsItsCount() async throws {
        // given 1,237 eligible items and 100 pinned ones older than the window
        let s = try await Store.make()
        defer { s.cleanUp() }
        var specs = (1...1_237).map { Spec(n: $0, ageMs: 31 * dayMs, text: "SECRET-7076-\($0)") }
        specs += (2_001...2_100).map { Spec(n: $0, ageMs: 31 * dayMs, pinned: true) }
        try await s.insert(specs)

        // when the sweep runs
        let outcome = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        // then 1,237 are gone, the pinned remain
        #expect(outcome.retentionDeleted == 1_237)
        #expect(try s.count("item") == 100)
        // and one line names the code, the static text and the count
        let lines = s.logs.lines(containing: ["STO-POL-001", "Retention sweep", "count=1237"])
        #expect(lines.count == 1, "one sweep line with the count: saw \(lines)")
        // and the line holds no item content
        #expect(lines.allSatisfy { !$0.contains("SECRET-7076") })

        // when a second sweep finds nothing to delete
        let second = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        // then it deletes 0, logs no second line for 1,237 and never logs a zero count
        #expect(second.retentionDeleted == 0)
        #expect(try s.count("item") == 100)
        let after = s.logs.lines(containing: ["STO-POL-001", "Retention sweep", "count=1237"])
        #expect(after.count == 1)
        #expect(s.logs.lines(containing: ["STO-POL-001", "Retention sweep", "count=0"]).isEmpty)
    }
}
