import FlotsamBase
import Foundation
import GRDB
import Testing
@testable import FlotsamStorage

// TASK-397 blind verification (Worf). FRD-003 FR-003-07 / AC-003-05a, FRD-007 FR-007-18. Expected values are literals.
// Each test names the code change that turns it red. Real files, real bookmarks, a real database.

/// Records, for every existence check the query layer makes, whether SQLite could still backfill the WAL: a reader
/// transaction still open when the check runs pins a snapshot, so the checkpoint cannot catch up with the log.
private final class SnapshotProbeFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var probe: (@Sendable () -> Void)?
    func arm(_ probe: @escaping @Sendable () -> Void) { lock.withLock { self.probe = probe } }
    func fileExists(at url: URL) -> Bool {
        let current = lock.withLock { probe }
        current?()
        return real.fileExists(at: url)
    }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { real.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { real.writeFile(data, to: url, permissions: permissions) }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { real.availableCapacity(at: url) }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[Int]] = []
    func add(_ item: [Int]) { lock.withLock { items.append(item) } }
    var count: Int { lock.withLock { items.count } }
    var first: [Int]? { lock.withLock { items.first } }
}

@Suite struct Worf397MissingTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("worf397-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: helpers

    private func touch(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func candidate(
        _ rig: Rig, _ key: String, kind: ItemKind, members: [IngestMember]
    ) -> IngestCandidate {
        IngestCandidate(
            kind: kind, contentKey: key, members: members, origin: .pasteboard,
            occurredAt: Date(timeIntervalSince1970: Double(rig.store.clock.millis) / 1000))
    }

    private func member(_ url: URL, bookmark: Bool = false, directory: Bool = false) throws -> IngestMember {
        IngestMember(path: url.path, bookmark: bookmark ? try url.bookmarkData() : nil, isDirectory: directory)
    }

    private func rows(_ rig: Rig, page: Int = 0) async throws -> [ItemRow] {
        var query = LibraryQuery()
        query.page = page
        return try await rig.store.database.items(matching: query).get().rows
    }

    private func isMissing(_ rig: Rig, _ id: UUID) async throws -> Bool {
        try #require(try await rows(rig).first { $0.id == id }).isMissing
    }

    // MARK: (1) bookmarks

    // Red if the bookmark branch of FileMemberLocator is deleted (a moved file reads as missing).
    @Test("OC-397-B1 a file moved after capture is found through its bookmark and is not missing")
    func bookmarkFollowsMove() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let original = try touch("orig.txt")
        let id = try await rig.create(candidate(rig, "k1", kind: .file, members: [try member(original, bookmark: true)]))
        try FileManager.default.moveItem(at: original, to: dir.appendingPathComponent("renamed.txt"))
        #expect(!FileManager.default.fileExists(atPath: original.path))

        let missing = try await isMissing(rig, id)

        #expect(missing == false)
    }

    // Red if the stored-path fallback is removed and only a (failed) bookmark is consulted.
    @Test("OC-397-B2 a stale bookmark whose stored path still exists is not missing")
    func staleBookmarkPathStillExists() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let original = try touch("again.txt")
        let id = try await rig.create(candidate(rig, "k2", kind: .file, members: [try member(original, bookmark: true)]))
        try FileManager.default.removeItem(at: original)
        try Data("new file, new inode".utf8).write(to: original)

        let missing = try await isMissing(rig, id)

        #expect(missing == false)
    }

    // Red if a bookmark that cannot resolve is treated as "exists", or if missing ignores the stored path.
    @Test("OC-397-B3 bookmark and stored path both gone is missing")
    func bookmarkAndPathGone() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let original = try touch("gone.txt")
        let id = try await rig.create(candidate(rig, "k3", kind: .file, members: [try member(original, bookmark: true)]))
        try FileManager.default.removeItem(at: original)

        #expect(try await isMissing(rig, id))
    }

    // Red if the bundle rule becomes "every member must exist" or "first member decides".
    @Test("OC-397-B4 a bundle with one bookmarked member moved and one deleted is not missing")
    func bundleMixedBookmark() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let dead = try touch("dead.txt")
        let moved = try touch("moved.txt")
        let id = try await rig.create(candidate(
            rig, "k4", kind: .bundle, members: [try member(dead, bookmark: true), try member(moved, bookmark: true)]))
        try FileManager.default.removeItem(at: dead)
        try FileManager.default.moveItem(at: moved, to: dir.appendingPathComponent("moved-away.txt"))

        #expect(try await isMissing(rig, id) == false)
    }

    // MARK: (1) folders and bundles

    // Red if folder rows are not covered by the check (isMissing stays false) or isDirectory breaks the path lookup.
    @Test("OC-397-F1 a folder item is missing exactly when its folder is gone; a bundle with a live folder is not")
    func folderItems() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("LiveFolder"), dying = dir.appendingPathComponent("DyingFolder")
        for folder in [live, dying] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let deadFile = try touch("dead-in-bundle.txt")
        let liveId = try await rig.create(candidate(rig, "f-live", kind: .folder, members: [try member(live, directory: true)]))
        let dyingId = try await rig.create(candidate(rig, "f-dying", kind: .folder, members: [try member(dying, directory: true)]))
        let bundleId = try await rig.create(candidate(
            rig, "f-bundle", kind: .bundle, members: [try member(deadFile), try member(live, directory: true)]))
        try FileManager.default.removeItem(at: dying)
        try FileManager.default.removeItem(at: deadFile)

        let page = try await rows(rig)

        #expect(page.count == 3)
        #expect(page.first { $0.id == liveId }?.isMissing == false)
        #expect(page.first { $0.id == dyingId }?.isMissing == true)
        #expect(page.first { $0.id == bundleId }?.isMissing == false)
    }

    // MARK: (1) non-file kinds

    // Red if `referencesFiles` is widened to other kinds, or the guard in markingMissing is dropped.
    @Test("OC-397-N1 text, link, colour, phone, email, rich text, image and screenshot rows are never missing")
    func nonFileKindsNeverMissing() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let live = try touch("live.txt")
        let kinds: [ItemKind] = [.text, .richText, .link, .color, .phone, .email, .image, .screenshot]
        var specs = kinds.enumerated().map { Spec(n: $0.offset + 1, kind: $0.element, ageMs: Int64($0.offset) * 1000) }
        // Even with leftover member rows pointing nowhere, a non-file kind must not be marked.
        specs[0].members = [(path: dir.appendingPathComponent("nowhere").path, isDirectory: false)]
        specs.append(Spec(n: 20, kind: .file, ageMs: 9000, members: [(path: live.path, isDirectory: false)]))
        try await rig.store.insert(specs)

        let page = try await rows(rig)

        #expect(page.count == 9)
        #expect(page.filter(\.isMissing).count == 0)
    }

    // Same, with no file-kind row on the page at all (the shortcut branch of markingMissing).
    @Test("OC-397-N2 a page with only non-file rows has no missing row")
    func onlyNonFilePage() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        try await rig.store.insert([Spec(n: 1, kind: .text), Spec(n: 2, kind: .link, ageMs: 1000), Spec(n: 3, kind: .image, ageMs: 2000)])

        let page = try await rows(rig)

        #expect(page.count == 3)
        #expect(page.filter(\.isMissing).count == 0)
    }

    // MARK: (5) symlinks

    // Red if existence is tested with lstat-style semantics that reject a link, or the check is skipped for links.
    @Test("OC-397-S1 a member path that is a symlink to a live file is not missing")
    func symlinkToLiveFile() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let target = try touch("target.txt")
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let id = try await rig.create(candidate(rig, "s1", kind: .file, members: [try member(link)]))

        #expect(try await isMissing(rig, id) == false)
    }

    // CHARACTERISATION: the FRD is silent on a dangling link. Current behaviour (FileManager.fileExists follows the
    // link) reads it as missing, which agrees with paste (the same locator). Red if that changes.
    @Test("OC-397-S2 characterisation: a symlink whose target was deleted reads as missing")
    func danglingSymlink() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let target = try touch("target2.txt")
        let link = dir.appendingPathComponent("link2.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let id = try await rig.create(candidate(rig, "s2", kind: .file, members: [try member(link)]))
        try FileManager.default.removeItem(at: target)
        #expect(FileManager.default.destinationOfSymbolicLinkExists(link))

        #expect(try await isMissing(rig, id))
    }

    // MARK: (5) page of 200

    // Red if the check is applied only to part of the page, or if missing state is attached to the wrong row.
    @Test("OC-397-P1 a full page of 200 file rows marks exactly the deleted ones, by identity, on both pages")
    func twoHundredRows() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        var specs: [Spec] = []
        for n in 1...250 {
            let url = dir.appendingPathComponent("f\(n).txt")
            if n % 5 != 0 { try Data("x".utf8).write(to: url) }
            specs.append(Spec(n: n, kind: .file, ageMs: Int64(n) * 1000, members: [(path: url.path, isDirectory: false)]))
        }
        try await rig.store.insert(specs)

        let first = try await rows(rig, page: 0)
        let second = try await rows(rig, page: 1)

        #expect(first.count == 200)
        #expect(second.count == 50)
        #expect(first.filter(\.isMissing).count == 40)
        #expect(second.filter(\.isMissing).count == 10)
        let missingIds = Set((first + second).filter(\.isMissing).map(\.id))
        let expectedIds = Set((1...250).filter { $0 % 5 == 0 }.map(Store.id))
        #expect(missingIds == expectedIds)
    }

    // MARK: (3) after the read transaction

    // Red if the existence checks are moved inside the `pool.read` closure: the open reader snapshot pins the WAL and
    // the probe's checkpoint cannot backfill (checkpointed < log).
    @Test("OC-397-T1 existence checks run with no read snapshot open")
    func checksRunOutsideReadTransaction() async throws {
        let fileSystem = SnapshotProbeFileSystem()
        let store = try await Store.make(fileSystem: fileSystem)
        defer { store.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let live = try touch("probe.txt")
        try await store.insert([Spec(n: 1, kind: .file, members: [(path: live.path, isDirectory: false)])])
        let results = OutcomeBox()
        let pool = store.database.pool
        fileSystem.arm {
            // A write that lands after any open reader's snapshot, then a non-blocking checkpoint.
            let outcome: [Int] = (try? pool.writeWithoutTransaction { db in
                try db.execute(sql: "UPDATE item SET updatedAt = updatedAt + 1")
                let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(PASSIVE)")
                return [row?[1] ?? -1, row?[2] ?? -2]
            }) ?? [-3, -4]
            results.add(outcome)
        }

        _ = try await store.database.items(matching: LibraryQuery()).get()

        #expect(results.count == 1)
        let outcome = try #require(results.first)
        #expect(outcome[0] == outcome[1], "log frames \(outcome[0]) vs checkpointed \(outcome[1]): a reader snapshot was open")
    }

    // MARK: (5) empty bundle

    // The FRD does not say whether a bundle with zero members is missing (FR-003-07 "none of its members exist" is
    // vacuously true; FR-003-15 step 1 "none left" is also vacuously true, so paste fails with LIB-DAT-001).
    // This test does NOT pick an answer. It asserts the one thing any answer needs: the state of an item must not
    // depend on what else is on the page. Known issue until fixed: the `guard !fileMembers.isEmpty` shortcut.
    @Test("OC-397-E1 an empty bundle has the same missing state alone as beside other file rows")
    func emptyBundleStateIndependentOfPage() async throws {
        let alone = try await Rig.make(); defer { alone.cleanUp() }
        let beside = try await Rig.make(); defer { beside.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let live = try touch("beside.txt")
        try await alone.store.insert([Spec(n: 1, kind: .bundle)])
        try await beside.store.insert([
            Spec(n: 1, kind: .bundle),
            Spec(n: 2, kind: .file, ageMs: 1000, members: [(path: live.path, isDirectory: false)]),
        ])

        let aloneState = try await rows(alone).first { $0.id == Store.id(1) }?.isMissing
        let besideState = try await rows(beside).first { $0.id == Store.id(1) }?.isMissing

        withKnownIssue("TASK-397: empty-bundle state flips with page contents (LibraryQueries.markingMissing early return)") {
            #expect(aloneState == besideState, "alone=\(String(describing: aloneState)) beside=\(String(describing: besideState))")
        }
    }

    // MARK: restore

    // Red if missing is cached/stored: a folder restored must clear on the next read, a deleted one must set it.
    @Test("OC-397-R1 delete, restore, delete again: the state follows the disk on every read")
    func followsDisk() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let file = try touch("cycle.txt")
        let id = try await rig.create(candidate(rig, "r1", kind: .file, members: [try member(file)]))
        var states: [Bool] = []

        states.append(try await isMissing(rig, id))
        try FileManager.default.removeItem(at: file)
        states.append(try await isMissing(rig, id))
        try Data("back".utf8).write(to: file)
        states.append(try await isMissing(rig, id))
        try FileManager.default.removeItem(at: file)
        states.append(try await isMissing(rig, id))

        #expect(states == [false, true, false, true])
    }
}

private extension FileManager {
    /// True when `link` itself exists as a symbolic link (so a test can tell "dangling" from "never existed").
    func destinationOfSymbolicLinkExists(_ link: URL) -> Bool {
        (try? destinationOfSymbolicLink(atPath: link.path)) != nil && !fileExists(atPath: link.path)
    }
}
