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
}
