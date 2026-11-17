import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T gap suite for database faults (FR-007-14, FR-007-18). The faults are real SQLite faults, not mocks:
//   - disk full: `PRAGMA max_page_count` pinned to the current size, so the next write that needs a page gets
//     SQLITE_FULL (result code 13) from SQLite itself;
//   - unreadable history: the item table is renamed away, so every read statement fails to prepare.
// Both are lifted again afterwards, so a test also proves the store recovers. Expected values are literals.
//
// Layer note, OC-7121: Capture wraps the write failure as CAP-IO-001 above this layer (FlotsamCapture is an empty
// module today) and the log line needs a log sink the repo does not have. Storage's half is asserted here: the
// failure carries STO-DB-001 with the SQLite code, and nothing partial is left. The other two clauses are GAP.
// Layer note, OC-7146: "History unavailable" with a Retry button is UI (GAP-journey). Storage's half is the STO-DB-004
// failure on every read entry point and the correct answer once the fault is gone.

@Suite struct IngestFaultGapTests {
    private let sqliteFull = 13

    /// Pins the database to its present size: any write that needs a new page now fails with SQLITE_FULL.
    private func fillDisk(_ rig: Rig) async throws {
        try await rig.store.database.pool.write { db in
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count")!
            try db.execute(sql: "PRAGMA max_page_count = \(pages)")
        }
    }

    private func freeDisk(_ rig: Rig) async throws {
        try await rig.store.database.pool.write { db in try db.execute(sql: "PRAGMA max_page_count = 1073741823") }
    }

    private func failure(_ result: FlotsamResult<IngestResult>) -> FlotsamError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    private struct Counts: Equatable {
        let items: Int
        let representations: Int
        let members: Int
    }

    private func counts(_ rig: Rig) throws -> Counts {
        Counts(
            items: try rig.store.count("item"), representations: try rig.store.count("representation"),
            members: try rig.store.count("bundleMember"))
    }

    // MARK: OC-7121

    /// OC-7121. Given SQLITE_FULL on write, when a text is copied, then the copy fails with STO-DB-001 carrying the
    /// SQLite code, item count delta 0, representation and member counts unchanged, and the earlier item is intact.
    /// Red if the failure is swallowed or mapped to another code, or a partial row survives the failed transaction.
    @Test("OC-7121 a text copy on a full database fails STO-DB-001 and leaves no partial rows")
    func oc7121_textCopyOnFullDatabase() async throws {
        // given one stored item, then a database that cannot grow
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let survivor = try await rig.create(rig.text("k-survivor", "stays put"))
        let before = try counts(rig)
        #expect(before == Counts(items: 1, representations: 0, members: 0))
        try await fillDisk(rig)

        // when a text too large for any free page is copied
        let result = await rig.ingest.ingest(rig.text("k-big", String(repeating: "a", count: 1_000_000)))

        // then it fails with STO-DB-001 and SQLite's disk-full code, and nothing was added or altered
        let error = try #require(failure(result), "the copy must fail on a full database")
        #expect(error.code == .stoDb001)
        #expect(error.underlying?.code == sqliteFull)
        #expect(try counts(rig) == before)
        #expect(try rig.row(survivor).plainText == "stays put")
        // the failed copy did not leave its content key behind: the same text still counts as new
        let leftovers = try await rig.store.reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE contentKey = 'k-big'")! }
        #expect(leftovers == 0)
    }

    /// OC-7121, blobs. A rich text writes its RTF blob before the row; when the row then fails, the blob is removed.
    /// Red if the failure path stops removing the blobs it already wrote (an orphan file per failed copy).
    @Test("OC-7121 a failed rich-text copy leaves no orphan blob and no representation row")
    func oc7121_failedRichCopyLeavesNoBlob() async throws {
        // given one stored rich text (so a blob exists), then a full database
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let rtf = Data(#"{\rtf1\ansi big}"#.utf8)
        let survivor = try await rig.create(rig.rich("k-rich-1", plain: "first", rtf: rtf))
        let blobsBefore = rig.blobFiles()
        let before = try counts(rig)
        #expect(blobsBefore.count == 1)
        #expect(before == Counts(items: 1, representations: 1, members: 0))
        try await fillDisk(rig)

        // when a second rich text, with a large plain text, is copied
        let result = await rig.ingest.ingest(rig.rich("k-rich-2", plain: String(repeating: "b", count: 1_000_000), rtf: rtf))

        // then it fails STO-DB-001, the blob it wrote is gone, and the first item's blob and rows are untouched
        #expect(failure(result)?.code == .stoDb001)
        #expect(rig.blobFiles() == blobsBefore)
        #expect(try counts(rig) == before)
        #expect(try rig.reps(survivor).count == 1)
        #expect(rig.blobData(try rig.reps(survivor)[0]) == rtf)
    }

    /// OC-7121, bundle. A files copy whose members cannot all be stored leaves no item and no bundleMember rows.
    @Test("OC-7121 a failed files copy leaves no item and no member rows")
    func oc7121_failedBundleCopyLeavesNoMembers() async throws {
        // given one stored files item, then a full database
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let survivor = try await rig.create(rig.files("k-files-1", count: 2))
        let before = try counts(rig)
        #expect(before == Counts(items: 1, representations: 0, members: 2))
        try await fillDisk(rig)

        // when a files copy with very long paths needs new pages
        let longPath = "/tmp/flotsam-8t/" + String(repeating: "p", count: 400_000)
        let candidate = IngestCandidate(
            kind: .bundle, contentKey: "k-files-2",
            members: (0..<3).map { IngestMember(path: longPath + "\($0)", bookmark: nil, isDirectory: false) },
            origin: .pasteboard, occurredAt: Date(timeIntervalSince1970: Double(rig.store.clock.millis) / 1000))
        let result = await rig.ingest.ingest(candidate)

        // then STO-DB-001, with no item and no member rows added, and the survivor still has its two members
        #expect(failure(result)?.code == .stoDb001)
        #expect(try counts(rig) == before)
        #expect(try rig.memberCount(survivor) == 2)
    }

    /// OC-7121, recovery. Once space is available the same copy succeeds: a failed write does not poison the store.
    /// Red if the failure path leaves the actor or database in a state that refuses later writes.
    @Test("OC-7121 after the disk frees, the same copy is stored as a new item")
    func oc7121_recoversWhenSpaceReturns() async throws {
        // given a copy that failed on a full database
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        _ = try await rig.create(rig.text("k-one", "one"))
        try await fillDisk(rig)
        let big = rig.text("k-big", String(repeating: "c", count: 1_000_000))
        #expect(failure(await rig.ingest.ingest(big))?.code == .stoDb001)
        #expect(try rig.itemCount() == 1)

        // when space returns and the same copy is made again
        try await freeDisk(rig)
        let id = try await rig.create(big)

        // then it is created once and the earlier item is still there
        #expect(try rig.itemCount() == 2)
        #expect(try rig.row(id).plainText?.count == 1_000_000)
    }

    // MARK: OC-7146

    private func renameItemTable(_ rig: Rig, from: String, to: String) async throws {
        try await rig.store.database.pool.write { db in try db.execute(sql: "ALTER TABLE \(from) RENAME TO \(to)") }
    }

    /// OC-7146. Given reads forced to fail, when the user searches, then every query entry point fails STO-DB-004; after
    /// the fault is removed and the user retries, the list returns with the correct count. The screen is GAP-journey.
    /// Red if a read failure is mapped to another code, shown as an empty list (success with 0), or sticks after the retry.
    @Test("OC-7146 a failed read is STO-DB-004 on every entry point and a retry returns the right list")
    func oc7146_readFailureThenRetry() async throws {
        // given a library of three items and a database whose item table cannot be read
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let ids = Set([
            try await rig.create(rig.text("k1", "alpha one")), try await rig.create(rig.text("k2", "alpha two")),
            try await rig.create(rig.text("k3", "beta three")),
        ])
        let db = rig.store.database
        try await renameItemTable(rig, from: "item", to: "item_unreadable")

        // when the user searches and the other entry points are read
        let page = await db.items(matching: LibraryQuery(text: "alpha"))
        let count = await db.count(filter: .all, text: "alpha")
        let sidebar = await db.sidebarCounts()

        // then each fails with STO-DB-004 rather than returning an empty success
        for (name, code) in [("page", page.failureCode), ("count", count.failureCode), ("sidebar", sidebar.failureCode)] {
            #expect(code == .stoDb004, "\(name)")
        }

        // when the fault is removed and the user clicks Retry
        try await renameItemTable(rig, from: "item_unreadable", to: "item")
        let retried = try await db.listing(LibraryQuery(text: "alpha"))

        // then the list is back, with the correct ids and count
        #expect(retried.total == 2)
        #expect(retried.unique.isSubset(of: ids) && retried.ids.count == 2)
        #expect(try await db.count(filter: .all).get() == 3)
        #expect(try await db.sidebarCounts().get().all == 3)
    }
}

extension Result where Failure == FlotsamError {
    fileprivate var failureCode: ErrorCode? {
        if case .failure(let error) = self { return error.code }
        return nil
    }
}
