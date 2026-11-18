import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// Worf blind tests for TASK-428 (FR-002-16, AC-002-13, AC-002-14). Written against the FRD, not the implementer's tests.
// Expected values are literals; the real file system and real symlinks are used throughout.

/// The local file system with two hooks, so a file can be swapped for a link at a chosen moment between the
/// importer's checks and its read (the TOCTOU window of FR-002-16).
private final class SwappingFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var infoCalls = 0
    /// Runs after the Nth `fileInfo` call (1-based) has returned its answer.
    var afterInfoCall: (Int, @Sendable () -> Void)?
    /// Runs just before the real read.
    var beforeRead: (@Sendable () -> Void)?

    func fileInfo(at url: URL) -> FileInfo? {
        let result = real.fileInfo(at: url)
        let (n, hook) = lock.withLock { () -> (Int, (@Sendable () -> Void)?) in
            infoCalls += 1
            let match = afterInfoCall.flatMap { $0.0 == infoCalls ? $0.1 : nil }
            return (infoCalls, match)
        }
        _ = n
        hook?()
        return result
    }
    func readFile(at url: URL) -> FlotsamResult<Data> {
        beforeRead?()
        return real.readFile(at: url)
    }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { real.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { real.writeFile(data, to: url, permissions: permissions) }
    func availableCapacity(at url: URL) -> Int64? { real.availableCapacity(at: url) }
}

@Suite struct ScreenshotPathGuardAdversarialTests {
    private let scanner = ScreenshotFolderScanner(fileSystem: LocalFileSystem(), preferences: FixedPreferences())
    private let secretBytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01])

    private func names(_ files: [ScreenshotFile]) -> [String] { files.map(\.url.lastPathComponent).sorted() }

    private func importer(_ recorder: IngestRecorder, fileSystem: any FileSystemPort = LocalFileSystem()) -> ScreenshotImporter {
        ScreenshotImporter(
            fileSystem: fileSystem, stability: StabilityCheck(fileSystem: fileSystem, clock: ManualClock()), ingest: recorder)
    }

    private func file(_ url: URL, in folder: URL) -> ScreenshotFile {
        ScreenshotFile(url: url, folder: folder, createdAt: Date(), byteSize: 4)
    }

    private func link(_ at: URL, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: at.path, withDestinationPath: destination)
    }

    // MARK: `..` and nesting

    // OC-428-W1: red if the guard stops rejecting a `..` component (a path that exists and resolves into the folder
    // under another name) or the scanner stops dropping it. Count delta: the listing holds exactly the one direct file.
    @Test("a path with a .. component is never a candidate, though it exists and names a real file")
    func dotDotComponentNeverCandidate() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        _ = try temp.file("shots/Screenshot direct.png", screenCapture: true)
        _ = try temp.file("shots/sub/Screenshot deep.png", screenCapture: true)
        let viaSub = folder.appendingPathComponent("sub/../Screenshot direct.png")
        let viaSelf = folder.appendingPathComponent("../shots/Screenshot direct.png")
        #expect(FileManager.default.fileExists(atPath: viaSub.path))
        #expect(scanner.candidate(viaSub, in: folder) == nil)
        #expect(scanner.candidate(viaSelf, in: folder) == nil)
        #expect(names(try scanner.scan(folder).get()) == ["Screenshot direct.png"])
    }

    // OC-428-W2: red if the importer leans on the scan: a ScreenshotFile with a `..` url must be rejected with SSP-VAL-001
    // and nothing ingested.
    @Test("the importer rejects a .. url with SSP-VAL-001 and ingests nothing")
    func importerRejectsDotDot() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        _ = try temp.file("shots/Screenshot direct.png")
        let recorder = IngestRecorder()
        let url = folder.appendingPathComponent("sub/../Screenshot direct.png")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let attempt = await importer(recorder).run(file(url, in: folder), countsAsCopy: true)
        guard case .rejected(let error, _) = attempt else { Issue.record("expected rejected, got \(attempt)"); return }
        #expect(error.code == .sspVal001)
        #expect(recorder.candidates.count == 0)
    }

    // OC-428-W3: red if the scan recurses or a descendant slips through candidate(). Boundary: 0 nested files listed
    // of 3 present; the directory named like a screenshot is dropped too.
    @Test("nested subfolders: no descendant is listed, at depth 1, 2, or as a folder named like a screenshot")
    func nestedSubfoldersNeverListed() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        _ = try temp.file("shots/Screenshot top.png", screenCapture: true)
        let one = try temp.file("shots/a/Screenshot one.png", screenCapture: true)
        let two = try temp.file("shots/a/b/Screenshot two.png", screenCapture: true)
        try temp.folder("shots/Screenshot folder.png")
        #expect(names(try scanner.scan(folder).get()) == ["Screenshot top.png"])
        #expect(scanner.candidate(one, in: folder) == nil)
        #expect(scanner.candidate(two, in: folder) == nil)
        #expect(!ScreenshotPathGuard.accepts(folder.appendingPathComponent("Screenshot folder.png"), kind: .directory, in: folder))
    }

    // OC-428-W4: a file one level above the folder is not a child (sibling with the same parent as the folder).
    @Test("a screenshot in the folder's parent or a sibling folder is not a candidate")
    func parentAndSiblingRejected() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        let parentFile = try temp.file("Screenshot parent.png", screenCapture: true)
        let sibling = try temp.file("shots2/Screenshot sib.png", screenCapture: true)
        // "shots2" shares the string prefix "shots": a prefix comparison would let it through.
        #expect(scanner.candidate(parentFile, in: folder) == nil)
        #expect(scanner.candidate(sibling, in: folder) == nil)
        #expect(!ScreenshotPathGuard.accepts(sibling, kind: .regular, in: folder))
    }

    // MARK: symlinked root

    // OC-428-W5 (AC-002-14): red if a link-to-folder root fails to list. Both names of the same folder list the same file.
    @Test("AC-002-14: a root named via the link and via the real path both list the one real file")
    func rootViaLinkAndViaRealPath() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.folder("real")
        _ = try temp.file("real/Screenshot 1.png", screenCapture: true)
        let viaLink = temp.root.appendingPathComponent("Desktop")
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: real)
        #expect(names(try scanner.scan(viaLink).get()) == ["Screenshot 1.png"])
        #expect(names(try scanner.scan(real).get()) == ["Screenshot 1.png"])
    }

    // OC-428-W6: a chain of links (a -> b -> real) must resolve fully; red if only one hop is followed.
    @Test("AC-002-14: a root that is a chain of two links is listed")
    func rootChainOfLinks() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.folder("real")
        _ = try temp.file("real/Screenshot 1.png", screenCapture: true)
        let hop2 = temp.root.appendingPathComponent("hop2")
        let hop1 = temp.root.appendingPathComponent("hop1")
        try link(hop2, to: real.path)
        try link(hop1, to: "hop2")
        let files = try scanner.scan(hop1).get()
        #expect(names(files) == ["Screenshot 1.png"])
        #expect(files.count == 1)
    }

    // OC-428-W7: the importer imports a file in a linked root, whichever way the file and folder are named (4 pairings).
    @Test("AC-002-14: the importer imports a direct child for every naming of file and folder through a linked root")
    func importerAllNamingPairs() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.folder("real")
        _ = try temp.file("real/Screenshot 1.png", bytes: Data([1, 2, 3, 4, 5, 6]))
        let viaLink = temp.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: real)
        let pairs: [(URL, URL)] = [
            (real.appendingPathComponent("Screenshot 1.png"), real),
            (real.appendingPathComponent("Screenshot 1.png"), viaLink),
            (viaLink.appendingPathComponent("Screenshot 1.png"), real),
            (viaLink.appendingPathComponent("Screenshot 1.png"), viaLink),
        ]
        for (url, folder) in pairs {
            let recorder = IngestRecorder()
            let attempt = await importer(recorder).run(file(url, in: folder), countsAsCopy: true)
            guard case .imported(_, let size) = attempt else { Issue.record("expected imported for \(url.path) in \(folder.path), got \(attempt)"); continue }
            #expect(size == 6)
            #expect(recorder.names == ["Screenshot 1.png"])
        }
    }

    // OC-428-W8: the folder reached through the system's own /var -> /private/var link (the form Foundation's
    // temporaryDirectory returns, unresolved) is the commonest linked root; red if the guard mishandles it.
    @Test("AC-002-14: an unresolved /var path (itself behind a system link) lists and imports its file")
    func systemLinkedRoot() async throws {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotsam-w8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unresolved) }
        let url = unresolved.appendingPathComponent("Screenshot 1.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        try TempFolder.setScreenCaptureAttribute(true, on: url)
        #expect(names(try scanner.scan(unresolved).get()) == ["Screenshot 1.png"])
        let recorder = IngestRecorder()
        let attempt = await importer(recorder).run(file(url, in: unresolved), countsAsCopy: true)
        guard case .imported = attempt else { Issue.record("expected imported, got \(attempt)"); return }
    }

    // MARK: child links

    // OC-428-W9 (AC-002-13): every flavour of escaping child is dropped by the scan and, if handed to the importer
    // anyway, rejected without a read. The secret's bytes must never reach the recorder (identity, not just count).
    @Test("AC-002-13: child links to outside (absolute, relative, to a folder, via ../) are dropped and never read")
    func childLinksOutsideNeverRead() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        let good = try temp.file("shots/Screenshot good.png", screenCapture: true)
        let secret = try temp.file("outside/Screenshot secret.png", bytes: secretBytes, screenCapture: true)
        let outsideDir = try temp.folder("outside/dir")
        let links: [(String, String)] = [
            ("Screenshot abs.png", secret.path),
            ("Screenshot rel.png", "../outside/Screenshot secret.png"),
            ("Screenshot dir.png", outsideDir.path),
            ("Screenshot deep.png", "../shots/../outside/Screenshot secret.png"),
        ]
        for (name, target) in links { try link(folder.appendingPathComponent(name), to: target) }
        #expect(names(try scanner.scan(folder).get()) == ["Screenshot good.png"])
        for (name, _) in links {
            let recorder = IngestRecorder()
            let attempt = await importer(recorder).run(file(folder.appendingPathComponent(name), in: folder), countsAsCopy: true)
            guard case .rejected(let error, _) = attempt else { Issue.record("\(name): expected rejected, got \(attempt)"); continue }
            #expect(error.code == .sspVal001)
            #expect(recorder.candidates.count == 0)
        }
        #expect(FileManager.default.fileExists(atPath: good.path))
    }

    // OC-428-W10: a link inside the folder to a SIBLING file inside the folder: also dropped (FR-002-16: "whatever the
    // link points at"). Survivor identity: the real target is the one listed, once.
    @Test("a link to another file in the same folder is dropped; the target itself survives exactly once")
    func inFolderLinkDroppedTargetSurvives() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        _ = try temp.file("shots/Screenshot real.png", screenCapture: true)
        try link(folder.appendingPathComponent("Screenshot alias.png"), to: "Screenshot real.png")
        let files = try scanner.scan(folder).get()
        #expect(files.count == 1)
        #expect(files.first?.url.lastPathComponent == "Screenshot real.png")
    }

    // OC-428-W11 (AC-002-14 + AC-002-13 together): a linked root with an escaping child link inside: the real file is
    // listed, the link is not, and importing the link reads nothing.
    @Test("a linked root with an escaping child: real file listed, child link dropped and unreadable")
    func linkedRootWithEscapingChild() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.folder("real")
        _ = try temp.file("real/Screenshot ok.png", screenCapture: true)
        let secret = try temp.file("outside/Screenshot secret.png", bytes: secretBytes, screenCapture: true)
        try link(real.appendingPathComponent("Screenshot leak.png"), to: secret.path)
        let viaLink = temp.root.appendingPathComponent("Desktop")
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: real)
        #expect(names(try scanner.scan(viaLink).get()) == ["Screenshot ok.png"])
        let recorder = IngestRecorder()
        let attempt = await importer(recorder).run(file(viaLink.appendingPathComponent("Screenshot leak.png"), in: viaLink), countsAsCopy: true)
        guard case .rejected(let error, _) = attempt else { Issue.record("expected rejected, got \(attempt)"); return }
        #expect(error.code == .sspVal001)
        #expect(recorder.candidates.count == 0)
    }

    // MARK: loops, dangling, special files

    // OC-428-W12: self-link, two-link cycle and a self-loop folder are dropped silently, never hang or throw.
    @Test("a self-link and a two-link cycle are dropped by the scan and rejected by the importer")
    func symlinkLoops() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        _ = try temp.file("shots/Screenshot ok.png", screenCapture: true)
        try link(folder.appendingPathComponent("Screenshot self.png"), to: "Screenshot self.png")
        try link(folder.appendingPathComponent("Screenshot a.png"), to: "Screenshot b.png")
        try link(folder.appendingPathComponent("Screenshot b.png"), to: "Screenshot a.png")
        #expect(names(try scanner.scan(folder).get()) == ["Screenshot ok.png"])
        for name in ["Screenshot self.png", "Screenshot a.png", "Screenshot b.png"] {
            let recorder = IngestRecorder()
            let attempt = await importer(recorder).run(file(folder.appendingPathComponent(name), in: folder), countsAsCopy: true)
            guard case .rejected(let error, _) = attempt else { Issue.record("\(name): expected rejected, got \(attempt)"); continue }
            #expect(error.code == .sspVal001)
            #expect(recorder.candidates.count == 0)
        }
    }

    // OC-428-W13: a watched folder that is itself a loop returns a failure result (caller maps it), no crash, no files.
    @Test("a watched folder that is a link loop fails the listing without crashing")
    func rootLinkLoop() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let a = temp.root.appendingPathComponent("loopA")
        let b = temp.root.appendingPathComponent("loopB")
        try link(a, to: b.path)
        try link(b, to: a.path)
        switch scanner.scan(a) {
        case .success(let files): #expect(files.count == 0, "a loop root must not list files")
        case .failure(let error): #expect(error.code == .sysInt001)
        }
    }

    // OC-428-W14: dangling link, alone and as the importer's input.
    @Test("a dangling link is dropped by the scan and rejected by the importer, not retried")
    func danglingLink() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        _ = try temp.file("shots/Screenshot ok.png", screenCapture: true)
        let dangling = folder.appendingPathComponent("Screenshot dangling.png")
        try link(dangling, to: "nowhere-428.png")
        #expect(names(try scanner.scan(folder).get()) == ["Screenshot ok.png"])
        let recorder = IngestRecorder()
        let attempt = await importer(recorder).run(file(dangling, in: folder), countsAsCopy: true)
        guard case .rejected(let error, _) = attempt else { Issue.record("expected rejected (never retried), got \(attempt)"); return }
        #expect(error.code == .sspVal001)
        #expect(recorder.candidates.count == 0)
    }

    // OC-428-W15: a FIFO named like a screenshot is "other", never listed, never opened (a read would block forever).
    @Test("a named pipe with a screenshot name is dropped")
    func fifoDropped() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        _ = try temp.file("shots/Screenshot ok.png", screenCapture: true)
        #expect(mkfifo(folder.appendingPathComponent("Screenshot fifo.png").path, 0o644) == 0)
        #expect(names(try scanner.scan(folder).get()) == ["Screenshot ok.png"])
    }

    // MARK: root spelling

    // OC-428-W16: trailing slash on the root, plain and linked. Red if URL equality trips on "…/shots/" vs "…/shots".
    @Test("a root with a trailing slash lists, accepts and imports its files, plain and linked")
    func trailingSlashRoot() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.folder("real")
        let url = try temp.file("real/Screenshot 1.png", screenCapture: true)
        let viaLink = temp.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: real)
        for path in [real.path + "/", viaLink.path + "/", real.path + "//"] {
            let slashed = URL(fileURLWithPath: path, isDirectory: true)
            #expect(names(try scanner.scan(slashed).get()) == ["Screenshot 1.png"], "scan of \(path)")
            #expect(ScreenshotPathGuard.accepts(url, kind: .regular, in: slashed), "guard with root \(path)")
            #expect(scanner.candidate(url, in: slashed) != nil, "candidate in root \(path)")
            let recorder = IngestRecorder()
            let attempt = await importer(recorder).run(file(url, in: slashed), countsAsCopy: true)
            guard case .imported = attempt else { Issue.record("root \(path): expected imported, got \(attempt)"); continue }
        }
        // negative control: the trailing slash does not widen the root to its descendants.
        let nested = try temp.file("real/sub/Screenshot 2.png", screenCapture: true)
        #expect(!ScreenshotPathGuard.accepts(nested, kind: .regular, in: URL(fileURLWithPath: real.path + "/", isDirectory: true)))
    }

    // OC-428-W17: a root spelled with a `..` detour ("real/sub/..") that lands on the same folder. The resolver
    // normalises it first, but the scanner is public: red if a `..` in the ROOT makes every file vanish silently.
    @Test("a root spelled with a .. detour still lists its direct children", .disabled("DEFECT W428-D3 (Minor): ScreenshotPathGuard rejects any url containing \"..\" even when the \"..\" is in the watched folder's own spelling, so scan(\"real/sub/..\") lists nothing. ScreenshotScan.swift:41-42"))
    func dotDotInsideRootSpelling() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.folder("real")
        _ = try temp.file("real/Screenshot 1.png", screenCapture: true)
        try temp.folder("real/sub")
        let detour = real.appendingPathComponent("sub/..", isDirectory: true)
        #expect(names(try scanner.scan(detour).get()) == ["Screenshot 1.png"])
    }

    // OC-428-W18: case variants on a case-insensitive volume. The same folder spelled "REAL" must still be "the
    // folder"; fail-closed here would silently stop pickup. Skipped where the volume is case-sensitive.
    @Test("a root spelled in a different case on a case-insensitive volume lists the same files")
    func caseVariantRoot() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.folder("realcase")
        let url = try temp.file("realcase/Screenshot 1.png", screenCapture: true)
        let upper = temp.root.appendingPathComponent("REALCASE", isDirectory: true)
        guard FileManager.default.fileExists(atPath: upper.path) else { return }  // case-sensitive volume: n/a
        #expect(real.path != upper.path)
        #expect(ScreenshotPathGuard.accepts(url, kind: .regular, in: upper))
        #expect(names(try scanner.scan(upper).get()) == ["Screenshot 1.png"])
    }

    // OC-428-W19: NFC vs NFD spelling of a folder name (APFS treats them as one folder). Same expectation as W18.
    @Test("a root spelled NFD while the file path is NFC lists the same files")
    func unicodeNormalizationRoot() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        let real = try temp.folder(nfc)
        let url = try temp.file("\(nfc)/Screenshot 1.png", screenCapture: true)
        let other = temp.root.appendingPathComponent(nfd, isDirectory: true)
        guard FileManager.default.fileExists(atPath: other.path) else { return }  // normalisation-sensitive volume: n/a
        _ = real
        #expect(ScreenshotPathGuard.accepts(url, kind: .regular, in: other))
        #expect(names(try scanner.scan(other).get()) == ["Screenshot 1.png"])
    }

    // OC-428-W20: a subfolder that is a link back to the root. A file reached as root/loop/x.png is the same file as
    // root/x.png, but the path as named is a descendant. The guard's own doc says "as named and as resolved".
    @Test("a file named through a subfolder link that points back at the root is not accepted as named", .disabled("DEFECT W428-D4 (Minor): guard resolves the named parent, so root/again/x.png (again -> root) passes though its doc says a descendant as named never passes. ScreenshotScan.swift:41-45"))
    func descendantViaSelfLinkedSubfolder() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        _ = try temp.file("shots/Screenshot 1.png", screenCapture: true)
        try link(folder.appendingPathComponent("again"), to: folder.path)
        let viaSub = folder.appendingPathComponent("again/Screenshot 1.png")
        #expect(!ScreenshotPathGuard.accepts(viaSub, kind: .regular, in: folder))
        #expect(scanner.candidate(viaSub, in: folder) == nil)
    }

    // MARK: TOCTOU through the ports

    // OC-428-W21 (AC-002-13): listed as a regular file, swapped for a link to the secret before the import starts.
    // Red if the importer trusts the scan.
    @Test("AC-002-13: a file swapped for a link after the scan is rejected with SSP-VAL-001 and no item is created")
    func swappedAfterScan() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        let url = try temp.file("shots/Screenshot 1.png", screenCapture: true)
        let secret = try temp.file("outside/secret.png", bytes: secretBytes)
        let listed = try #require(scanner.candidate(url, in: folder))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: secret)
        let recorder = IngestRecorder()
        let attempt = await importer(recorder).run(listed, countsAsCopy: true)
        guard case .rejected(let error, _) = attempt else { Issue.record("expected rejected, got \(attempt)"); return }
        #expect(error.code == .sspVal001)
        #expect(recorder.candidates.count == 0)
    }

    // OC-428-W22: same swap, link to a sibling inside the folder (the guard's resolved check cannot catch this one;
    // only the kind can).
    @Test("a file swapped for a link to a sibling in the same folder is rejected")
    func swappedForInFolderLink() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        let url = try temp.file("shots/Screenshot 1.png", screenCapture: true)
        _ = try temp.file("shots/Screenshot sibling.png", bytes: secretBytes)
        let listed = try #require(scanner.candidate(url, in: folder))
        try FileManager.default.removeItem(at: url)
        try link(url, to: "Screenshot sibling.png")
        let recorder = IngestRecorder()
        let attempt = await importer(recorder).run(listed, countsAsCopy: true)
        guard case .rejected(let error, _) = attempt else { Issue.record("expected rejected, got \(attempt)"); return }
        #expect(error.code == .sspVal001)
        #expect(recorder.candidates.count == 0)
    }

    // OC-428-W23: the swap lands AFTER the stability check's last look but before the guard: the guard is handed a
    // stale `.regular` kind, so only its path check stands between a link to a sibling and a read through the link.
    @Test("a swap for an in-folder link after the stability check's last look is still rejected", .disabled("DEFECT W428-D1 (Major): guard trusts the stability check's stale FileKind; a swap to a link to a sibling after the last fileInfo is read through the link and imported. ScreenshotImporter.swift:56-68"))
    func swappedAfterStabilityBeforeGuard() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        let url = try temp.file("shots/Screenshot 1.png", screenCapture: true)
        _ = try temp.file("shots/Screenshot sibling.png", bytes: secretBytes)
        let fileSystem = SwappingFileSystem()
        fileSystem.afterInfoCall = (2, {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "Screenshot sibling.png")
        })
        let recorder = IngestRecorder()
        let listed = try #require(scanner.candidate(url, in: folder))
        let attempt = await importer(recorder, fileSystem: fileSystem).run(listed, countsAsCopy: true)
        guard case .rejected(let error, _) = attempt else { Issue.record("expected rejected, got \(attempt)"); return }
        #expect(error.code == .sspVal001)
        #expect(recorder.candidates.count == 0)
    }

    // OC-428-W24: same stale-kind swap, link pointing OUTSIDE: the guard's resolved-parent check must catch it.
    @Test("a swap for an outside link after the stability check's last look is rejected and never read")
    func swappedOutsideAfterStability() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        let url = try temp.file("shots/Screenshot 1.png", screenCapture: true)
        let secret = try temp.file("outside/secret.png", bytes: secretBytes)
        let fileSystem = SwappingFileSystem()
        fileSystem.afterInfoCall = (2, {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: secret)
        })
        let recorder = IngestRecorder()
        let listed = try #require(scanner.candidate(url, in: folder))
        let attempt = await importer(recorder, fileSystem: fileSystem).run(listed, countsAsCopy: true)
        guard case .rejected(let error, _) = attempt else { Issue.record("expected rejected, got \(attempt)"); return }
        #expect(error.code == .sspVal001)
        #expect(recorder.candidates.count == 0)
    }

    // OC-428-W25: the swap lands between the guard and the read (the guard has already said yes). A link followed by
    // the read leaks the outside file's bytes into ingest.
    @Test("a swap for an outside link between the guard and the read does not leak the target's bytes", .disabled("DEFECT W428-D2 (Major): guard and read are separate steps and readFile follows links (Data(contentsOf:)); a swap in between leaks the outside file into ingest. ScreenshotImporter.swift:61-68, Adapters.swift readFile"))
    func swappedBetweenGuardAndRead() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("shots")
        let url = try temp.file("shots/Screenshot 1.png", screenCapture: true)
        let secret = try temp.file("outside/secret.png", bytes: secretBytes)
        let fileSystem = SwappingFileSystem()
        fileSystem.beforeRead = {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: secret)
        }
        let recorder = IngestRecorder()
        let listed = try #require(scanner.candidate(url, in: folder))
        _ = await importer(recorder, fileSystem: fileSystem).run(listed, countsAsCopy: true)
        let leaked = recorder.candidates.contains { $0.representations.contains { $0.data == secretBytes } }
        #expect(!leaked, "bytes of a file outside the watched folder reached ingest")
    }
}
