import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8V remediation B, data-folder and database-open obligations that had no test: OC-7004, 7005, 7006, 7007,
// 7008, 7009, 7010, 7041 and 7149. Each test names the Sources change that turns it red.
//
// What a unit test cannot see is said on the test: a real SIGKILL (7010), a trace of the whole Flotsam process
// (7005) and a network monitor (7149) need a running app, so these assert the on-disk or in-code half and say so.

// MARK: Helpers

/// A file system that records every path it was asked to write, create, move to, copy to or remove.
final class RecordingFileSystem: FileSystemPort, @unchecked Sendable {
    private let inner: any FileSystemPort
    private let lock = NSLock()
    private var recorded: [URL] = []

    init(wrapping inner: any FileSystemPort) { self.inner = inner }

    var writes: [URL] { lock.withLock { recorded } }
    private func note(_ url: URL) { lock.withLock { recorded.append(url) } }

    func fileExists(at url: URL) -> Bool { inner.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> {
        note(url); return inner.createDirectory(at: url, permissions: permissions)
    }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> {
        note(destination); return inner.copyItem(at: source, to: destination)
    }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> {
        note(destination); return inner.moveItem(at: source, to: destination)
    }
    func removeItem(at url: URL) -> FlotsamResult<Void> { note(url); return inner.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { inner.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { inner.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> {
        note(url); return inner.writeFile(data, to: url, permissions: permissions)
    }
    func readFile(at url: URL) -> FlotsamResult<Data> { inner.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { inner.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { inner.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { inner.availableCapacity(at: url) }
}

/// A settings store backing that records every key it was asked to read or write.
final class RecordingKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var readKeys: Set<String> = []
    private var writtenKeys: Set<String> = []

    func string(forKey key: String) -> String? { lock.withLock { readKeys.insert(key); return values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { writtenKeys.insert(key); values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { writtenKeys.insert(key); _ = values.removeValue(forKey: key) } }
    var reads: Set<String> { lock.withLock { readKeys } }
    var writes: Set<String> { lock.withLock { writtenKeys } }
    func forgetHistory() { lock.withLock { readKeys = []; writtenKeys = [] } }
}

/// Paths of everything under `root`, relative to it, files and folders both.
func unmapped007Listing(_ root: URL) -> Set<String> {
    let base = root.resolvingSymlinksInPath().path
    guard let walker = FileManager.default.enumerator(atPath: root.resolvingSymlinksInPath().path) else { return [] }
    _ = base
    return Set(walker.compactMap { $0 as? String })
}

/// The package's `Sources/` folder, found from this file's own path.
func unmapped007SourcesRoot(_ file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")
}

/// Every `.swift` file under `Sources/` with its text.
func unmapped007SourceFiles() -> [(path: String, text: String)] {
    let root = unmapped007SourcesRoot()
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
    return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.compactMap { relative in
        (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)).map { (relative, $0) }
    }
}

/// The networking tokens FRD-007 section 5 forbids anywhere in the product's code.
enum Unmapped007NetworkScan {
    static let forbidden = [
        "URLSession", "NWConnection", "NWListener", "NWPath", "import Network", "CFNetwork", "CFSocket", "NSURLConnection",
        "getaddrinfo", "WKWebView", "import WebKit", "http://", "https://",
    ]
    static func hits(in text: String) -> [String] { forbidden.filter { text.contains($0) } }
}

private let pngImage = TestImage.make(width: 16, height: 16, format: .png)

@Suite(.timeLimit(.minutes(1))) struct Unmapped007OpenAndFolderTests {
    private func code(_ result: FlotsamResult<IngestResult>) -> ErrorCode? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    // MARK: OC-7004

    /// OC-7004. Red if a setting is ever persisted into the data folder (a settings or preferences file appears
    /// there) or if the preset does not survive a relaunch.
    @Test("OC-7004 the retention preset survives a relaunch and the data folder gains no settings file")
    func oc7004_presetPersistsAndFolderGainsNoSettingsFile() async throws {
        // given a data folder listing L0, a 60 day old item, and settings kept in their own defaults suite
        let suite = TestDefaultsSuite("oc7004")
        defer { suite.remove() }
        let settings = SettingsStore(store: UserDefaultsStore(defaults: suite.defaults))
        let store = try await Store.make()
        defer { store.cleanUp() }
        let rig = Rig(
            store: store, settings: settings, ingest: IngestActor(database: store.database, settings: settings),
            fileSystem: CapacityFileSystem(capacity: 10 * 1024 * mib))
        try await store.insert(Spec(n: 1, ageMs: 60 * dayMs))
        let l0 = unmapped007Listing(store.root)
        #expect(settings.value(SettingKeys.storageRetention) == .d30, "precondition: the default is 30 days")

        // when the user picks 90 days and a session runs (a copy, a sweep, a reconcile)
        settings.set(RetentionPreset.d90, for: SettingKeys.storageRetention)
        _ = try await rig.create(rig.text("k-7004", "a copy during the session"))
        let sweep = try await store.database.runRetentionSweep(preset: settings.value(SettingKeys.storageRetention), budget: .unlimited).get()
        _ = try await store.database.reconcile().get()

        // then after a "relaunch" (a new defaults object over the same suite) the preset still reads 90 days
        let relaunched = SettingsStore(store: UserDefaultsStore(defaults: suite.defaults))
        #expect(relaunched.value(SettingKeys.storageRetention) == .d90)
        // and it is the 90 day preset that governed the sweep: the 60 day old item survived (30 days would delete it)
        #expect(sweep.retentionDeleted == 0)
        let ids = try await store.reader().read { try String.fetchAll($0, sql: "SELECT id FROM item") }
        #expect(ids.count == 2)
        #expect(ids.contains(Store.id(1).uuidString), "the 60 day old item must survive a 90 day sweep")
        // and the data folder gained nothing but SQLite's own companion files, and no file that looks like settings
        let added = unmapped007Listing(store.root).subtracting(l0)
        #expect(added.subtracting(["flotsam.sqlite-wal", "flotsam.sqlite-shm"]).isEmpty, "unexpected new files: \(added)")
        let all = unmapped007Listing(store.root).map { $0.lowercased() }
        #expect(all.allSatisfy { !$0.contains("setting") && !$0.contains("preference") && !$0.hasSuffix(".plist") && !$0.hasSuffix(".json") })
    }

    // MARK: OC-7005

    /// OC-7005, the part a unit test can see: every write the Storage layer asks its file system for during a scripted
    /// session lands under the data folder, and nothing but the data folder appears beside it. (The fs_usage trace of
    /// the running app, including pasteboard and drag-out, is out of reach of a unit test.) Red if any path (the
    /// staging folder, a blob, a thumbnail) is redirected outside the data folder.
    @Test("OC-7005 a scripted session writes only inside the data folder")
    func oc7005_scriptedSessionWritesOnlyInsideTheDataFolder() async throws {
        // given a data folder that is the only thing in its own parent, behind a recording file system
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-7005-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Flotsam")
        let capacity = CapacityFileSystem(capacity: 10 * 1024 * mib)
        let recording = RecordingFileSystem(wrapping: capacity)
        let store = try await Store.make(fileSystem: recording, root: root)
        let settings = SettingsStore(store: MemoryKV())
        let rig = Rig(store: store, settings: settings, ingest: IngestActor(database: store.database, settings: settings), fileSystem: capacity)

        // when a session copies text, an image and files, imports a screenshot, deletes an item and clears history
        let text = try await rig.create(rig.text("k-text", "session text"))
        _ = try await rig.create(rig.image("k-image", pngImage))
        _ = try await rig.create(rig.files("k-files", count: 3))
        _ = try await rig.create(rig.image("k-shot", TestImage.make(width: 24, height: 24, format: .png), kind: .screenshot, origin: .screenshotFile))
        _ = try await store.database.delete(ids: [text]).get()
        store.clock.advance(ms: 11 * 60_000)
        _ = try await store.database.reconcile().get()
        let cleared = try await store.database.clearHistory(range: .allTime, includeExempt: true).get()

        // then the session did write (the recording is live), and every recorded path is inside the data folder
        #expect(cleared.deletedCount == 3)
        let writes = recording.writes
        #expect(writes.count > 5, "the recording must have seen the session: \(writes.count)")
        let rootPath = root.standardizedFileURL.path
        let outside = writes.filter { $0.standardizedFileURL.path != rootPath && !$0.standardizedFileURL.path.hasPrefix(rootPath + "/") }
        #expect(outside.isEmpty, "writes outside the data folder: \(outside.map(\.path))")
        // and on disk the parent still holds only the data folder
        #expect(unmapped007Listing(parent).filter { !$0.hasPrefix("Flotsam") }.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["Flotsam"])
    }

    // MARK: OC-7006

    /// OC-7006, the Storage half: a parent that cannot be written to makes open fail STO-IO-002, Fatal, and no folder
    /// is created. (The alert with 'Reveal Data Folder' and 'Quit' and the process exit are app UI.) Red if the folder
    /// failure is mapped to another code or severity, or swallowed.
    @Test("OC-7006 an unwritable Application Support makes open fail STO-IO-002 fatal and creates nothing")
    func oc7006_unwritableParentFailsFatalWithNoFolder() async throws {
        // given a parent folder that cannot be written to and no data folder inside it
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-7006-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        try #require(!FileManager.default.isWritableFile(atPath: parent.path), "precondition: the parent must be unwritable")
        let target = parent.appendingPathComponent("Flotsam")

        // when the database is opened there
        let result = await FlotsamDatabase.open(folder: target)

        // then it fails STO-IO-002 as a fatal, and no data folder exists
        guard case .failure(let error) = result else { Issue.record("open must fail"); return }
        #expect(error.code == .stoIo002)
        #expect(error.severity == .fatal)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)

        // when the parent becomes writable again
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let retry = await FlotsamDatabase.open(folder: target)

        // then the same open succeeds and creates the folder (the refusal was the permission, not the call)
        guard case .success = retry else { Issue.record("open must succeed once writable"); return }
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("flotsam.sqlite").path))
    }

    // MARK: OC-7007

    /// OC-7007, the Storage half: with `blobs/` unwritable an image copy fails STO-IO-001, nothing is stored or left
    /// in staging, and the next copy works once the folder is writable again. (The log line, the one Notice and the
    /// process staying alive belong to Capture and the app.) Red if the blob failure is mapped to another code, an
    /// item row is kept, or staging is left behind.
    @Test("OC-7007 an unwritable blobs folder refuses an image with STO-IO-001 and leaves no item, blob or staging file")
    func oc7007_unwritableBlobsFolderRefusesImage() async throws {
        // given N=1 item and a blobs folder that cannot be written
        let rig = try await Rig.make()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.store.blobsDir.path)
            rig.cleanUp()
        }
        _ = try await rig.create(rig.text("k-existing", "already here"))
        let repsBefore = try rig.store.count("representation")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rig.store.blobsDir.path)
        try #require(!FileManager.default.isWritableFile(atPath: rig.store.blobsDir.path), "precondition: blobs/ must be unwritable")
        let tmp = rig.store.root.appendingPathComponent("tmp")

        // when an image is copied
        let result = await rig.ingest.ingest(rig.image("k-img-7007", pngImage))

        // then it fails STO-IO-001 as an error, the item count is unchanged, and no blob or staging file exists
        guard case .failure(let error) = result else { Issue.record("the image must be refused"); return }
        #expect(error.code == .stoIo001)
        #expect(error.severity == .error)
        #expect(try rig.itemCount() == 1)
        #expect(rig.blobFiles().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).isEmpty)
        #expect(try rig.store.count("representation") == repsBefore)

        // when blobs/ is writable again and the same image is copied
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.store.blobsDir.path)
        let id = try await rig.create(rig.image("k-img-7007", pngImage))

        // then it is created once (the refusal left no content key behind) and the earlier item is still there
        #expect(try rig.itemCount() == 2)
        #expect(try rig.reps(id).count >= 1)
        #expect(rig.blobFiles().count >= 1)
    }

    // MARK: OC-7008

    /// OC-7008. A separate read-only connection (the `sqlite3` of the scenario) reads journal_mode, and the -wal file
    /// exists while the database is open. Red if the database is opened in any other journal mode.
    @Test("OC-7008 a separate connection reads journal_mode wal and the -wal file exists while the database is open")
    func oc7008_journalModeIsWalAndWalFileExists() async throws {
        // given a running database with one committed item
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        _ = try await rig.create(rig.text("k-7008", "wal please"))

        // when a fresh read-only connection asks for the journal mode and the folder is listed
        let mode = try await rig.store.reader().read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        let names = rig.store.names(in: rig.store.root)

        // then the mode is wal and the -wal file is there beside the database
        #expect(mode == "wal")
        #expect(names.contains("flotsam.sqlite"))
        #expect(names.contains("flotsam.sqlite-wal"))
        // and no rollback journal exists (a DELETE-mode database would use one)
        #expect(!names.contains("flotsam.sqlite-journal"))
    }

    // MARK: OC-7009

    /// OC-7009, foreign key half. Behaviour, not a pragma read: a child row for an item that does not exist is
    /// refused. Red if foreign keys are off on the app's connection.
    @Test("OC-7009 a representation for a missing item is refused by the foreign key")
    func oc7009_foreignKeyRefusesAnOrphanChild() async throws {
        // given a database with one item
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(Spec(n: 1, blobs: 1, repBytes: 10))
        let before = try s.count("representation")

        // when a representation pointing at an item id that is not there is inserted through the app's connection
        var failure: Error?
        do {
            try await s.database.pool.write { db in
                try db.execute(
                    sql: "INSERT INTO representation (itemId, uti, byteSize, blobName) VALUES (?, 'public.png', 1, 'nope')",
                    arguments: ["99999999-9999-9999-9999-999999999999"])
            }
        } catch { failure = error }

        // then the insert fails with a foreign key violation and no row was added
        let dbError = try #require(failure as? DatabaseError, "the insert must throw")
        #expect(dbError.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY)
        #expect(try s.count("representation") == before)
        #expect(try s.count("item") == 1)
    }

    /// OC-7009, secure delete half. Behaviour, not a pragma read: after an item is deleted and the WAL folded in, its
    /// text is nowhere in the database file or the WAL, while its neighbours are untouched. The first checkpoint
    /// proves the scan can see the text. Red if secure_delete is off on the app's connection.
    @Test("OC-7009 deleted text is not left in the database file or the WAL")
    func oc7009_deletedTextIsScrubbedFromDisk() async throws {
        // given three items on the same pages, one carrying a distinctive text, and the WAL folded into the file
        let marker = "SCRUB-7009-Zq(7x)#marker-for-the-deleted-row"
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([
            Spec(n: 1, ageMs: 3 * hourMs, text: "neighbour before"), Spec(n: 2, ageMs: 2 * hourMs, text: marker),
            Spec(n: 3, ageMs: hourMs, text: "neighbour after"),
        ])
        func checkpoint() async throws {
            try await s.database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        }
        func diskContainsMarker() throws -> Bool {
            let needle = Data(marker.utf8)
            for name in ["flotsam.sqlite", "flotsam.sqlite-wal"] {
                let url = s.root.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if try Data(contentsOf: url).range(of: needle) != nil { return true }
            }
            return false
        }
        try await checkpoint()
        #expect(try diskContainsMarker(), "precondition: the scan must find the text while the item exists")

        // when the item is deleted and the WAL is folded in again
        let removed = try await s.database.delete(ids: [Store.id(2)]).get()
        try await checkpoint()

        // then the item is gone, its neighbours remain, and the text is in neither file
        #expect(removed == [Store.id(2)])
        #expect(try s.presentIds() == [1, 3])
        #expect(try !diskContainsMarker(), "the deleted text is still readable on disk")
    }

    // MARK: OC-7010

    /// OC-7010, the on-disk half. A SIGKILL needs a second process, so this takes the bytes a kill would leave: the
    /// database, WAL and shared-memory files copied while the pool is open and nothing has been closed or
    /// checkpointed. Opening that copy must show N+1 items and the marked text exactly once. Red if the copy is
    /// acknowledged before it is committed to the WAL.
    @Test("OC-7010 the files left by an unclean stop hold the copied text exactly once")
    func oc7010_uncleanStopLeavesTheCopiedText() async throws {
        // given a database with N=2 items and one more copied just now
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        _ = try await rig.create(rig.text("k-a", "first"))
        _ = try await rig.create(rig.text("k-b", "second"))
        _ = try await rig.create(rig.text("k-mark", "MARK-K1"))

        // when the files are copied with the database still open (no close, no checkpoint), then opened elsewhere
        let crashed = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-7010-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: crashed) }
        for name in ["flotsam.sqlite", "flotsam.sqlite-wal", "flotsam.sqlite-shm"] {
            let source = rig.store.root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: crashed.appendingPathComponent(name))
            }
        }
        let relaunched = try await FlotsamDatabase.open(folder: crashed).get()
        let reader = try DatabaseQueue(path: crashed.appendingPathComponent("flotsam.sqlite").path)
        let total = try await reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item")! }
        let marked = try await reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE plainText = 'MARK-K1'")! }
        let diagnostics = try await relaunched.pragmaFacts()

        // then N+1 items are there, the marked text exists once, and the relaunched database is healthy
        #expect(total == 3)
        #expect(marked == 1)
        #expect(diagnostics.journalMode == "wal")
        #expect(relaunched.openNotice == nil)
    }

    // MARK: OC-7041

    /// OC-7041, the registry half. Every setting key declared anywhere in `Sources/` is a row of the FR-008-01 table;
    /// none is a ceiling. Red if a text, rich, image or bundle-member ceiling key is added. (Settings controls are UI.)
    /// FRD-008 completed the registry (the four FRD-007 keys were its skeleton), so the expected list is the full FR-008-01
    /// table (33 keys; later rows such as capture.cue, shortcuts.addClip and shelf.edgeBar arrived with their own tickets).
    @Test("OC-7041 the settings registry declares exactly the FR-008-01 keys and none is a ceiling")
    func oc7041_registryHoldsOnlyTheFR00801Keys() throws {
        // given every Swift file under Sources/
        let files = unmapped007SourceFiles()
        try #require(files.count > 20, "the scan must see the product's sources: \(files.count) files")

        // when the SettingKey declarations are collected
        let pattern = try NSRegularExpression(pattern: #"SettingKey\(\s*"([^"]+)""#)
        var names: [String] = []
        for file in files {
            let range = NSRange(file.text.startIndex..., in: file.text)
            for match in pattern.matches(in: file.text, range: range) {
                if let r = Range(match.range(at: 1), in: file.text) { names.append(String(file.text[r])) }
            }
        }

        // then they are exactly the rows of the FR-008-01 table
        #expect(names.sorted() == [
           "capture.autoBundle", "capture.cue", "capture.mode", "library.background", "library.closeAfterPaste",
           "library.compactPanelSize", "library.display", "library.layout", "library.panelSize",
           "library.previewPreset", "library.resumeOnReopen", "library.sort", "library.types", "library.viewMode",
           "onboarding.completed", "privacy.ignoredApps", "screenshots.enabled", "screenshots.folderOverride",
           "settings.lastPane", "shelf.edgeBar", "shelf.enabled", "shelf.placement", "shelf.revealOnEdgeHover",
           "shortcuts.addClip", "shortcuts.openLibrary", "shortcuts.pasteQueue", "shortcuts.saveClipboard",
           "shortcuts.toggleShelf", "storage.imageBudget", "storage.imageQuality", "storage.retention",
           "triggers.enabled", "triggers.excludedApps",
        ])
        #expect(names.allSatisfy { !$0.lowercased().contains("ceiling") && !$0.lowercased().contains("limit") })
    }

    /// OC-7041, the behaviour half. Large copies of every kind consult only registered keys, and never write one.
    /// Red if ingest starts reading a ceiling key.
    @Test("OC-7041 ingesting large copies reads only registered settings and writes none")
    func oc7041_ingestReadsOnlyRegisteredKeys() async throws {
        // given a rig whose settings backing records every key
        let kv = RecordingKV()
        let settings = SettingsStore(store: kv)
        settings.set(ImageQuality.balanced, for: SettingKeys.storageImageQuality)
        let store = try await Store.make()
        defer { store.cleanUp() }
        let rig = Rig(
            store: store, settings: settings, ingest: IngestActor(database: store.database, settings: settings),
            fileSystem: CapacityFileSystem(capacity: 10 * 1024 * mib))
        kv.forgetHistory()

        // when a 3 MB text, a rich text, an image and a 40 member file copy are ingested
        _ = try await rig.create(rig.text("k-big-text", String(repeating: "x", count: 3_000_000)))
        _ = try await rig.create(rig.rich("k-rich", plain: "rich", rtf: Data(repeating: 0x41, count: 500_000)))
        _ = try await rig.create(rig.image("k-img-7041", pngImage))
        _ = try await rig.create(rig.files("k-files-7041", count: 40))

        // then all four were stored, only registered keys were read, and nothing was written
        #expect(try rig.itemCount() == 4)
        let registered: Set = ["capture.mode", "storage.retention", "storage.imageBudget", "storage.imageQuality"]
        #expect(kv.reads.isSubset(of: registered), "unregistered keys read: \(kv.reads.subtracting(registered))")
        #expect(kv.reads.contains("storage.imageQuality"), "the recording must be live: \(kv.reads)")
        #expect(kv.writes.isEmpty)
    }

    // MARK: OC-7149

    /// OC-7149, the part code can show: no networking API appears anywhere in the product's sources, and the package
    /// has no dependency beyond GRDB. (A connection monitor on a running app is out of reach of a unit test.) Red if
    /// a networking import or call, or a second package dependency, is added.
    @Test("OC-7149 no source file uses a networking API and the only package dependency is GRDB")
    func oc7149_noNetworkCodeAndOneDependency() throws {
        // given every Swift file under Sources/ and the package manifest
        let files = unmapped007SourceFiles()
        try #require(files.count > 20, "the scan must see the product's sources: \(files.count) files")

        // when each file is scanned for networking tokens
        let offenders = files.compactMap { file -> String? in
            let hits = Unmapped007NetworkScan.hits(in: file.text)
            return hits.isEmpty ? nil : "\(file.path): \(hits)"
        }

        // then there are none
        #expect(offenders.isEmpty, "networking code found: \(offenders)")
        // and the manifest declares exactly one package dependency, GRDB
        let manifest = try String(contentsOf: unmapped007SourcesRoot().deletingLastPathComponent().appendingPathComponent("Package.swift"), encoding: .utf8)
        let dependencies = manifest.components(separatedBy: "\n").filter { $0.contains(".package(url:") }
        #expect(dependencies.count == 1)
        #expect(dependencies.first?.contains("groue/GRDB.swift") == true)
    }

    /// OC-7149, the scanner itself. A scan that cannot find a network call proves nothing, so it is shown to find
    /// each forbidden token and to leave harmless text alone.
    @Test("OC-7149 the scanner finds every forbidden token and ignores ordinary code")
    func oc7149_scannerFindsEachTokenAndNothingElse() {
        // given one snippet per forbidden token and one harmless snippet
        for token in Unmapped007NetworkScan.forbidden {
            // when a snippet containing the token is scanned
            let hits = Unmapped007NetworkScan.hits(in: "let x = 1 // \(token) here")
            // then exactly that token is reported
            #expect(hits == [token], "\(token) not reported alone: \(hits)")
        }
        #expect(Unmapped007NetworkScan.hits(in: "import Foundation\nimport GRDB\nlet url = URL(fileURLWithPath: \"/tmp\")").isEmpty)
    }
}
