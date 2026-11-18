import Foundation
import Testing
@testable import FlotsamBase

// TASK-397 blind verification (Worf). FileMemberLocator is the single home of "does this member still exist".
// Real files, real bookmarks, the real LocalFileSystem. Expected values are literals.

@Suite struct Worf397FileMemberLocatorTests {
    private let root: URL
    private let files = LocalFileSystem()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("worf397-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func touch(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    // Red if the bookmark is ignored: the stored path is gone after a rename, only the bookmark knows the new place.
    @Test("OC-397-L1 a renamed file is found at its new path through the bookmark")
    func followsRename() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try touch("old.txt")
        let bookmark = try old.bookmarkData()
        let renamed = root.appendingPathComponent("new.txt")
        try FileManager.default.moveItem(at: old, to: renamed)

        let found = FileMemberLocator.currentURL(path: old.path, bookmark: bookmark, isDirectory: false, files: files)

        #expect(found?.lastPathComponent == "new.txt")
    }

    // Red if the stored path is dropped when a bookmark is present but unresolvable.
    @Test("OC-397-L2 a bookmark that no longer resolves falls back to the stored path")
    func fallsBackToPath() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try touch("again.txt")
        let bookmark = try file.bookmarkData()
        try FileManager.default.removeItem(at: file)
        try Data("recreated".utf8).write(to: file)

        let found = FileMemberLocator.currentURL(path: file.path, bookmark: bookmark, isDirectory: false, files: files)

        #expect(found?.lastPathComponent == "again.txt")
    }

    // Red if undecodable bookmark bytes crash or short-circuit to "exists" rather than falling through to the path.
    @Test("OC-397-L3 garbage bookmark bytes are ignored: existing path found, missing path nil")
    func garbageBookmark() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try touch("real.txt")
        let junk = Data([0x00, 0x01, 0x02, 0xFF])

        let present = FileMemberLocator.currentURL(path: file.path, bookmark: junk, isDirectory: false, files: files)
        let absent = FileMemberLocator.currentURL(path: root.appendingPathComponent("nope").path, bookmark: junk, isDirectory: false, files: files)

        #expect(present?.lastPathComponent == "real.txt")
        #expect(absent == nil)
    }

    // Red if both are gone yet a URL is still returned.
    @Test("OC-397-L4 nothing at the bookmark or the path is nil")
    func bothGone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try touch("vanish.txt")
        let bookmark = try file.bookmarkData()
        try FileManager.default.removeItem(at: file)

        #expect(FileMemberLocator.currentURL(path: file.path, bookmark: bookmark, isDirectory: false, files: files) == nil)
    }

    // Red if the candidate order is swapped (stored path before bookmark): a moved file's bookmark place is probed
    // first. (macOS itself resolves a bookmark to the original path when a different file sits there, so the order,
    // not a "different path" outcome, is the observable contract.)
    @Test("OC-397-L5 the bookmark's location is probed before the stored path")
    func bookmarkProbedFirst() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try touch("a.txt")
        let bookmark = try old.bookmarkData()
        try FileManager.default.moveItem(at: old, to: root.appendingPathComponent("b.txt"))
        let spy = ProbeOrderFileSystem()

        let found = FileMemberLocator.currentURL(path: old.path, bookmark: bookmark, isDirectory: false, files: spy)

        #expect(found?.lastPathComponent == "b.txt")
        #expect(spy.probed.map(\.lastPathComponent) == ["b.txt"])
    }

    // Red if the stored path is probed even though the bookmark already found the file (wasted I/O on a slow volume),
    // or if the stored path is probed first.
    @Test("OC-397-L8 with no bookmark only the stored path is probed, once")
    func noBookmarkOneProbe() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try touch("solo.txt")
        let spy = ProbeOrderFileSystem()

        _ = FileMemberLocator.currentURL(path: file.path, bookmark: nil, isDirectory: false, files: spy)

        #expect(spy.probed.map(\.lastPathComponent) == ["solo.txt"])
    }

    // Red if a folder is probed as a file (isDirectory is carried into the URL).
    @Test("OC-397-L6 a directory member is found")
    func directory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(FileMemberLocator.currentURL(path: dir.path, bookmark: nil, isDirectory: true, files: files)?.lastPathComponent == "Folder")
    }

    // Red if referencesFiles is widened or narrowed.
    @Test("OC-397-L7 referencesFiles is true for exactly file, folder and bundle")
    func referencesFilesSet() {
        let names = ItemKind.allCases.filter(\.referencesFiles).map(\.rawValue).sorted()
        #expect(names == ["bundle", "file", "folder"])
    }
}

private final class ProbeOrderFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var urls: [URL] = []
    var probed: [URL] { lock.withLock { urls } }
    func fileExists(at url: URL) -> Bool { lock.withLock { urls.append(url) }; return real.fileExists(at: url) }
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
