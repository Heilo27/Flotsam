import FlotsamBase
import Foundation
import GRDB
import Testing
@testable import FlotsamPaste
@testable import FlotsamStorage

// TASK-188 / AC-003-12 (FR-003-15 step 4, FRD-003 business rule "paste count increments on every successful pasteboard
// placement"): the paste sequence against a REAL FlotsamDatabase, so the count that moves is the column the Library reads,
// not a fake's `recorded` array (PasteServiceTests asserts only the fake). Every expected value is a literal; state is read
// back through a second read-only connection and, for the user-facing number, through `items(matching:)`.
//
// p95 <= 150 ms (AC-003-12) is NOT measured here: a wall-clock percentile of Return to the posted key event depends on the
// main run loop, the real pasteboard and the target app, so it cannot be made deterministic at service level. What can be
// pinned deterministically is the only delay the service itself adds: one 40 ms settle on the happy path, zero polling
// when the panel hides at once and the target is already frontmost (test OC-3012-T). The real-app matrix of AC-003-10/11
// (Notes, Terminal, Safari, Xcode, VS Code, Finder) is manual and is not covered by any test in this file.

@MainActor
@Suite struct PasteCountDatabaseTests {
    static let target = FrontmostApp(bundleId: "com.apple.Notes", processId: 42)

    nonisolated private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    @MainActor private final class Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worf-paste-count-\(UUID().uuidString)")
        let database: FlotsamDatabase
        let service: PasteService
        let pasteboard = FakePasteboard()
        let keys = FakeKeys()
        let host = FakeHost()
        let serviceClock = RecordingClock()

        init(existingPaths: Set<String> = [], trusted: Bool = true) async throws {
            database = try await FlotsamDatabase.open(folder: root, clock: RecordingClock()).get()
            service = PasteService(
                store: database, pasteboard: pasteboard, files: FakeFiles(existing: existingPaths),
                frontmost: FakeFrontmost(target: PasteCountDatabaseTests.target, pollsUntilTarget: 0),
                accessibility: FakePermission(isAccessibilityTrusted: trusted), keys: keys, clock: serviceClock,
                ownWrites: OwnWriteLedger())
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        /// Items 1..textItems are text items ("item n"); each `bundles` entry is a bundle item with those member paths.
        func seed(textItems: Int, bundles: [Int: [String]] = [:]) async throws {
            let now = Int64(1_800_000_000_000)
            try await database.pool.write { db in
                for n in 1...textItems {
                    try db.execute(
                        sql: """
                            INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize, pinned, updatedAt)
                            VALUES (?, 'text', ?, ?, ?, ?, ?, 0, 0, ?)
                            """,
                        arguments: [PasteCountDatabaseTests.id(n).uuidString, now - Int64(n), now - Int64(n), "key-\(n)", "item \(n)", "item \(n)", now])
                }
                for (n, paths) in bundles {
                    try db.execute(
                        sql: """
                            INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize, pinned, updatedAt)
                            VALUES (?, 'bundle', ?, ?, ?, NULL, '', 0, 0, ?)
                            """,
                        arguments: [PasteCountDatabaseTests.id(n).uuidString, now - Int64(n), now - Int64(n), "key-\(n)", now])
                    for (ordinal, path) in paths.enumerated() {
                        try db.execute(
                            sql: "INSERT INTO bundleMember (itemId, ordinal, path, bookmark, isDirectory) VALUES (?, ?, ?, NULL, 0)",
                            arguments: [PasteCountDatabaseTests.id(n).uuidString, ordinal, path])
                    }
                }
            }
        }

        private func reader() throws -> DatabaseQueue {
            var configuration = Configuration()
            configuration.readonly = true
            return try DatabaseQueue(path: root.appendingPathComponent("flotsam.sqlite").path, configuration: configuration)
        }

        /// item number -> pasteCount, read on a second connection.
        func counts() throws -> [Int: Int] {
            let rows = try reader().read { try Row.fetchAll($0, sql: "SELECT id, pasteCount FROM item") }
            return Dictionary(uniqueKeysWithValues: rows.map { (Int(String(($0["id"] as String).suffix(12)))!, $0["pasteCount"] as Int) })
        }

        func lastUsed(_ n: Int) throws -> Int64? {
            try reader().read { try Int64?.fetchOne($0, sql: "SELECT lastUsedAt FROM item WHERE id = ?", arguments: [PasteCountDatabaseTests.id(n).uuidString]) ?? nil }
        }

        func itemCount() throws -> Int { try reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") ?? -1 } }

        func paste(_ n: Int, mode: PasteMode = .paste) async -> FlotsamResult<PasteOutcome> {
            await service.paste(itemId: PasteCountDatabaseTests.id(n), mode: mode, target: PasteCountDatabaseTests.target, host: host)
        }
    }

    private func code<T>(_ result: FlotsamResult<T>) -> ErrorCode? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    // Red if recordPaste is dropped from the sequence, writes without its WHERE (every row moves), or adds 2.
    @Test("OC-3012 given 3 items at pasteCount 0, when item 2 is pasted once, then only item 2 reads 1, lastUsedAt is stamped, and the item count stays 3")
    func pasteIncrementsExactlyOnce() async throws {
        let env = try await Env()
        defer { env.cleanUp() }
        try await env.seed(textItems: 3)
        #expect(try env.counts() == [1: 0, 2: 0, 3: 0])

        let outcome = try await env.paste(2).get()

        #expect(outcome == .pasted)
        #expect(try env.counts() == [1: 0, 2: 1, 3: 0])
        #expect(try env.lastUsed(2) == 1_800_000_000_000)
        #expect(try env.lastUsed(1) == nil)
        #expect(try env.itemCount() == 3, "a paste adds no history item")
        #expect(env.keys.posts == 1)
    }

    // Red if the count is set to 1 instead of incremented (second paste would still read 1).
    @Test("OC-3012 given an item pasted once, when pasted a second time, then it reads 2 (increment, not set)")
    func secondPasteReadsTwo() async throws {
        let env = try await Env()
        defer { env.cleanUp() }
        try await env.seed(textItems: 2)

        _ = try await env.paste(1).get()
        _ = try await env.paste(1).get()

        #expect(try env.counts() == [1: 2, 2: 0])
    }

    // Red if the number the Library row shows is not the stored column (the user reads ItemRow.pasteCount).
    @Test("OC-3012 given an item pasted twice, when the Library queries it, then its row reads pasteCount 2 and the other row 0")
    func libraryRowReadsTheCount() async throws {
        let env = try await Env()
        defer { env.cleanUp() }
        try await env.seed(textItems: 2)
        _ = try await env.paste(2).get()
        _ = try await env.paste(2).get()

        let page = try await env.database.items(matching: LibraryQuery()).get()

        #expect(page.totalCount == 2)
        #expect(Dictionary(uniqueKeysWithValues: page.rows.map { ($0.id, $0.pasteCount) }) == [Self.id(1): 0, Self.id(2): 2])
    }

    // FRD-003 business rule: count on every successful placement, including copy-only and the Accessibility fallback.
    // Red if either path returns before recordPaste (step 4 moved after the early returns).
    @Test("OC-3012 given copy-only and the Accessibility-denied fallback, when each pastes a different item, then each reads 1 and no key event is posted")
    func copyOnlyAndAccessibilityFallbackCount() async throws {
        let copyOnly = try await Env()
        defer { copyOnly.cleanUp() }
        try await copyOnly.seed(textItems: 2)
        let denied = try await Env(trusted: false)
        defer { denied.cleanUp() }
        try await denied.seed(textItems: 2)

        #expect(try await copyOnly.paste(1, mode: .copyOnly).get() == .copied)
        #expect(try await denied.paste(1).get() == .copiedAccessibilityDenied)

        #expect(try copyOnly.counts() == [1: 1, 2: 0])
        #expect(try denied.counts() == [1: 1, 2: 0])
        #expect(copyOnly.keys.posts == 0)
        #expect(denied.keys.posts == 0)
    }

    // Boundary: a failed paste must not count. Pasteboard write refused (LIB-OS-001) -> step 3 fails before step 4.
    // Red if recordPaste runs before the pasteboard write.
    @Test("OC-3012 given the pasteboard refuses the write, when pasted, then LIB-OS-001 and the count stays 0 for every item")
    func pasteboardFailureDoesNotCount() async throws {
        let env = try await Env()
        defer { env.cleanUp() }
        try await env.seed(textItems: 2)
        env.pasteboard.failWith = FlotsamError(.libOs001, "write refused")

        let result = await env.paste(1)

        #expect(code(result) == .libOs001)
        #expect(try env.counts() == [1: 0, 2: 0])
        #expect(try env.lastUsed(1) == nil)
        #expect(env.host.hides == 0)
    }

    // Red if the "drop missing members, none left -> LIB-DAT-001" check moves after recordPaste.
    @Test("OC-3012 given a bundle whose 2 files are all gone, when pasted, then LIB-DAT-001, nothing written, and the count stays 0")
    func allMembersGoneDoesNotCount() async throws {
        let env = try await Env(existingPaths: [])
        defer { env.cleanUp() }
        try await env.seed(textItems: 1, bundles: [9: ["/gone/one.txt", "/gone/two.txt"]])

        let result = await env.paste(9)

        #expect(code(result) == .libDat001)
        #expect(try env.counts() == [1: 0, 9: 0])
        #expect(env.pasteboard.written.isEmpty)
        #expect(env.host.hides == 0)
        #expect(try env.itemCount() == 2, "the item stays; only LIB-IO-001 deletes")
    }

    // Counter case for the one above: one surviving member is a successful paste and counts once, not once per member.
    // Red if the count is incremented per pasted member.
    @Test("OC-3012 given a bundle of 3 files with 2 still present, when pasted, then it reads 1 and the pasteboard holds exactly 2 file URLs")
    func partialBundleCountsOnce() async throws {
        let env = try await Env(existingPaths: ["/here/a.txt", "/here/c.txt"])
        defer { env.cleanUp() }
        try await env.seed(textItems: 1, bundles: [9: ["/here/a.txt", "/here/b.txt", "/here/c.txt"]])

        let outcome = try await env.paste(9).get()

        #expect(outcome == .pasted)
        #expect(try env.counts() == [1: 0, 9: 1])
        #expect(env.pasteboard.written[0].filter { $0.uti == "public.file-url" }.count == 2)
    }

    // Boundary: an id that is not in the database is LIB-IO-001; nothing is counted and no other row moves.
    // Red if the missing-row failure still runs recordPaste (it would be a no-op UPDATE today, so also red if an upsert appears).
    @Test("OC-3012 given an id with no row, when pasted, then LIB-IO-001, the 2 existing items keep count 0, and the item count stays 2")
    func missingItemDoesNotCount() async throws {
        let env = try await Env()
        defer { env.cleanUp() }
        try await env.seed(textItems: 2)

        let result = await env.paste(77)

        #expect(code(result) == .libIo001)
        #expect(try env.counts() == [1: 0, 2: 0])
        #expect(try env.itemCount() == 2)
        #expect(env.pasteboard.written.isEmpty)
        #expect(env.keys.posts == 0)
    }

    // recordPaste itself, called directly: a row that does not exist is a successful no-op and creates nothing.
    // Red if recordPaste starts inserting or throws for a deleted-meanwhile item (the paste would then show an error).
    @Test("OC-3012 given item 1 only, when recordPaste runs for id 1 and for a missing id, then both succeed, only item 1 counts, and no row is created")
    func recordPasteDirect() async throws {
        let env = try await Env()
        defer { env.cleanUp() }
        try await env.seed(textItems: 1)

        try await env.database.recordPaste(of: Self.id(1)).get()
        try await env.database.recordPaste(of: Self.id(50)).get()

        #expect(try env.counts() == [1: 1])
        #expect(try env.itemCount() == 1)
    }

    // The only delay the service adds on the happy path (AC-003-12 "<= 150 ms" budget): one 40 ms settle, no polling when
    // the panel hides at once and the target is already frontmost. Red if a poll loop or a longer settle is introduced.
    @Test("OC-3012-T given the panel hides at once and the target is frontmost, when pasted, then the service sleeps exactly one 40 ms settle")
    func happyPathAddsOnlyTheSettle() async throws {
        let env = try await Env()
        defer { env.cleanUp() }
        try await env.seed(textItems: 1)

        _ = try await env.paste(1).get()

        #expect(env.serviceClock.slept == [.milliseconds(40)])
    }
}
