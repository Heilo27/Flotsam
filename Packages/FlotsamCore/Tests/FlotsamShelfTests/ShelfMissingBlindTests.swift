import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf
@testable import FlotsamStorage

// Blind QA of the S2 Shelf Missing fix. FRD-006 FR-006-07, FRD-003 FR-003-07 / AC-003-05a, ARCHITECTURE FileMemberLocator.
// Rule under test: a file, folder or bundle card is Missing iff NO member exists (partial = present, empty bundle =
// Missing, a moved member whose bookmark resolves exists); the Library and the Shelf agree; a non-file card and a card
// the details port does not describe are never Missing. Written from the FRD, not the implementation: every expected
// value is a literal id set. Real temp files, real bookmarks, real LocalFileSystem, real database for the Library side.

private final class QuietSink: LogSink, @unchecked Sendable {
    func write(_ record: LogRecord) {}
}

/// A file system whose answer to "does it exist" is fixed, to prove the Missing rule asks the port it is given. Every
/// other call goes to the real file system so the database can open its folder.
private struct FixedFileSystem: FileSystemPort {
    let answer: Bool
    private let real = LocalFileSystem()
    func fileExists(at url: URL) -> Bool { answer }
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

/// One card to put on both surfaces, as one database row with its member rows (`nil` is the same as none).
private struct Card {
    let n: Int
    let kind: ItemKind
    let members: [ItemMember]?
    var pinned = false
}

@MainActor @Suite struct ShelfMissingBlindTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-missing-blind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: Fixtures

    private func path(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// A real file remembered by path and by bookmark.
    private func file(_ name: String, bookmark: Bool = true) throws -> (url: URL, member: ItemMember) {
        let url = path(name)
        try Data("x".utf8).write(to: url)
        return (url, ItemMember(path: url.path, bookmark: bookmark ? try url.bookmarkData() : nil, isDirectory: false))
    }

    /// A real directory remembered by path and by bookmark.
    private func folder(_ name: String, bookmark: Bool = true) throws -> (url: URL, member: ItemMember) {
        let url = path(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, ItemMember(path: url.path, bookmark: bookmark ? try url.bookmarkData() : nil, isDirectory: true))
    }

    private func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    private func move(_ url: URL, to name: String) throws { try FileManager.default.moveItem(at: url, to: path(name)) }

    private func cleanUp() {
        // A test may leave a directory with no permissions behind.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path("locked").path)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Surfaces

    /// A real database holding the cards (S1 ruling 2026-11-17: both surfaces read `ItemRow.isMissing` from it).
    private func database(_ cards: [Card], files: any FileSystemPort = LocalFileSystem()) async throws -> FlotsamDatabase {
        let root = path("library-\(UUID().uuidString)")
        let database = try await FlotsamDatabase.open(folder: root, fileSystem: files, logSink: QuietSink()).get()
        try await database.pool.write { db in
            for card in cards {
                let id = shelfID(card.n).uuidString
                try db.execute(
                    sql: "INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, updatedAt, pinned) VALUES (?, ?, 1, ?, ?, 1, ?)",
                    arguments: [id, card.kind.rawValue, card.n, "key-\(card.n)", card.pinned ? 1 : 0])
                for (ordinal, member) in (card.members ?? []).enumerated() {
                    try db.execute(
                        sql: "INSERT INTO bundleMember (itemId, ordinal, path, bookmark, isDirectory) VALUES (?, ?, ?, ?, ?)",
                        arguments: [id, ordinal, member.path, member.bookmark, member.isDirectory ? 1 : 0])
                }
            }
        }
        return database
    }

    /// The ids the Shelf marks Missing, drawn by the real model over the database.
    private func shelfMissing(in database: FlotsamDatabase) async -> Set<UUID> {
        let model = ShelfModel(source: database, paster: FakeShelfPaster(), host: FakeShelfHost(), events: ItemEventBus(), details: database)
        await model.open(target: textEdit, sticky: true)
        return Set(model.sections().flatMap(\.cards).filter(\.isMissing).map(\.id))
    }

    /// The ids the Shelf marks Missing for these cards.
    private func shelfMissing(_ cards: [Card], files: any FileSystemPort = LocalFileSystem()) async throws -> Set<UUID> {
        await shelfMissing(in: try await database(cards, files: files))
    }

    /// The ids the Library's real query marks Missing for the cards, read from a real database.
    private func libraryMissing(_ cards: [Card]) async throws -> Set<UUID> {
        let page = try await database(cards).items(matching: LibraryQuery()).get()
        #expect(page.rows.count == cards.count, "every card must be on the Library page")
        return Set(page.rows.filter(\.isMissing).map(\.id))
    }

    /// Both surfaces must name exactly `expected` (card numbers) as Missing, and so agree with each other.
    private func expectMissing(
        _ expected: Set<Int>, _ cards: [Card], _ label: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let want = Set(expected.map(shelfID))
        let shelf = try await shelfMissing(cards)
        let library = try await libraryMissing(cards)
        #expect(shelf == want, "Shelf: \(label)", sourceLocation: sourceLocation)
        #expect(library == want, "Library: \(label)", sourceLocation: sourceLocation)
        #expect(shelf == library, "agreement: \(label)", sourceLocation: sourceLocation)
    }

    // MARK: Bookmarks that move

    // given a file renamed in place after capture (old path gone, bookmark resolves) next to a really deleted one
    // red if the Shelf checks the stored path only, or marks every card with a vanished path
    @Test("OC-S2-006-W1 a member renamed in place after capture is present; only the genuinely deleted card is Missing")
    func renameAfterCapture() async throws {
        defer { cleanUp() }
        let renamed = try file("report.txt")
        try move(renamed.url, to: "report-final.txt")
        let deleted = try file("gone.txt")
        try remove(deleted.url)

        try await expectMissing([2], [
            Card(n: 1, kind: .file, members: [renamed.member]),
            Card(n: 2, kind: .file, members: [deleted.member]),
        ], "renamed present, deleted Missing")
    }

    // given a file moved twice into other folders and a parent folder renamed (the bookmark is stale each time)
    // red if resolution is dropped, only the first hop is followed, or a stale flag is treated as "gone"
    @Test("OC-S2-006-W2 a member moved twice, and one whose parent folder was renamed, is present (stale bookmark still resolves)")
    func movedTwiceAndParentRenamed() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: path("one"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: path("two"), withIntermediateDirectories: true)
        let hopper = try file("hopper.txt")
        try move(hopper.url, to: "one/hopper.txt")
        try move(path("one/hopper.txt"), to: "two/hopper.txt")

        try FileManager.default.createDirectory(at: path("parent"), withIntermediateDirectories: true)
        let inner = path("parent/inner.txt")
        try Data("x".utf8).write(to: inner)
        let innerMember = ItemMember(path: inner.path, bookmark: try inner.bookmarkData(), isDirectory: false)
        try move(path("parent"), to: "parent-renamed")

        try await expectMissing([], [
            Card(n: 1, kind: .file, members: [hopper.member]),
            Card(n: 2, kind: .file, members: [innerMember]),
        ], "moved twice and parent renamed")
    }

    // given a file moved and then deleted at its new place
    // red if a resolving-but-now-empty bookmark counts as existing (the resolved URL is not stat'ed)
    @Test("OC-S2-006-W3 a member that moved and was then deleted is Missing, not rescued by its stale bookmark")
    func movedThenDeleted() async throws {
        defer { cleanUp() }
        let a = try file("a.txt")
        try move(a.url, to: "a-moved.txt")
        try remove(path("a-moved.txt"))
        let keeper = try file("keeper.txt")

        try await expectMissing([1], [
            Card(n: 1, kind: .file, members: [a.member]),
            Card(n: 2, kind: .file, members: [keeper.member]),
        ], "moved then deleted")
    }

    // given a file deleted and a different file written at the same path (the bookmark's file identity is gone)
    // red if the Shelf requires the bookmark to resolve, i.e. drops the stored-path fallback
    @Test("OC-S2-006-W4 a member replaced by a new file at the same path is present by its stored path")
    func replacedAtSamePath() async throws {
        defer { cleanUp() }
        let original = try file("doc.txt")
        try remove(original.url)
        try Data("new".utf8).write(to: original.url)

        try await expectMissing([], [Card(n: 1, kind: .file, members: [original.member])], "replaced file")
    }

    // given a bookmark that is garbage next to a live path, and next to a dead path
    // red if an unresolvable bookmark short-circuits to Missing, or a garbage bookmark hides the path fallback
    @Test("OC-S2-006-W5 a corrupt bookmark falls back to the stored path: live path present, dead path Missing")
    func corruptBookmark() async throws {
        defer { cleanUp() }
        let live = try file("live.txt", bookmark: false)
        let dead = try file("dead.txt", bookmark: false)
        try remove(dead.url)
        let junk = Data("not a bookmark".utf8)

        try await expectMissing([2], [
            Card(n: 1, kind: .file, members: [ItemMember(path: live.url.path, bookmark: junk, isDirectory: false)]),
            Card(n: 2, kind: .file, members: [ItemMember(path: dead.url.path, bookmark: junk, isDirectory: false)]),
        ], "corrupt bookmark")
    }

    // given a stored path that is gone but whose bookmark resolves to a live file elsewhere
    // red if the bookmark is consulted only when the path exists
    @Test("OC-S2-006-W6 a member whose stored path is dead but whose bookmark resolves is present")
    func bookmarkOnly() async throws {
        defer { cleanUp() }
        let a = try file("a.txt")
        try move(a.url, to: "elsewhere.txt")
        let stalePath = ItemMember(path: path("never-existed.txt").path, bookmark: a.member.bookmark, isDirectory: false)

        try await expectMissing([], [Card(n: 1, kind: .file, members: [stalePath])], "bookmark resolves, path dead")
    }

    // MARK: Odd filesystem shapes

    // given the file's path now holds a directory
    // red only if the rule changes how "exists" is decided; Library and Shelf must at least agree. FRD says "exists".
    @Test("OC-S2-006-W7 a file replaced by a directory at the same path still exists on both surfaces")
    func fileReplacedByDirectory() async throws {
        defer { cleanUp() }
        let a = try file("thing", bookmark: false)
        try remove(a.url)
        try FileManager.default.createDirectory(at: a.url, withIntermediateDirectories: false)

        try await expectMissing([], [Card(n: 1, kind: .file, members: [a.member])], "file replaced by dir")
    }

    // given a directory member now replaced by a plain file at its path
    // red under the same change as W7, in the other direction
    @Test("OC-S2-006-W8 a folder replaced by a file at the same path still exists on both surfaces")
    func folderReplacedByFile() async throws {
        defer { cleanUp() }
        let d = try folder("box", bookmark: false)
        try remove(d.url)
        try Data("x".utf8).write(to: d.url)

        try await expectMissing([], [Card(n: 1, kind: .folder, members: [d.member])], "folder replaced by file")
    }

    // given symlink members: live target, dangling target, target deleted after capture, a link to a directory
    // red if a link is judged by lstat (the link itself), which makes a dangling link "exist" (FR-003-07: dead link = gone)
    @Test("OC-S2-006-W9 symlink members: live and directory links are present; dangling and later-orphaned links are Missing")
    func symlinkMembers() async throws {
        defer { cleanUp() }
        let target = try file("target.txt", bookmark: false)
        let liveLink = path("live-link")
        try FileManager.default.createSymbolicLink(at: liveLink, withDestinationURL: target.url)
        let dangling = path("dangling-link")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: path("no-such-target").path)
        let dirTarget = try folder("dir-target", bookmark: false)
        let dirLink = path("dir-link")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: dirTarget.url)
        let orphanTarget = try file("orphan-target.txt", bookmark: false)
        let orphanLink = path("orphan-link")
        try FileManager.default.createSymbolicLink(at: orphanLink, withDestinationURL: orphanTarget.url)
        try remove(orphanTarget.url)

        func link(_ url: URL, isDirectory: Bool = false) -> ItemMember {
            ItemMember(path: url.path, bookmark: nil, isDirectory: isDirectory)
        }
        try await expectMissing([2, 4], [
            Card(n: 1, kind: .file, members: [link(liveLink)]),
            Card(n: 2, kind: .file, members: [link(dangling)]),
            Card(n: 3, kind: .folder, members: [link(dirLink, isDirectory: true)]),
            Card(n: 4, kind: .file, members: [link(orphanLink)]),
        ], "symlinks")
    }

    // given a bundle of a dangling link and a real file, and a bundle of only dangling links
    // red if any dangling link taints the bundle, or if the dangling check is skipped for bundles
    @Test("OC-S2-006-W10 a bundle with one live member beside a dangling link is present; all dangling links is Missing")
    func bundleOfLinks() async throws {
        defer { cleanUp() }
        let real = try file("real.txt")
        let dangling1 = path("d1")
        let dangling2 = path("d2")
        try FileManager.default.createSymbolicLink(atPath: dangling1.path, withDestinationPath: path("zzz1").path)
        try FileManager.default.createSymbolicLink(atPath: dangling2.path, withDestinationPath: path("zzz2").path)
        let d1 = ItemMember(path: dangling1.path, bookmark: nil, isDirectory: false)
        let d2 = ItemMember(path: dangling2.path, bookmark: nil, isDirectory: false)

        try await expectMissing([2], [
            Card(n: 1, kind: .bundle, members: [d1, real.member, d2]),
            Card(n: 2, kind: .bundle, members: [d1, d2]),
        ], "bundles of links")
    }

    // given every member inside a folder whose permissions were removed (a path that cannot be stat'ed)
    // red if either surface treats "cannot tell" as present, or the two surfaces handle the error differently
    @Test("OC-S2-006-W11 members under an unreadable parent are Missing on both surfaces, and present again once access returns")
    func permissionDeniedParent() async throws {
        defer { cleanUp() }
        guard getuid() != 0 else { return }
        try FileManager.default.createDirectory(at: path("locked"), withIntermediateDirectories: true)
        let inside = path("locked/inside.txt")
        try Data("x".utf8).write(to: inside)
        let member = ItemMember(path: inside.path, bookmark: try inside.bookmarkData(), isDirectory: false)
        let cards = [Card(n: 1, kind: .file, members: [member]), Card(n: 2, kind: .bundle, members: [member])]

        try await expectMissing([], cards, "before lock")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path("locked").path)
        try await expectMissing([1, 2], cards, "locked parent")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path("locked").path)
        try await expectMissing([], cards, "after unlock")
    }

    // MARK: Bundle composition

    // given bundles that mix files and folders where one kind is gone and the other present, both orders, plus a lying flag
    // red if the rule looks at only the first member, only files, or only the isDirectory-flagged members
    @Test("OC-S2-006-W12 a mixed file and folder bundle is Missing only when both kinds are gone, in either order")
    func mixedKindsInOneBundle() async throws {
        defer { cleanUp() }
        let liveFile = try file("live.txt")
        let liveDir = try folder("live-dir")
        let deadFile = try file("dead.txt")
        try remove(deadFile.url)
        let deadDir = try folder("dead-dir")
        try remove(deadDir.url)
        // The stored flag says "file" but the path is a directory: still exists.
        let lying = ItemMember(path: liveDir.url.path, bookmark: nil, isDirectory: false)

        try await expectMissing([5], [
            Card(n: 1, kind: .bundle, members: [deadFile.member, liveDir.member]),
            Card(n: 2, kind: .bundle, members: [liveDir.member, deadFile.member]),
            Card(n: 3, kind: .bundle, members: [deadDir.member, liveFile.member]),
            Card(n: 4, kind: .bundle, members: [lying, deadFile.member]),
            Card(n: 5, kind: .bundle, members: [deadFile.member, deadDir.member]),
            Card(n: 6, kind: .folder, members: [liveDir.member]),
        ], "mixed kinds")
    }

    // given a 500-member bundle (the cap) where only the last member, then only the first member, then none survive
    // red if the rule inspects a prefix, only the first member, or caps the scan
    @Test("OC-S2-006-W13 a 500-member bundle is present when only its first or only its last member survives, Missing when none")
    func largeBundleBoundaries() async throws {
        defer { cleanUp() }
        var dead: [ItemMember] = []
        for index in 0..<499 {
            dead.append(ItemMember(path: path("ghost-\(index).txt").path, bookmark: nil, isDirectory: false))
        }
        let survivor = try file("survivor.txt")

        try await expectMissing([3], [
            Card(n: 1, kind: .bundle, members: dead + [survivor.member]),
            Card(n: 2, kind: .bundle, members: [survivor.member] + dead),
            Card(n: 3, kind: .bundle, members: dead + [ItemMember(path: path("ghost-last.txt").path, bookmark: nil, isDirectory: false)]),
        ], "500-member bundle")
    }

    // given the same real file in two different cards and one in a third; only one card loses its other files
    // red if state leaks between cards (a shared cache, or one card's survivors rescuing another)
    @Test("OC-S2-006-W14 one card's surviving member never rescues another card that lists a deleted file")
    func noLeakBetweenCards() async throws {
        defer { cleanUp() }
        let shared = try file("shared.txt")
        let onlyA = try file("only-a.txt")
        try remove(onlyA.url)

        try await expectMissing([2], [
            Card(n: 1, kind: .bundle, members: [shared.member, onlyA.member]),
            Card(n: 2, kind: .file, members: [onlyA.member]),
            Card(n: 3, kind: .file, members: [shared.member]),
        ], "no leak between cards")
    }

    // MARK: Empty, non-file, undescribed (Shelf-side contract)

    // given listed-but-empty file, folder and bundle cards, and a listed-but-empty text card
    // red if emptiness is read as "nothing missing" for the file kinds, or applied to a text card
    @Test("OC-S2-006-W15 an empty file, folder or bundle card is Missing; an empty text card is not (Shelf and Library)")
    func emptyMembers() async throws {
        defer { cleanUp() }
        try await expectMissing([1, 2, 3], [
            Card(n: 1, kind: .bundle, members: []),
            Card(n: 2, kind: .file, members: []),
            Card(n: 3, kind: .folder, members: []),
            Card(n: 4, kind: .text, members: []),
        ], "empty members")
    }

    // given every non-file kind carrying member paths that do not exist (stray rows), plus file cards the source reports
    // present (an undescribed card carries no flag)
    // red if the badge is decided from the members rather than from the kind, or an unflagged file card defaults to Missing
    @Test("OC-S2-006-W16 non-file kinds are never Missing whatever members they carry; a file card the row does not flag is never Missing")
    func nonFileAndUndescribed() async throws {
        let ghost = [ItemMember(path: path("nothing-here").path, bookmark: nil, isDirectory: false)]
        let kinds: [ItemKind] = [.text, .richText, .link, .color, .phone, .email, .image, .screenshot]
        let cards = kinds.enumerated().map { Card(n: $0.offset + 1, kind: $0.element, members: ghost) }

        let missing = try await shelfMissing(cards)

        #expect(missing.isEmpty, "marked Missing: \(missing.count) card(s)")

        let rows = [makeShelfRow(20, kind: .file), makeShelfRow(21, kind: .bundle), makeShelfRow(22, kind: .folder)]
        let rig = ShelfRig(rows: rows)
        await rig.openSticky()
        #expect(rig.model.sections().flatMap(\.cards).count == 3)
        #expect(rig.model.sections().flatMap(\.cards).filter(\.isMissing).isEmpty, "an unflagged card must not be Missing")
    }

    // given text, image and link cards that carry ghost member rows, beside a file card whose only member is a ghost
    // red if the model decides from whatever members exist instead of from the card's kind
    @Test("OC-S2-006-W25 ghost member rows on non-file cards still never make a non-file card Missing")
    func ghostMembersCannotMarkNonFileCards() async throws {
        let ghost = [ItemMember(path: path("nothing-here").path, bookmark: nil, isDirectory: false)]
        let cards = [Card(n: 1, kind: .text, members: ghost), Card(n: 2, kind: .image, members: ghost),
                     Card(n: 3, kind: .link, members: ghost), Card(n: 4, kind: .file, members: ghost)]

        let missing = try await shelfMissing(cards)

        #expect(missing == [shelfID(4)])
    }

    // given a Shelf whose details port answers for an id that is not on the Shelf, beside a flagged and an unflagged card
    // red if the stray entry produces a card or a count change, or the unflagged neighbour inherits the flag
    @Test("OC-S2-006-W17 a details entry for an id not on the Shelf adds no card and marks none")
    func strayDetailsEntry() async {
        let rows = [makeShelfRow(1, kind: .file, memberCount: 1, missing: true), makeShelfRow(2, kind: .file, memberCount: 1)]
        let rig = ShelfRig(rows: rows, details: FakeShelfDetails(texts: [shelfID(99): "stray"]))
        await rig.openSticky()

        let cards = rig.model.sections().flatMap(\.cards)
        #expect(cards.map(\.id) == [shelfID(1), shelfID(2)])
        #expect(cards.filter(\.isMissing).map(\.id) == [shelfID(1)])
    }

    // MARK: Pinned and Recent, and the disk read each time

    // given pinned and recent file cards, some Missing
    // red if the rule is applied to only one section, or the pinned rows are not given their members
    @Test("OC-S2-006-W18 Missing is marked in both the Pinned and the Recent section, exactly on the right cards")
    func pinnedAndRecent() async throws {
        defer { cleanUp() }
        let live = try file("live.txt")
        let dead = try file("dead.txt")
        try remove(dead.url)

        try await expectMissing([1, 4], [
            Card(n: 1, kind: .file, members: [dead.member], pinned: true),
            Card(n: 2, kind: .file, members: [live.member], pinned: true),
            Card(n: 3, kind: .file, members: [live.member]),
            Card(n: 4, kind: .bundle, members: [dead.member]),
        ], "pinned and recent")
    }

    // given a card whose file is deleted and then restored; the Shelf reopens each time
    // red if the Shelf caches Missing from the first read (the state is "never stored", FR-003-07)
    @Test("OC-S2-006-W19 deleting a file marks the card on the next load and restoring it clears the mark")
    func deleteThenRestoreClears() async throws {
        defer { cleanUp() }
        let a = try file("a.txt")
        let store = try await database([Card(n: 1, kind: .file, members: [a.member])])

        let before = await shelfMissing(in: store)
        try remove(a.url)
        let whileGone = await shelfMissing(in: store)
        try Data("x".utf8).write(to: a.url)
        let afterRestore = await shelfMissing(in: store)

        #expect(before.isEmpty)
        #expect(whileGone == [shelfID(1)])
        #expect(afterRestore.isEmpty)
    }

    // MARK: One rule, one port

    // given every real file present but a file system port that answers "nothing exists", and the reverse
    // red if the Shelf (or the shared helper) stats through FileManager instead of the injected FileSystemPort
    @Test("OC-S2-006-W20 the Shelf asks the file system port it was given: a port with nothing marks a card Missing; a port with everything marks none")
    func shelfUsesInjectedPort() async throws {
        defer { cleanUp() }
        let present = try file("present.txt")
        let deleted = try file("deleted.txt")
        try remove(deleted.url)
        let cards = [Card(n: 1, kind: .file, members: [present.member]), Card(n: 2, kind: .file, members: [deleted.member])]

        let nothingExists = try await shelfMissing(cards, files: FixedFileSystem(answer: false))
        let everythingExists = try await shelfMissing(cards, files: FixedFileSystem(answer: true))

        #expect(nothingExists == [shelfID(1), shelfID(2)])
        #expect(everythingExists.isEmpty)
    }

    // given the shared helper called directly on the shapes the surfaces feed it
    // red if Collection<ItemMember>.anyExists is changed to all-exist / none-exist / first-only
    @Test("OC-S2-006-W21 Collection<ItemMember>.anyExists: empty is false, one of three is true, none of three is false")
    func anyExistsContract() throws {
        defer { cleanUp() }
        let live = try file("live.txt")
        let dead = ItemMember(path: path("dead.txt").path, bookmark: nil, isDirectory: false)
        let files = LocalFileSystem()

        #expect([ItemMember]().anyExists(files: files) == false)
        #expect([dead, live.member, dead].anyExists(files: files) == true)
        #expect([dead, dead, dead].anyExists(files: files) == false)
        #expect([live.member].anyExists(files: files) == true)
    }
}
