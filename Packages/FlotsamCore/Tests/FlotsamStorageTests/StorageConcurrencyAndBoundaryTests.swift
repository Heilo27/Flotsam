import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-046 / FR-007-02: "Exactly one serial writer; any number of concurrent readers. All writes are transactions ...
// whichever binding library is chosen is the only module that imports SQLite."
// A writer is held open on purpose (its transaction blocked on a semaphore after it has already changed rows) so the claims
// are observed deterministically instead of by hoping two threads happen to overlap. Expected values are literals; the
// state after commit is read through a second read-only connection. A bounded wait (never an open-ended one) turns a
// reader that is blocked behind the writer into a failure instead of a hung suite.

private final class Gate: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let open = DispatchSemaphore(value: 0)
    func arrive() { reached.signal() }
    func waitForRelease() { open.wait() }
    func release() { open.signal() }
    func waitUntilReached() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { self.reached.wait(); continuation.resume() }
        }
    }
}

private extension Store {
    func scalar(_ sql: String) throws -> Int {
        try reader().read { try Int.fetchOne($0, sql: sql) ?? -1 }
    }

    func text(_ sql: String) throws -> [String?] {
        try reader().read { try String?.fetchAll($0, sql: sql) }
    }
}

private func readJoinedNotes(_ pool: DatabasePool) async -> String? {
    do {
        return try await pool.read { db in try String.fetchOne(db, sql: "SELECT group_concat(note, ',') FROM item") }
    } catch {
        return nil
    }
}

private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
    func finish(_ value: T?) {
        let pending = lock.withLock { () -> CheckedContinuation<T?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// Runs `operation`; nil when it has not finished within `seconds`. The operation runs unstructured on purpose: a reader that
/// is stuck behind the writer cannot be cancelled, and a structured group would then wait for it forever, turning the failure
/// this is meant to report into a hung suite.
private func within<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = Once<T>(continuation)
        Task.detached { once.finish(await operation()) }
        Task.detached { try? await Task.sleep(for: .seconds(seconds)); once.finish(nil) }
    }
}

@Suite struct StorageConcurrencyTests {

    /// Holds a write transaction open after it has set every note to `value`. Returns the task for the write and the gate.
    private func holdWriter(_ store: Store, setting value: String) -> (Task<Void, Error>, Gate) {
        let gate = Gate()
        let pool = store.database.pool
        let task = Task {
            try await pool.write { db in
                try db.execute(sql: "UPDATE item SET note = ?", arguments: [value])
                gate.arrive()
                gate.waitForRelease()
            }
        }
        return (task, gate)
    }

    // Red if readers are serialized behind the writer (single connection / no WAL: the read would time out), or if a reader
    // sees uncommitted rows (a mix of "old" and "new" or only "new").
    @Test("OC-7002 given a write held open after changing all 5 notes, when 8 readers read concurrently, then all finish, each sees 5 x old and none sees new")
    func readersDuringOpenWriteSeeOneCommittedSnapshot() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...5).map { Spec(n: $0, ageMs: Int64($0) * 1000) })
        try await store.database.pool.write { try $0.execute(sql: "UPDATE item SET note = 'old'") }
        let (writer, gate) = holdWriter(store, setting: "new")
        await gate.waitUntilReached()
        let pool = store.database.pool

        let snapshots: [String?] = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await within(5) { await readJoinedNotes(pool) } ?? nil
                }
            }
            var all: [String?] = []
            for await snapshot in group { all.append(snapshot) }
            return all
        }
        gate.release()
        try await writer.value

        #expect(snapshots.count == 8)
        #expect(snapshots.allSatisfy { $0 == "old,old,old,old,old" }, "readers saw \(snapshots)")
        #expect(try store.text("SELECT note FROM item ORDER BY id") == ["new", "new", "new", "new", "new"])
    }

    // The same through the public read API the Library uses: count and rows stay at the committed 5 while 3 more rows are
    // inserted and uncommitted, and become 8 only after the commit.
    // Red if items(matching:) / count(filter:) take the writer's lock or see uncommitted inserts.
    @Test("OC-7002 given a write that inserted 3 items and is still open, when the Library queries, then it sees 5, and after the commit 8")
    func publicQueriesSeeOnlyCommittedRows() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...5).map { Spec(n: $0, ageMs: Int64($0) * 1000) })
        let gate = Gate()
        let database = store.database
        let writer = Task {
            try await database.pool.write { db in
                let now = Int64(1_800_000_000_000)
                for n in 6...8 {
                    try db.execute(
                        sql: """
                            INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize, pinned, updatedAt)
                            VALUES (?, 'text', ?, ?, ?, ?, ?, 0, 0, ?)
                            """,
                        arguments: [Store.id(n).uuidString, now, now, "key-\(n)", "item \(n)", "item \(n)", now])
                }
                gate.arrive()
                gate.waitForRelease()
            }
        }
        await gate.waitUntilReached()

        let during = await within(5) { try? await database.items(matching: LibraryQuery()).get().totalCount }
        let countDuring = await within(5) { try? await database.count(filter: .all).get() }
        gate.release()
        try await writer.value
        let after = try await database.items(matching: LibraryQuery()).get()

        #expect(during == 5)
        #expect(countDuring == 5)
        #expect(after.totalCount == 8)
        #expect(Set(after.rows.map(\.id)) == Set((1...8).map(Store.id)))
    }

    // Red if togglePinned over 5 items commits per item (a reader could see 2 pinned of 5): the reader asserts it never
    // observes anything but all or nothing, across 40 toggles while 3 readers poll.
    @Test("OC-7002 given 40 whole-selection pin toggles on 5 items and 3 polling readers, when run together, then no reader ever sees a partly pinned set")
    func readersNeverSeeAPartialPinWrite() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...5).map { Spec(n: $0, ageMs: Int64($0) * 1000) })
        let database = store.database
        let ids = (1...5).map(Store.id)
        let stop = StopFlag()

        let observed: [Set<Int>] = await withTaskGroup(of: Set<Int>.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    var seen = Set<Int>()
                    while !stop.isSet {
                        if let pinned = try? await database.pool.read({ try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE pinned = 1") }) {
                            seen.insert(pinned)
                        }
                    }
                    return seen
                }
            }
            for _ in 0..<40 { _ = await database.togglePinned(ids: ids) }
            stop.set()
            var all: [Set<Int>] = []
            for await seen in group { all.append(seen) }
            return all
        }

        #expect(observed.count == 3)
        for seen in observed { #expect(seen.isSubset(of: [0, 5]), "a reader saw pinned counts \(seen.sorted())") }
        #expect(try store.scalar("SELECT COUNT(*) FROM item WHERE pinned = 1") == 0, "40 toggles end where they started")
    }

    // Red if two writers can interleave their read-decide-write: 20 concurrent toggles of one item must return exactly 10
    // pinned and 10 unpinned and end unpinned. A racing writer would show duplicates and a wrong final state.
    @Test("OC-7002 given 20 concurrent pin toggles on one item, when they all finish, then exactly 10 returned pinned, 10 unpinned, and the item is unpinned")
    func concurrentTogglesSerialize() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 1000), Spec(n: 2, ageMs: 2000)])
        let database = store.database
        let id = Store.id(1)

        let results: [Bool?] = await withTaskGroup(of: Bool?.self) { group in
            for _ in 0..<20 { group.addTask { try? await database.togglePinned(ids: [id]).get() } }
            var all: [Bool?] = []
            for await result in group { all.append(result) }
            return all
        }

        #expect(results.count == 20)
        #expect(results.filter { $0 == true }.count == 10)
        #expect(results.filter { $0 == false }.count == 10)
        #expect(try store.scalar("SELECT COUNT(*) FROM item WHERE pinned = 1") == 0)
        #expect(try store.count("item") == 2)
    }

    // Writes queue behind the open writer and apply in submission order. Red if a second writer is allowed in while the first
    // transaction is open (B would finish during the hold), or if the queued writes apply out of order (final note would be "B").
    // TASK-501 (OC-7002 flake): the order is read from the database, not from the order the two awaiting tasks resume in. Both
    // resume together once the writer is released, and under load the pool ran C's continuation before B's (`finished` came
    // back ["C", "B"] with the final note correctly "C"): the writes had applied in order, the observation had not.
    @Test("OC-7002 given writer A holding its transaction, when B then C (a later submission) set the note, then neither finishes during the hold and the final note is C")
    func writesQueueInSubmissionOrder() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 1000)])
        try await store.database.pool.write { db in
            try db.execute(sql: "CREATE TABLE applied (seq INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT)")
            try db.execute(
                sql: "CREATE TRIGGER applied_log AFTER UPDATE OF note ON item BEGIN INSERT INTO applied (note) VALUES (NEW.note); END")
        }
        let (writerA, gate) = holdWriter(store, setting: "A")
        await gate.waitUntilReached()
        let database = store.database
        let finished = FinishLog()

        let b = Task { _ = await database.setNote("B", for: Store.id(1)); finished.add("B") }
        try await Task.sleep(for: .milliseconds(200))
        let c = Task { _ = await database.setNote("C", for: Store.id(1)); finished.add("C") }
        try await Task.sleep(for: .milliseconds(300))
        let duringHold = finished.all
        let noteDuringHold = try store.text("SELECT note FROM item")
        gate.release()
        try await writerA.value
        await b.value
        await c.value

        #expect(duringHold == [], "writes must wait for the open writer")
        #expect(noteDuringHold == [nil], "A is uncommitted and B, C are queued")
        #expect(finished.all.sorted() == ["B", "C"], "both queued writes finished after the release")
        #expect(try store.text("SELECT note FROM applied ORDER BY seq") == ["A", "B", "C"], "the writes applied in submission order")
        #expect(try store.text("SELECT note FROM item") == ["C"])
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private final class FinishLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.withLock { entries.append(entry) } }
        var all: [String] { lock.withLock { entries } }
    }
}

// FR-007-02 / FR-000-02 / ADR-0001: only FlotsamStorage imports SQLite. This is the same rule bin/check-architecture.sh
// enforces in the shell; here it runs inside `swift test`, over the package Sources AND the App target, and it carries
// its own positive controls so a broken scan cannot pass silently.
@Suite struct StorageImportBoundaryTests {
    private static let repo: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// A line that imports a SQLite binding: GRDB, SQLite3, CSQLite and the GRDB-vendored SQLite modules, with or without
    /// attributes such as @testable or @preconcurrency. Comments do not count.
    private static var sqliteImport: Regex<AnyRegexOutput> { try! Regex(#"^\s*(@\w+(\([^)]*\))?\s+)*((public|internal|package)\s+)?import\s+((struct|class|func|enum|protocol|typealias|var|let)\s+)?(GRDB|SQLite3?|CSQLite|GRDBSQLite|SQLCipher)(?![A-Za-z0-9_])"#) }

    private func importers(under relative: String) throws -> [String] {
        let root = Self.repo.appendingPathComponent(relative)
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
        return try files.filter { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .contains { $0.firstMatch(of: Self.sqliteImport) != nil }
        }.map { String($0.path.dropFirst(Self.repo.path.count + 1)) }.sorted()
    }

    // Red if the pattern stops matching real import forms (a scan that matches nothing passes everything), or starts
    // matching comments or look-alike module names.
    @Test("OC-7001 the import detector matches every SQLite import spelling and nothing else")
    func detectorIsCapableOfFailing() {
        let positives = [
            "import GRDB", "  import GRDB", "@testable import GRDB", "@preconcurrency import GRDB", "public import GRDB",
            "import SQLite3", "import SQLite", "import CSQLite", "import GRDBSQLite", "import struct GRDB.Row", "import func SQLite3.sqlite3_open", "@_exported import GRDB",
        ]
        let negatives = ["// import GRDB", "import Foundation", "import FlotsamStorage", "let note = \"import GRDB\"", "import GRDBHelper"]

        #expect(positives.filter { $0.firstMatch(of: Self.sqliteImport) == nil } == [])
        #expect(negatives.filter { $0.firstMatch(of: Self.sqliteImport) != nil } == [])
    }

    // Red if any module other than FlotsamStorage, or the App, adds an import of GRDB/SQLite.
    @Test("OC-7001 no file in any package source module except FlotsamStorage, and none in App, imports GRDB or SQLite")
    func onlyStorageImportsSQLite() throws {
        let packageSources = try importers(under: "Packages/FlotsamCore/Sources")
        let app = try importers(under: "App")

        #expect(packageSources.filter { !$0.hasPrefix("Packages/FlotsamCore/Sources/FlotsamStorage/") } == [])
        #expect(app == [])
    }

    // Positive control: the scan really reads the Storage sources (a wrong repo root would find nothing and pass the test above).
    // Red if the walk finds no Storage importers, or misses the one file that opens the database.
    @Test("OC-7001 the scan does see FlotsamStorage importing GRDB, including FlotsamDatabase.swift")
    func scanSeesStorage() throws {
        let storage = try importers(under: "Packages/FlotsamCore/Sources/FlotsamStorage")

        #expect(storage.count >= 15)
        #expect(storage.contains("Packages/FlotsamCore/Sources/FlotsamStorage/Database/FlotsamDatabase.swift"))
        #expect(try importers(under: "Packages/FlotsamCore/Sources").count == storage.count)
    }

    // Red if another target (not Storage) gains the GRDB product dependency in Package.swift: the import ban would then be
    // one stray `import` away from compiling.
    @Test("OC-7001 Package.swift gives the GRDB product to exactly one target, FlotsamStorage")
    func onlyStorageDependsOnGRDB() throws {
        let manifest = try String(contentsOf: Self.repo.appendingPathComponent("Packages/FlotsamCore/Package.swift"), encoding: .utf8)
        let lines = manifest.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let productLines = lines.indices.filter { lines[$0].contains(#".product(name: "GRDB""#) }

        #expect(productLines.count == 1)
        let line = try #require(productLines.first)
        #expect(lines[line - 1].contains(#"name: "FlotsamStorage""#), "the GRDB dependency sits in the FlotsamStorage target")
    }
}
