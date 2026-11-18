import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// FR-002-16: symbolic links and files resolving outside the watched folder are never read.
@Suite struct ScreenshotPathGuardTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    private func importer(_ recorder: IngestRecorder) -> ScreenshotImporter {
        let fileSystem = LocalFileSystem()
        return ScreenshotImporter(
            fileSystem: fileSystem, stability: StabilityCheck(fileSystem: fileSystem, clock: ManualClock()), ingest: recorder)
    }

    private func run(_ importer: ScreenshotImporter, _ url: URL) async -> ScreenshotImportAttempt {
        let info = LocalFileSystem().fileInfo(at: url)
        let file = ScreenshotFile(url: url, createdAt: info?.modifiedAt ?? Date(), byteSize: info?.byteSize ?? 0)
        return await importer.run(file, countsAsCopy: true)
    }

    @Test("a regular file in the watched folder is imported")
    func regularFileImports() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let url = try temp.file("shots/Screenshot 1.png")
        let recorder = IngestRecorder()
        let attempt = await run(importer(recorder), url)
        guard case .imported = attempt else { Issue.record("expected imported, got \(attempt)"); return }
        #expect(recorder.names == ["Screenshot 1.png"])
    }

    @Test("a symlink to a file inside the same folder is rejected and never read")
    func symlinkInsideFolderRejected() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let target = try temp.file("shots/Screenshot real.png")
        let link = temp.root.appendingPathComponent("shots/Screenshot link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let recorder = IngestRecorder()
        let attempt = await run(importer(recorder), link)
        guard case .rejected(let error, _) = attempt else { Issue.record("expected rejected, got \(attempt)"); return }
        #expect(error.code == .sspVal001)
        #expect(recorder.candidates.isEmpty)
    }

    @Test("a symlink to a file outside the watched folder is rejected and never read")
    func symlinkOutsideFolderRejected() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let secret = try temp.file("elsewhere/secret.png")
        try temp.folder("shots")
        let link = temp.root.appendingPathComponent("shots/Screenshot link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let recorder = IngestRecorder()
        let attempt = await run(importer(recorder), link)
        guard case .rejected(let error, _) = attempt else { Issue.record("expected rejected, got \(attempt)"); return }
        #expect(error.code == .sspVal001)
        #expect(recorder.candidates.isEmpty)
    }

    @Test("a relative symlink climbing out of the folder is rejected")
    func relativeEscapeRejected() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        try temp.file("secret.png")
        try temp.folder("shots")
        let link = temp.root.appendingPathComponent("shots/Screenshot up.png")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../secret.png")
        let recorder = IngestRecorder()
        let attempt = await run(importer(recorder), link)
        guard case .rejected = attempt else { Issue.record("expected rejected, got \(attempt)"); return }
        #expect(recorder.candidates.isEmpty)
    }

    @Test("the guard rejects a path that resolves outside the folder it names, even when its kind reads as regular")
    func resolvedPathLeavesFolder() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let outside = try temp.file("elsewhere/other.png")
        try temp.folder("shots")
        let link = temp.root.appendingPathComponent("shots/Screenshot x.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!ScreenshotPathGuard.accepts(link, kind: .regular))
        #expect(!ScreenshotPathGuard.accepts(link, kind: .symbolicLink))
        #expect(ScreenshotPathGuard.accepts(outside, kind: .regular))
        #expect(!ScreenshotPathGuard.accepts(outside, kind: .directory))
    }

    @Test("the scanner lists a regular screenshot and drops both kinds of link")
    func scannerDropsLinks() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        let real = try temp.file("shots/Screenshot real.png", screenCapture: true)
        let outside = try temp.file("elsewhere/Screenshot out.png", screenCapture: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("Screenshot inner.png"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("Screenshot outer.png"), withDestinationURL: outside)
        let scanner = ScreenshotFolderScanner(fileSystem: LocalFileSystem(), preferences: FixedPreferences())
        let names = try scanner.scan(folder).get().map(\.url.lastPathComponent)
        #expect(names == ["Screenshot real.png"])
    }

    // OC-421-W1 (AC-002-13 negative control): red if the guard compares against an unresolved folder and so rejects
    // real files when the watched folder itself is reached through a link (e.g. a relocated Desktop).
    @Test("a regular file is still accepted when the watched folder is itself reached through a link")
    func linkedWatchedFolderStillWorks() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.folder("realshots")
        _ = try temp.file("realshots/Screenshot 1.png", screenCapture: true)
        let viaLink = temp.root.appendingPathComponent("linkedshots")
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: real)
        let scanner = ScreenshotFolderScanner(fileSystem: LocalFileSystem(), preferences: FixedPreferences())
        // Single-path candidate (the FSEvents route): FileManager cannot list a link-to-folder, but events name files.
        let file = try #require(scanner.candidate(viaLink.appendingPathComponent("Screenshot 1.png")))
        #expect(file.url.lastPathComponent == "Screenshot 1.png")
        let recorder = IngestRecorder()
        let attempt = await run(importer(recorder), file.url)
        guard case .imported = attempt else { Issue.record("expected imported, got \(attempt)"); return }
        #expect(recorder.names == ["Screenshot 1.png"])
    }

    // OC-421-W2 (AC-002-13 negative): a link to a directory and a dangling link are dropped by the scan; red if the
    // scanner ever follows links when listing.
    @Test("the scanner drops a link to a folder and a dangling link")
    func scannerDropsDirectoryAndDanglingLinks() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        let dir = try temp.folder("elsewhere")
        _ = try temp.file("shots/Screenshot real.png", screenCapture: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("Screenshot dir.png"), withDestinationURL: dir)
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("Screenshot dangling.png").path, withDestinationPath: "/nonexistent-flotsam-target.png")
        let scanner = ScreenshotFolderScanner(fileSystem: LocalFileSystem(), preferences: FixedPreferences())
        let names = try scanner.scan(folder).get().map(\.url.lastPathComponent)
        #expect(names == ["Screenshot real.png"])
    }

    // TASK-428: FileManager refuses to list a link-to-folder ("Not a directory"), so a watched folder reached through
    // a link (a relocated Desktop, an override folder) failed its whole scan. The root is resolved once, then listed.
    @Test("TASK-428: scanning a watched folder that is itself a symlink lists its files")
    func symlinkedRootIsScanned() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.folder("realshots")
        _ = try temp.file("realshots/Screenshot 1.png", screenCapture: true)
        let viaLink = temp.root.appendingPathComponent("linkedshots")
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: real)
        let scanner = ScreenshotFolderScanner(fileSystem: LocalFileSystem(), preferences: FixedPreferences())
        let files = try scanner.scan(viaLink).get()
        #expect(files.map(\.url.lastPathComponent) == ["Screenshot 1.png"])
        // Files keep the folder's own path form, so seen/pending keys agree with FSEvents candidates.
        #expect(files.first?.url.deletingLastPathComponent().path == viaLink.path)
    }

    @Test("TASK-428: through a symlinked root, links inside the folder are still dropped")
    func symlinkedRootStillDropsInnerLinks() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.folder("realshots")
        let target = try temp.file("realshots/Screenshot real.png", screenCapture: true)
        let outside = try temp.file("elsewhere/Screenshot out.png", screenCapture: true)
        try FileManager.default.createSymbolicLink(
            at: real.appendingPathComponent("Screenshot inner.png"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: real.appendingPathComponent("Screenshot outer.png"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            atPath: real.appendingPathComponent("Screenshot dotdot.png").path, withDestinationPath: "../elsewhere/Screenshot out.png")
        let viaLink = temp.root.appendingPathComponent("linkedshots")
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: real)
        let scanner = ScreenshotFolderScanner(fileSystem: LocalFileSystem(), preferences: FixedPreferences())
        let names = try scanner.scan(viaLink).get().map(\.url.lastPathComponent)
        #expect(names == ["Screenshot real.png"])
    }

    @Test("TASK-428: a symlinked root does not make a file that escapes it importable")
    func symlinkedRootEscapeRejectedByImporter() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.folder("realshots")
        let outside = try temp.file("elsewhere/Screenshot out.png", screenCapture: true)
        let viaLink = temp.root.appendingPathComponent("linkedshots")
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: real)
        let escape = viaLink.appendingPathComponent("Screenshot escape.png")
        try FileManager.default.createSymbolicLink(atPath: escape.path, withDestinationPath: "../elsewhere/Screenshot out.png")
        #expect(FileManager.default.fileExists(atPath: outside.path))
        let recorder = IngestRecorder()
        let attempt = await run(importer(recorder), escape)
        guard case .rejected(let error, _) = attempt else { Issue.record("expected rejected, got \(attempt)"); return }
        #expect(error.code == .sspVal001)
        #expect(recorder.candidates.isEmpty)
    }
}
