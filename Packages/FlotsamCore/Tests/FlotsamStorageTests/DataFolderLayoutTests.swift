import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T gap batch, the data folder (FR-007-01). Modes are read back from the file system with stat, never from the
// constants the production code writes them with. Expected values are literals.

@Suite struct DataFolderLayoutTests {
    private func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    /// Every file and folder under `root`, as paths relative to it.
    private func everyEntry(under root: URL) -> [(relative: String, url: URL, isDirectory: Bool)] {
        let base = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var entries: [(String, URL, Bool)] = []
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            entries.append((String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)), url, isDirectory))
        }
        return entries
    }

    /// The backup-exclusion flag the OS reads (the same flag `tmutil isexcluded` reports for a sticky exclusion).
    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    /// OC-7001. Given no data folder exists, when the store is opened for the first time, then the folder exists with
    /// mode 0700 and holds flotsam.sqlite, blobs/, thumbs/ and tmp/, and every file Flotsam created there is 0600.
    @Test("OC-7001 a first launch creates the owner-only folder with its four members")
    func oc7001_firstLaunchLayoutAndModes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let database = try await FlotsamDatabase.open(folder: root).get()
        _ = try await database.diagnostics().get()

        #expect(try mode(root) == 0o700)
        let entries = everyEntry(under: root)
        #expect(Set(entries.map(\.relative)).isSuperset(of: ["flotsam.sqlite", "blobs", "thumbs", "tmp"]))
        for name in ["blobs", "thumbs", "tmp"] {
            #expect(try mode(root.appendingPathComponent(name)) == 0o700, "folder \(name)")
        }
        let files = entries.filter { !$0.isDirectory }
        #expect(files.map(\.relative).contains("flotsam.sqlite"))
        for file in files { #expect(try mode(file.url) == 0o600, "file \(file.relative)") }
    }

    /// OC-7001 (files written after first launch). Given an image has been copied and its thumbnails built, then every
    /// file in the folder, including the blob, thumbnails and SQLite's WAL files, is 0600 and every folder is 0700.
    @Test("OC-7001 blobs, thumbnails and database side files are owner-only too")
    func oc7001_filesWrittenLaterAreOwnerOnly() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let png = TestImage.make(width: 64, height: 48, format: .png)
        let id = try await rig.create(rig.image("k-7001", png))
        let built = await rig.awaitThumbnails(id)
        #expect(built, "both thumbnail sizes should exist before modes are read")

        let entries = everyEntry(under: rig.store.root)

        #expect(entries.filter { !$0.isDirectory }.count >= 4)  // sqlite, one blob, two thumbnails
        #expect(try rig.reps(id).count == 1)
        for entry in entries {
            #expect(try mode(entry.url) == (entry.isDirectory ? 0o700 : 0o600), "\(entry.isDirectory ? "folder" : "file") \(entry.relative)")
        }
    }

    /// OC-7002. Given a leftover tmp/leftover.part and an existing item with a blob, when the app is launched again,
    /// then tmp/ is empty, no item was created from the leftover and the existing item and its blob are untouched.
    @Test("OC-7002 launch empties tmp and creates nothing from what it held")
    func oc7002_leftoverTmpIsEmptiedAtLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let first = try await Store.make(root: root)
            try await first.insert(Spec(n: 1, kind: .richText, blobs: 1, repBytes: 12))
            try first.plant("tmp/leftover.part", contents: "half a write")
            try first.plant("tmp/nested/inner.part", contents: "more")
            #expect(first.names(in: first.root.appendingPathComponent("tmp")) == ["leftover.part", "nested"])
            #expect(try first.count("item") == 1)
        }

        let relaunched = try await Store.make(root: root)

        #expect(relaunched.names(in: root.appendingPathComponent("tmp")) == [])
        #expect(try relaunched.count("item") == 1)
        #expect(try relaunched.presentIds() == [1])
        #expect(relaunched.contents(relaunched.blobURL(1, 1)) == "blob-1-1")
    }

    /// OC-7003. Given the data folder is created, when the backup-exclusion flag is read (tmutil isexcluded cannot be
    /// used: it reports everything under the system temp directory as Excluded), then thumbs/ is excluded and
    /// flotsam.sqlite and blobs/ are not.
    @Test("OC-7003 only the regenerable thumbnails are excluded from backups")
    func oc7003_backupExclusion() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }

        let thumbs = try isExcludedFromBackup(s.thumbsDir)
        let database = try isExcludedFromBackup(s.root.appendingPathComponent("flotsam.sqlite"))
        let blobs = try isExcludedFromBackup(s.blobsDir)

        #expect(thumbs == true)
        #expect(database == false)
        #expect(blobs == false)
    }
}
