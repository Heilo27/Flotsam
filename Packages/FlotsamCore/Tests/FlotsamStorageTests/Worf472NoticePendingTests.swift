import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

/// Delegating file system that can fail a move, a write or a remove by file name, and records every remove.
final class W472FileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    let removed = Cell<[String]>([])
    var failMoveNamed: Set<String> = []
    var failWriteNamed: Set<String> = []
    var failRemoveNamed: Set<String> = []

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> {
        if failMoveNamed.contains(destination.lastPathComponent) { return .failure(FlotsamError(.stoIo002, "injected move failure")) }
        return real.moveItem(at: source, to: destination)
    }
    func removeItem(at url: URL) -> FlotsamResult<Void> {
        removed.mutate { $0.append(url.path) }
        if failRemoveNamed.contains(url.lastPathComponent) { return .failure(FlotsamError(.stoIo002, "injected remove failure")) }
        return real.removeItem(at: url)
    }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> {
        if failWriteNamed.contains(url.lastPathComponent) { return .failure(FlotsamError(.stoIo002, "injected write failure")) }
        return real.writeFile(data, to: url, permissions: permissions)
    }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { real.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { real.availableCapacity(at: url) }
}

// TASK-472 / FR-007-13, AC-007-11: adversarial checks on the `notice-pending` marker. Expected values are literals.
@Suite("Worf472: notice-pending marker", .timeLimit(.minutes(3)))
struct Worf472NoticePendingTests {
    private func open(_ root: URL, fs: any FileSystemPort = LocalFileSystem()) async -> (failure: FlotsamError?, notice: FlotsamError?) {
        switch await FlotsamDatabase.open(folder: root, fileSystem: fs, clock: SystemClock(), migrations: Migrations.all) {
        case .failure(let error): return (error, nil)
        case .success(let db): return (nil, db.openNotice)
        }
    }

    private func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private func corruptDirs(_ root: URL) -> [String] { names(root).filter { $0.hasPrefix("corrupt-") } }

    /// Arranges "-wal already moved, -shm fails": zero-byte main + real -wal + -shm. Returns the wal sha.
    private func arrangeShmOnlyFailure(_ root: URL) throws -> String {
        try V370.buildWithWal(into: root)
        let sha = try #require(V370.sha(V370.walURL(root)))
        try Data().write(to: V370.dbURL(root))
        try Data("shm".utf8).write(to: root.appendingPathComponent("flotsam.sqlite-shm"))
        return sha
    }

    // OC-472-A given -shm-only failure, when relaunching, then the only removeItem call is the marker and the -wal is untouched.
    // Red if: the notice path deletes anything besides the marker (e.g. removes the whole corrupt dir).
    @Test func relaunch_removesOnlyTheMarker_everythingElseSurvives() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let walSha = try arrangeShmOnlyFailure(root)
        let fs1 = W472FileSystem(); fs1.failMoveNamed = ["flotsam.sqlite-shm"]
        #expect(await open(root, fs: fs1).failure?.code == .stoDb003)
        let dir = try #require(corruptDirs(root).first)
        let before = names(root.appendingPathComponent(dir))
        #expect(before.contains("notice-pending") && before.contains("flotsam.sqlite-wal") && before.contains("flotsam.sqlite"))

        let fs2 = W472FileSystem()
        let second = await open(root, fs: fs2)
        #expect(second.notice?.code == .stoDb002)
        #expect(fs2.removed.value.map { ($0 as NSString).lastPathComponent } == ["notice-pending"])
        let after = names(root.appendingPathComponent(dir))
        #expect(after == before.filter { $0 != "notice-pending" })
        #expect(V370.sha(root.appendingPathComponent(dir).appendingPathComponent("flotsam.sqlite-wal")) == walSha)
    }

    // OC-472-B given two marked quarantines and one unmarked, when opening, then ONE notice, both markers gone, unmarked untouched.
    // Red if: consume stops at the first marker, or deletes unmarked folders.
    @Test func multipleCorruptDirs_oneNotice_allMarkersConsumed() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for (name, marked) in [("corrupt-1700000000001", true), ("corrupt-1700000000002", true), ("corrupt-1700000000003", false)] {
            let d = root.appendingPathComponent(name)
            try fm.createDirectory(at: d, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: d.appendingPathComponent("flotsam.sqlite-wal"))
            if marked { try Data().write(to: d.appendingPathComponent("notice-pending")) }
        }
        // Recent stamps would expire; these are 2023, past 30 days, so use fresh stamps instead.
        for d in corruptDirs(root) { try fm.removeItem(at: root.appendingPathComponent(d)) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let stamps = [now - 1000, now - 2000, now - 3000]
        for (i, s) in stamps.enumerated() {
            let d = root.appendingPathComponent("corrupt-\(s)")
            try fm.createDirectory(at: d, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: d.appendingPathComponent("flotsam.sqlite-wal"))
            if i < 2 { try Data().write(to: d.appendingPathComponent("notice-pending")) }
        }
        let first = await open(root)
        #expect(first.notice?.code == .stoDb002)
        for (i, s) in stamps.enumerated() {
            let d = root.appendingPathComponent("corrupt-\(s)")
            #expect(names(d) == ["flotsam.sqlite-wal"], "dir \(i) must hold only its -wal")
        }
        #expect(corruptDirs(root).count == 3)
        #expect(await open(root).notice == nil)
    }

    // OC-472-C given `notice-pending` that is a directory or a symlink, when opening, then no notice and it is left alone.
    // Red if: the marker test is loosened to fileExists (would remove the symlink target / dir).
    @Test func nonRegularMarker_isIgnored() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let a = root.appendingPathComponent("corrupt-\(now - 1000)")
        let b = root.appendingPathComponent("corrupt-\(now - 2000)")
        try fm.createDirectory(at: a.appendingPathComponent("notice-pending"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: a.appendingPathComponent("notice-pending/inner"))
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("precious".utf8).write(to: outside)
        try fm.createSymbolicLink(at: b.appendingPathComponent("notice-pending"), withDestinationURL: outside)
        let r = await open(root)
        #expect(r.notice == nil)
        #expect(fm.fileExists(atPath: a.appendingPathComponent("notice-pending/inner").path))
        #expect(fm.fileExists(atPath: outside.path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: b.appendingPathComponent("notice-pending").path)) != nil)
    }

    // OC-472-D given the marker cannot be written, when the -shm move fails, then the launch still fails closed
    // (STO-DB-003), the -wal is preserved, the next launch opens a library (no crash, no data loss).
    // Red if: a marker write failure turns into success/crash, or the -wal moves/vanishes.
    @Test func markerWriteFailure_stillFailsClosed_dataSafe() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let walSha = try arrangeShmOnlyFailure(root)
        let fs = W472FileSystem(); fs.failMoveNamed = ["flotsam.sqlite-shm"]; fs.failWriteNamed = ["notice-pending"]
        #expect(await open(root, fs: fs).failure?.code == .stoDb003)
        let dir = try #require(corruptDirs(root).first)
        #expect(!names(root.appendingPathComponent(dir)).contains("notice-pending"))
        let second = await open(root)
        #expect(second.failure == nil)
        let held = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?
            .filter { V370.sha(root.appendingPathComponent($0)) == walSha } ?? []
        #expect(held.count == 1 && held[0].hasPrefix("corrupt-"))
    }

    // OC-472-E given the marker cannot be removed, then the notice is still raised and is retried (raised again) next launch;
    // once removable, it stops. Documents the fail-loud direction.
    // Red if: a removal failure suppresses the notice.
    @Test func markerRemovalFailure_noticeStillRaised_thenRetried() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try arrangeShmOnlyFailure(root)
        let fs = W472FileSystem(); fs.failMoveNamed = ["flotsam.sqlite-shm"]
        _ = await open(root, fs: fs)
        let stuck = W472FileSystem(); stuck.failRemoveNamed = ["notice-pending"]
        #expect(await open(root, fs: stuck).notice?.code == .stoDb002)
        #expect(await open(root, fs: stuck).notice?.code == .stoDb002)
        #expect(await open(root).notice?.code == .stoDb002)
        #expect(await open(root).notice == nil)
    }

    // OC-472-F given a first launch whose very first move failed (marker in an otherwise empty corrupt dir), when the
    // next launch quarantines for real and raises STO-DB-002, then the stale marker is consumed too: the launch after
    // that raises nothing. Red if: the stale marker survives and a second, spurious STO-DB-002 fires later.
    @Test func staleMarkerFromEarlierFailedQuarantine_notReraisedAfterRealQuarantine() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: V370.dbURL(root))
        let fs = W472FileSystem(); fs.failMoveNamed = ["flotsam.sqlite"]
        #expect(await open(root, fs: fs).failure?.code == .stoDb003)
        #expect(corruptDirs(root).count == 1)
        let second = await open(root)
        #expect(second.notice?.code == .stoDb002)
        #expect(corruptDirs(root).count == 2)
        let third = await open(root)
        #expect(third.notice == nil, "one damage event, one notice per recovery; the stale marker must not fire again")
    }

    // OC-472-G given a marked quarantine older than 30 days, when opening, then it is expired whole and no notice fires
    // (documented: the 30-day expiry runs first). Red if: expiry order changes or expiry skips marked dirs.
    @Test func expiredMarkedQuarantine_isDeletedWhole_noNotice() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await open(root)  // a launch that creates the file migrates; expiry runs only on a later clean launch
        let d = root.appendingPathComponent("corrupt-1600000000000")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data().write(to: d.appendingPathComponent("notice-pending"))
        let r = await open(root)
        #expect(r.notice == nil)
        #expect(corruptDirs(root).isEmpty)
    }

    // OC-472-H given a healthy folder with no quarantine, when opening, then no notice (0 case).
    @Test func noQuarantine_noNotice() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = await open(root)
        #expect(r.failure == nil && r.notice == nil)
        #expect(corruptDirs(root).isEmpty)
    }
}
