import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import FlotsamBase
import FlotsamPayload
@testable import FlotsamScreenshots
@testable import FlotsamStorage

// FRD-002 pipeline contract tests (screenshot pickup through the real ingest pipeline).
//
// Real: ScreenshotWatcher, IngestActor, FlotsamDatabase in a temp folder, LocalFileSystem, real PNG files with real
// extended attributes and birth dates, ErrorReporter. Fakes sit only on the ports: the folder event source, the clock,
// `com.apple.screencapture` preferences, the settings key-value store, the error presenter and the log sink.
// Persistence is always read through a FRESH `FlotsamDatabase.open`, never an in-memory list.
//
// Every helper here is private and prefixed `Pipeline` so it cannot collide with another suite in this target.

// MARK: - Fixtures

/// A screenshot file as the test wrote it, with what the contract compares afterwards.
private struct PipelineShot {
    let url: URL
    let bytes: Data
    let sha: String
    let width: Int
    let height: Int
    let born: Date
    var name: String { url.lastPathComponent }
}

private func pipelineSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func pipelineSHA256(ofFileAt url: URL) -> String? {
    (try? Data(contentsOf: url)).map(pipelineSHA256)
}

/// A PNG whose pixels are unique to this call (a random seed runs through every pixel), so no two files share a content key.
private func pipelinePNG(width: Int, height: Int) -> Data {
    let seed = withUnsafeBytes(of: UUID().uuid) { Array($0) }
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in 0..<(width * height) {
        pixels[index * 4] = seed[index % 16] &+ UInt8(truncatingIfNeeded: index)
        pixels[index * 4 + 1] = seed[(index + 5) % 16] ^ UInt8(truncatingIfNeeded: index >> 3)
        pixels[index * 4 + 2] = seed[(index + 11) % 16] &+ UInt8(truncatingIfNeeded: index >> 6)
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

/// Every extended attribute of a file, name to bytes.
private func pipelineXattrs(_ url: URL) -> [String: Data] {
    let path = url.path
    let size = listxattr(path, nil, 0, 0)
    guard size > 0 else { return [:] }
    var names = [CChar](repeating: 0, count: size)
    listxattr(path, &names, size, 0)
    var result: [String: Data] = [:]
    for name in String(decoding: names.prefix(size).map { UInt8(bitPattern: $0) }, as: UTF8.self).split(separator: "\0").map(String.init) where !name.isEmpty {
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length >= 0 else { continue }
        var value = [UInt8](repeating: 0, count: length)
        getxattr(path, name, &value, length, 0, 0)
        result[name] = Data(value)
    }
    return result
}

private func pipelineModified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

/// One file as the contract compares it: "sha|modification date|xattr count".
private func pipelineSnapshot(_ url: URL) -> String {
    let sha = pipelineSHA256(ofFileAt: url) ?? "unreadable"
    return "\(sha)|\(pipelineModified(url)?.timeIntervalSince1970 ?? -1)|\(pipelineXattrs(url).count)"
}

/// A listing of a folder: file name to its snapshot, so any create, rename, edit or delete shows.
private func pipelineListing(of folder: URL) -> [String: String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return Dictionary(uniqueKeysWithValues: names.map { ($0, pipelineSnapshot(folder.appendingPathComponent($0))) })
}

/// Whole seconds, so epoch-millisecond storage round-trips exactly.
private func pipelineWhole(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

/// Polls `condition` until it holds or `seconds` pass. Work arrives through spawned tasks, so a test waits on the
/// state it expects and asserts on the returned flag.
private func pipelineEventually(seconds: Double = 20, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Everything the reporter would draw: Notice lists, newest last.
private final class PipelinePresenter: ErrorPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[Notice]] = []
    private var huds: [String] = []
    func showHUD(message: String) { lock.withLock { huds.append(message) } }
    func noticesChanged(_ notices: [Notice]) { lock.withLock { lists.append(notices) } }
    func presentFatal(_ error: FlotsamError) {}
    var latestNotices: [Notice] { lock.withLock { lists.last ?? [] } }
    var hudCount: Int { lock.withLock { huds.count } }
}

/// The real pipeline over a temp tree: watcher, ingest actor, database and reporter wired as the app wires them.
private final class PipelineRig: @unchecked Sendable {
    let temp: TempFolder
    let home: URL
    /// W: the watched folder.
    let watched: URL
    let dataFolder: URL
    let clock = SteppedClock()
    let source = FakeFolderSource()
    let preferences = MutablePreferences()
    let pollTick = PollTick()
    let settings = SettingsStore(store: MemorySettingsBacking())
    let presenter = PipelinePresenter()
    let sink = WatcherLogSink()
    private(set) var database: FlotsamDatabase!
    private(set) var watcher: ScreenshotWatcher!
    private(set) var reporter: ErrorReporter!

    init() throws {
        temp = try TempFolder()
        home = try temp.folder("home")
        watched = try temp.folder("home/Shots")
        dataFolder = temp.root.appendingPathComponent("data", isDirectory: true)
        preferences.set(location: watched.path)
    }

    /// Opens the database (first launch) or a fresh instance on the same folder (relaunch), builds a new watcher over it
    /// and starts it. `watermark` is written first, as a previous run would have left it.
    func launch(watermark: Date? = nil) async throws {
        try await openDatabase(watermark: watermark)
        await startWatcher()
    }

    /// The database alone, so a test can seed items before pickup starts.
    func openDatabase(watermark: Date? = nil) async throws {
        // The database shares the rig's clock: the watcher's sleeps advance it past real time, and Clear History's
        // `lastCopiedAt <= now` bound would otherwise skip every item born in the database's "future".
        database = try await FlotsamDatabase.open(folder: dataFolder, clock: clock, logSink: sink).get()
        if let watermark {
            _ = await DatabaseWatermarkStore(database: database).setLastScanAt(watermark)
        }
    }

    func startWatcher() async {
        let database = self.database!
        let reporter = ErrorReporter(presenter: presenter, sink: sink)
        self.reporter = reporter
        watcher = ScreenshotWatcher(
            fileSystem: LocalFileSystem(), preferences: preferences, home: home, clock: clock, eventSource: source,
            settings: settings, ingest: IngestActor(database: database, settings: settings),
            watermarkStore: DatabaseWatermarkStore(database: database),
            report: { error in await reporter.report(error, origin: .background) },
            clear: { code in await reporter.clearNotices(code: code) }, pollTick: pollTick, sink: sink)
        await watcher.start()
    }

    /// A clipboard-origin image item (kind `image`) with exactly these bytes, as capture would store it.
    @discardableResult
    func seedClipboardImage(_ bytes: Data, at date: Date) async throws -> IngestResult {
        let candidate = IngestCandidate(
            kind: .image, contentKey: ContentKey.image(bytes),
            representations: [PasteboardRepresentation(uti: "public.png", data: bytes)], origin: .pasteboard,
            occurredAt: date)
        return try await IngestActor(database: database, settings: settings).ingest(candidate).get()
    }

    /// Quit: pickup stops, the database instance is dropped. Everything durable is on disk.
    func quit() async {
        settings.set(false, for: SettingKeys.screenshotsEnabled)
        await watcher.settingsDidChange()
        settings.set(true, for: SettingKeys.screenshotsEnabled)
        watcher = nil
        database = nil
    }

    /// Quit then launch again over the same data folder.
    func relaunch() async throws {
        await quit()
        try await launch()
    }

    /// A fresh database instance on the data folder: what the Library shows after a relaunch.
    func fresh() async throws -> FlotsamDatabase {
        try await FlotsamDatabase.open(folder: dataFolder).get()
    }

    func cleanUp() {
        if let walker = FileManager.default.enumerator(at: temp.root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        temp.cleanUp()
    }

    /// A system-style screenshot in W: a real PNG, unique pixels, the screen-capture attribute, born at `born`.
    @discardableResult
    func shot(
        _ name: String = "Screenshot oc-\(UUID().uuidString).png", width: Int = 41, height: Int = 29, born: Date? = nil,
        in folder: URL? = nil, bytes fixed: Data? = nil
    ) throws -> PipelineShot {
        let bytes = fixed ?? pipelinePNG(width: width, height: height)
        let url = (folder ?? watched).appendingPathComponent(name)
        try bytes.write(to: url)
        try TempFolder.setScreenCaptureAttribute(true, on: url)
        let birth = pipelineWhole(born ?? clock.now())
        try FileManager.default.setAttributes([.creationDate: birth], ofItemAtPath: url.path)
        return PipelineShot(url: url, bytes: bytes, sha: pipelineSHA256(bytes), width: width, height: height, born: birth)
    }

    func event(_ url: URL) { source.emit(.changed([url])) }

    /// One 30 s tick, finished.
    func tick() async {
        clock.advance(by: ScreenshotWatcher.tickInterval)
        await watcher.tickFired()
    }

    func count(_ filter: LibraryFilter = .all, text: String = "") async -> Int {
        (try? await database.count(filter: filter, text: text).get()) ?? -1
    }

    func rows(_ query: LibraryQuery = LibraryQuery()) async -> [ItemRow] {
        (try? await database.items(matching: query).get().rows) ?? []
    }

    func waitForCount(_ expected: Int) async -> Bool { await pipelineEventually { await count() == expected } }

    /// Rows read through a fresh instance.
    func freshRows(_ query: LibraryQuery = LibraryQuery()) async throws -> [ItemRow] {
        try await fresh().items(matching: query).get().rows
    }

    func freshCount() async throws -> Int { try await fresh().count(filter: .all).get() }

    /// The state every contract starts from: pickup on, mode Active, W resolved and listable, running, with a watermark
    /// from "a moment ago" so a file added now is newer than it.
    func running() async throws {
        try await launch(watermark: clock.now().addingTimeInterval(-3_600))
    }
}

// MARK: - Batch 1: deletion and persistence (OC-2038, 2043, 2044, 2052, 2053)

@Suite("FRD002Pipeline deletion and file independence")
struct FRD002PipelineDeletionTests {
    /// Imports `count` screenshots through the live event path and waits until they are all stored.
    private func importLive(_ rig: PipelineRig, _ count: Int, baseWidth: Int = 30) async throws -> [PipelineShot] {
        var shots: [PipelineShot] = []
        for index in 0..<count {
            // Distinct widths keep every screenshot's pixel size, and so its content, unique.
            let shot = try rig.shot(width: baseWidth + index)
            shots.append(shot)
            rig.event(shot.url)
            #expect(await rig.waitForCount(shots.count), "screenshot \(shots.count) never reached the Library")
        }
        return shots
    }

    @Test("OC-2052 deleting the source file leaves the item (count delta 0, same id)")
    func sourceFileDeletedItemRemains() async throws {
        // Given: one screenshot item S imported from file F, found by its stable id.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        try await rig.running()
        let shot = try await importLive(rig, 1)[0]
        let before = await rig.rows()
        #expect(before.count == 1)
        let idBefore = before[0].id
        // When: F is deleted from disk, and a 30 s tick (a reconcile scan) runs.
        try FileManager.default.removeItem(at: shot.url)
        await rig.tick()
        await letItSettle()
        // Then: S is still there with the same id, in this instance and in a fresh one.
        let after = await rig.rows()
        #expect(after.map(\.id) == [idBefore])
        let freshRows = try await rig.freshRows()
        #expect(freshRows.map(\.id) == [idBefore])
        #expect(freshRows.first?.kind == .screenshot)
    }

    @Test("OC-2043 after F is deleted and the Library reopened, S is present with the same pixel size")
    func itemSurvivesFileDeletionAcrossReopen() async throws {
        // Given: a 41 x 29 screenshot imported from file F.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        try await rig.running()
        let shot = try await importLive(rig, 1, baseWidth: 41)[0]
        let before = await rig.rows()
        #expect(before.count == 1)
        #expect(before[0].pixelWidth == 41)
        #expect(before[0].pixelHeight == 29)
        // When: F is deleted (trashed and emptied), then the Library is reopened (quit, relaunch, fresh read).
        try FileManager.default.removeItem(at: shot.url)
        try await rig.relaunch()
        await letItSettle()
        // Then: the count delta is 0, the row has the same id and pixel size, and its preview bytes are F's bytes.
        let reopened = try await rig.freshRows()
        #expect(reopened.map(\.id) == before.map(\.id))
        #expect(reopened.first?.pixelWidth == 41)
        #expect(reopened.first?.pixelHeight == 29)
        let content = try await rig.fresh().content(of: before[0].id).get()
        #expect(content.representations.count == 1)
        #expect(content.representations.first?.data == shot.bytes)
    }

    @Test("OC-2044 deleting the item removes exactly it and leaves F with the same SHA-256")
    func deletingItemLeavesFileUntouched() async throws {
        // Given: three screenshots imported; the middle one's SHA-256 recorded.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        try await rig.running()
        let shots = try await importLive(rig, 3)
        let rows = await rig.rows()
        #expect(rows.count == 3)
        let target = shots[1]
        let ids = Set(rows.map(\.id))
        let targetRow = try #require(rows.first { $0.pixelWidth == target.width && $0.pixelHeight == target.height && $0.lastCopiedAt == target.born })
        // When: S is deleted from history (command-delete: the one deletion path).
        let removed = try await rig.database.delete(ids: [targetRow.id]).get()
        // Then: count -1 by identity (the target is gone, the other two survive), F exists with the same bytes.
        #expect(removed == [targetRow.id])
        let survivors = try await rig.freshRows()
        #expect(survivors.count == 2)
        #expect(!survivors.map(\.id).contains(targetRow.id))
        #expect(Set(survivors.map(\.id)) == ids.subtracting([targetRow.id]))
        #expect(FileManager.default.fileExists(atPath: target.url.path))
        #expect(pipelineSHA256(ofFileAt: target.url) == target.sha)
        for other in [shots[0], shots[2]] { #expect(pipelineSHA256(ofFileAt: other.url) == other.sha) }
    }

    @Test("OC-2053 deleting from history leaves every source file unchanged, also after Clear History")
    func historyDeletionNeverTouchesFiles() async throws {
        // Given: two screenshots imported; their SHA-256 and the folder listing recorded.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        try await rig.running()
        let shots = try await importLive(rig, 2)
        let listing = pipelineListing(of: rig.watched)
        #expect(listing.count == 2)
        let rows = await rig.rows()
        // When: one is deleted from history, then everything is cleared.
        _ = try await rig.database.delete(ids: [rows[0].id]).get()
        #expect(try await rig.freshCount() == 1)
        let outcome = try await rig.database.clearHistory(range: .allTime, includeExempt: true).get()
        // Then: the Library is empty (delta -1 then -1) and both files are exactly as they were.
        #expect(outcome.deletedCount == 1)
        #expect(try await rig.freshCount() == 0)
        #expect(pipelineListing(of: rig.watched) == listing)
        for shot in shots { #expect(pipelineSHA256(ofFileAt: shot.url) == shot.sha) }
    }

    @Test("OC-2038 a deleted screenshot stays absent after quit and relaunch (3 launch-imported screenshots, AC-002-07)")
    func deletedScreenshotStaysDeletedAcrossRelaunch() async throws {
        // Given: Flotsam was quit, 3 screenshots were taken, and Flotsam is launched: exactly 3 items appear.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        let shots = try (1...3).map { try rig.shot(born: rig.clock.now().addingTimeInterval(-Double($0) * 100)) }
        try await rig.launch(watermark: rig.clock.now().addingTimeInterval(-3_600))
        #expect(await rig.waitForCount(3))
        let rows = await rig.rows()
        #expect(rows.count == 3)
        let doomed = try #require(rows.first { $0.lastCopiedAt == shots[1].born && $0.pixelWidth == shots[1].width })
        // When: one is deleted (command-delete), then Flotsam is quit and relaunched.
        _ = try await rig.database.delete(ids: [doomed.id]).get()
        #expect(try await rig.freshCount() == 2)
        try await rig.relaunch()
        await letItSettle()
        _ = await pipelineEventually(seconds: 2) { await rig.count() != 2 }
        // Then: count after relaunch = count after delete, the deleted id is still absent, the file is on disk.
        let reopened = try await rig.freshRows()
        #expect(reopened.count == 2)
        #expect(!reopened.map(\.id).contains(doomed.id))
        #expect(Set(reopened.map(\.id)) == Set(rows.map(\.id)).subtracting([doomed.id]))
        #expect(FileManager.default.fileExists(atPath: shots[1].url.path))
    }

    @Test("OC-2038 a live-imported screenshot deleted before any later scan stays absent after quit and relaunch")
    func deletedScreenshotInsideWatermarkWindowStaysDeleted() async throws {
        // Given: three screenshots imported live (file events) and no reconcile scan since (the persisted watermark still
        // predates them: only launch, wake, activation and rebuild move it; a live import does not).
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        try await rig.running()
        let shots = try await importLive(rig, 3)
        let rows = await rig.rows()
        let doomed = try #require(rows.first { $0.lastCopiedAt == shots[1].born && $0.pixelWidth == shots[1].width })
        // When: one is deleted, then Flotsam is quit and relaunched at once.
        _ = try await rig.database.delete(ids: [doomed.id]).get()
        #expect(try await rig.freshCount() == 2)
        try await rig.relaunch()
        await letItSettle()
        _ = await pipelineEventually(seconds: 2) { await rig.count() != 2 }
        // Then: the deleted one stays absent (count after relaunch = count after delete).
        let reopened = try await rig.freshRows()
        #expect(reopened.count == 2)
        #expect(!reopened.map(\.id).contains(doomed.id))
    }
}

// MARK: - Batch 2: dates, ordering, source, dedupe, file immutability (OC-2042, 2045, 2046, 2047, 2050, 2051)

@Suite("FRD002Pipeline item dates, source and dedupe")
struct FRD002PipelineItemTests {
    private func waitForCopyCount(_ rig: PipelineRig, id: UUID, _ expected: Int) async -> Bool {
        await pipelineEventually {
            ((try? await rig.database.content(of: id).get())?.copyCount) == expected
        }
    }

    @Test("OC-2042 item dates are the file's creation date, not the launch time, and Recent places it by that date")
    func itemDateIsFileBirthDate() async throws {
        // Given: Flotsam is quit; a screenshot is added at T; two clipboard images exist at T - 5 min and T + 5 min.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        let t = pipelineWhole(rig.clock.now())
        try await rig.openDatabase(watermark: t.addingTimeInterval(-3_600))
        try await rig.seedClipboardImage(pipelinePNG(width: 9, height: 9), at: t.addingTimeInterval(-300))
        try await rig.seedClipboardImage(pipelinePNG(width: 11, height: 11), at: t.addingTimeInterval(300))
        try rig.shot(born: t)
        // When: Flotsam launches at T + 10 min.
        rig.clock.advance(by: 600)
        await rig.startWatcher()
        #expect(await rig.waitForCount(3))
        // Then: the screenshot's Copied and First copied are T (not T + 600), and it sits between the other two.
        let rows = try await rig.freshRows()
        #expect(rows.count == 3)
        let screenshot = try #require(rows.first { $0.kind == .screenshot })
        #expect(screenshot.lastCopiedAt == t)
        #expect(screenshot.lastCopiedAt != rig.clock.now())
        let content = try await rig.fresh().content(of: screenshot.id).get()
        #expect(content.firstCopiedAt == t)
        #expect(rows.map(\.kind) == [.image, .screenshot, .image])
        #expect(rows[0].lastCopiedAt == t.addingTimeInterval(300))
        #expect(rows[2].lastCopiedAt == t.addingTimeInterval(-300))
    }

    @Test("OC-2047 two screenshots added while quit are listed newest creation date first")
    func recentOrdersByFileBirthDate() async throws {
        // Given: Flotsam is quit; the file for B (born T + 2 min, named to sort first) is written before A's (born T).
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        let t = pipelineWhole(rig.clock.now())
        let b = try rig.shot("Screenshot a-b.png", width: 37, height: 23, born: t.addingTimeInterval(120))
        let a = try rig.shot("Screenshot z-a.png", width: 31, height: 21, born: t)
        // When: Flotsam launches.
        try await rig.launch(watermark: t.addingTimeInterval(-3_600))
        #expect(await rig.waitForCount(2))
        // Then: B is above A in Recent, by creation date.
        let rows = try await rig.freshRows()
        #expect(rows.count == 2)
        #expect(rows.map(\.lastCopiedAt) == [b.born, a.born])
        #expect(rows.map(\.pixelWidth) == [37, 31])
    }

    @Test("OC-2045 import leaves the file at the same path with the same SHA-256, modification date and attributes")
    func importDoesNotTouchTheFile() async throws {
        // Given: pickup is running; a screenshot is written under a hidden temp name and renamed into W atomically.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        try await rig.running()
        let bytes = pipelinePNG(width: 41, height: 29)
        let hidden = rig.watched.appendingPathComponent(".Screenshot-tmp-\(UUID().uuidString).png")
        try bytes.write(to: hidden)
        try TempFolder.setScreenCaptureAttribute(true, on: hidden)
        try FileManager.default.setAttributes([.creationDate: pipelineWhole(rig.clock.now())], ofItemAtPath: hidden.path)
        let final = rig.watched.appendingPathComponent("Screenshot oc-\(UUID().uuidString).png")
        try FileManager.default.moveItem(at: hidden, to: final)
        let sha = pipelineSHA256(bytes)
        let modified = pipelineModified(final)
        let xattrs = pipelineXattrs(final)
        #expect(xattrs["com.apple.metadata:kMDItemIsScreenCapture"] != nil)
        // When: the rename event arrives and the import completes.
        rig.event(hidden)
        rig.event(final)
        #expect(await rig.waitForCount(1))
        await letItSettle()
        // Then: same path, name, SHA-256, modification date and extended attributes; nothing else appeared in W.
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.watched.path) == [final.lastPathComponent])
        #expect(pipelineSHA256(ofFileAt: final) == sha)
        #expect(pipelineModified(final) == modified)
        #expect(pipelineXattrs(final) == xattrs)
    }

    @Test("OC-2046 a screenshot item reads Screenshot, is under the Screenshots filter and the Screenshot app")
    func screenshotSourceAndKind() async throws {
        // Given: one clipboard image and one picked-up 41 x 29 screenshot.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        try await rig.openDatabase(watermark: rig.clock.now().addingTimeInterval(-3_600))
        try await rig.seedClipboardImage(pipelinePNG(width: 7, height: 5), at: rig.clock.now().addingTimeInterval(-60))
        await rig.startWatcher()
        rig.event(try rig.shot().url)
        #expect(await rig.waitForCount(2))
        // When: the row, the filter lists and the sidebar are read from a fresh instance.
        let fresh = try await rig.fresh()
        let screenshots = try await fresh.items(matching: LibraryQuery(filter: .kind(.screenshot))).get().rows
        let counts = try await fresh.sidebarCounts().get()
        // Then: exactly the screenshot is under the filter; its source is the label; the row reads label + pixel size.
        #expect(screenshots.count == 1)
        #expect(screenshots.first?.kind == .screenshot)
        #expect(screenshots.first?.sourceName == "Screenshot")
        #expect(screenshots.first?.primaryLine == "Screenshot 41 × 29")
        #expect(counts.kinds[.screenshot] == 1)
        #expect(counts.kinds[.image] == 1)
        let app = counts.apps.first { $0.identity == .bundle("com.apple.screencaptureui") }
        #expect(app?.name == "Screenshot")
        #expect(app?.count == 1)
        #expect(counts.apps.filter { $0.identity == .bundle("com.apple.screencaptureui") }.count == 1)
    }

    @Test("OC-2050 a screenshot identical to a clipboard image bumps it: count delta 0, kind image, copy count c + 1")
    func screenshotDedupesAgainstClipboardImage() async throws {
        // Given: an image item I copied twice (copy count 2) from the clipboard.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        let bytes = pipelinePNG(width: 41, height: 29)
        try await rig.openDatabase(watermark: rig.clock.now().addingTimeInterval(-3_600))
        try await rig.seedClipboardImage(bytes, at: rig.clock.now().addingTimeInterval(-120))
        try await rig.seedClipboardImage(bytes, at: rig.clock.now().addingTimeInterval(-60))
        await rig.startWatcher()
        let seeded = try await rig.freshRows()
        #expect(seeded.count == 1)
        let id = seeded[0].id
        #expect(try await rig.fresh().content(of: id).get().copyCount == 2)
        // When: a qualifying screenshot with identical bytes is added.
        let shot = try rig.shot(bytes: bytes)
        rig.event(shot.url)
        // Then: still one item, same id, kind image, copy count 3.
        #expect(await waitForCopyCount(rig, id: id, 3))
        let after = try await rig.freshRows()
        #expect(after.map(\.id) == [id])
        #expect(after.first?.kind == .image)
        #expect(try await rig.fresh().content(of: id).get().copyCount == 3)
    }

    @Test("OC-2051 a Finder duplicate of an imported screenshot creates nothing; different bytes still do")
    func finderDuplicateIsDeduped() async throws {
        // Given: screenshot X imported.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        try await rig.running()
        let x = try rig.shot("Screenshot X.png")
        rig.event(x.url)
        #expect(await rig.waitForCount(1))
        let id = try #require(await rig.rows().first?.id)
        // When: X is duplicated in Finder into W as 'Screenshot X copy.png' (same bytes).
        let copy = rig.watched.appendingPathComponent("Screenshot X copy.png")
        try FileManager.default.copyItem(at: x.url, to: copy)
        rig.event(copy)
        // Then: count delta 0 and the same item is bumped (the duplicate was processed, not missed).
        #expect(await waitForCopyCount(rig, id: id, 2))
        #expect(try await rig.freshRows().map(\.id) == [id])
        // And: a screenshot with different bytes still creates an item, so the dedupe is by content.
        let other = try rig.shot("Screenshot Y.png", width: 33, height: 17)
        rig.event(other.url)
        #expect(await rig.waitForCount(2))
        #expect(try await rig.freshCount() == 2)
    }
}

// MARK: - Batch 3: backfill, folder immutability, wake and activation, write failure (OC-2059, 2071, 2074, 2084)

@Suite("FRD002Pipeline backfill, folder immutability, reconcile triggers and write failure")
struct FRD002PipelineSessionTests {
    private func importLive(_ rig: PipelineRig, _ count: Int, from start: Int = 0) async throws -> [PipelineShot] {
        var shots: [PipelineShot] = []
        for index in 0..<count {
            let shot = try rig.shot(width: 30 + start + index)
            shots.append(shot)
            rig.event(shot.url)
            #expect(await rig.waitForCount(start + index + 1), "screenshot \(index + 1) never reached the Library")
        }
        return shots
    }

    @Test("OC-2059 Import recent screenshots leaves a tagged, annotated item single with its tag and note")
    func backfillKeepsTagAndNote() async throws {
        // Given: a screenshot item with tag 'keep' and note 'n-<uuid>', and one older screenshot not yet imported.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        try await rig.running()
        let shot = try await importLive(rig, 1)[0]
        let id = try #require(await rig.rows().first?.id)
        let note = "n-\(UUID().uuidString)"
        _ = try await rig.database.createTagAndApply(name: "keep", to: [id]).get()
        _ = try await rig.database.setNote(note, for: id).get()
        let older = try rig.shot(born: rig.clock.now().addingTimeInterval(-7_200))
        // When: Import recent screenshots is run.
        let created = await rig.watcher.importRecent()
        // Then: only the older file created an item (count 1 -> 2); the tagged item is still single, tag and note intact.
        #expect(created == 1)
        let rows = try await rig.freshRows()
        #expect(rows.count == 2)
        let kept = rows.filter { $0.id == id }
        #expect(kept.count == 1)
        #expect(kept.first?.tagNames == ["keep"])
        #expect(kept.first?.lastCopiedAt == shot.born)
        let content = try await rig.fresh().content(of: id).get()
        #expect(content.note == note)
        #expect(content.copyCount == 1)
        #expect(rows.contains { $0.lastCopiedAt == older.born && $0.id != id })
    }

    @Test("OC-2071 a whole session never creates, renames, modifies or deletes a file in W")
    func sessionLeavesWatchedFolderUntouched() async throws {
        // Given: W holds two bystander files; its full listing (name, SHA-256, modification date, attributes) is taken.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        let notes = rig.watched.appendingPathComponent("notes.txt")
        let movie = rig.watched.appendingPathComponent("Screen Recording 1.mov")
        try Data("pipeline notes".utf8).write(to: notes)
        try Data(count: 2_048).write(to: movie)
        try await rig.running()
        var expected = pipelineListing(of: rig.watched)
        #expect(expected.count == 2)
        // When: 10 imports, a dedupe, a backfill, 3 item deletions and a Clear History run.
        var shots = try await importLive(rig, 10)
        for shot in shots { expected[shot.name] = pipelineSnapshot(shot.url) }
        let copy = rig.watched.appendingPathComponent("Screenshot dup.png")
        try FileManager.default.copyItem(at: shots[0].url, to: copy)
        expected[copy.lastPathComponent] = pipelineSnapshot(copy)
        rig.event(copy)
        let id0 = try #require(await rig.rows().first { $0.pixelWidth == shots[0].width }?.id)
        #expect(await pipelineEventually { ((try? await rig.database.content(of: id0).get())?.copyCount ?? 0) >= 2 })
        let old = try (0..<2).map { try rig.shot(born: rig.clock.now().addingTimeInterval(-7_200 - Double($0))) }
        for shot in old { expected[shot.name] = pipelineSnapshot(shot.url) }
        shots += old
        #expect(await rig.watcher.importRecent() == 2)
        let rows = try await rig.freshRows()
        #expect(rows.count == 12)
        let removed = try await rig.database.delete(ids: rows.prefix(3).map(\.id)).get()
        #expect(removed.count == 3)
        #expect(try await rig.freshCount() == 9)
        let outcome = try await rig.database.clearHistory(range: .allTime, includeExempt: true).get()
        #expect(outcome.deletedCount == 9)
        #expect(try await rig.freshCount() == 0)
        await letItSettle()
        // Then: W's listing is the baseline plus exactly the files the test added, each unchanged.
        #expect(pipelineListing(of: rig.watched) == expected)
        let expectedFileCount: Int = 15
        #expect(expected.count == expectedFileCount)
    }

    @Test("OC-2074 a deleted screenshot stays absent after relaunch, wake and activation (launch-imported)")
    func deletedStaysAbsentAcrossTriggers() async throws {
        // Given: two screenshots imported by the launch scan; one deleted from history; its file remains in W.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        let shots = try (1...2).map { try rig.shot(born: rig.clock.now().addingTimeInterval(-Double($0) * 100)) }
        try await rig.launch(watermark: rig.clock.now().addingTimeInterval(-3_600))
        #expect(await rig.waitForCount(2))
        let rows = await rig.rows()
        let doomed = try #require(rows.first { $0.lastCopiedAt == shots[0].born })
        let survivor = try #require(rows.first { $0.id != doomed.id })
        _ = try await rig.database.delete(ids: [doomed.id]).get()
        #expect(try await rig.freshCount() == 1)
        // When / Then: after each of relaunch, wake and activation the count is unchanged and S is absent.
        try await rig.relaunch()
        await letItSettle()
        _ = await pipelineEventually(seconds: 1.5) { await rig.count() != 1 }
        try await expectAbsent(rig, doomed.id, survivor.id, after: "relaunch")
        rig.clock.advance(by: 3_600)
        await rig.watcher.didWake()
        await letItSettle()
        _ = await pipelineEventually(seconds: 1.5) { await rig.count() != 1 }
        try await expectAbsent(rig, doomed.id, survivor.id, after: "wake")
        rig.clock.advance(by: 60)
        await rig.watcher.didBecomeActive()
        await letItSettle()
        _ = await pipelineEventually(seconds: 1.5) { await rig.count() != 1 }
        try await expectAbsent(rig, doomed.id, survivor.id, after: "activation")
        #expect(FileManager.default.fileExists(atPath: shots[0].url.path))
    }

    @Test("OC-2074 a live-imported screenshot deleted from history stays absent after wake and activation, and relaunch")
    func liveImportedDeletedStaysAbsent() async throws {
        // Given: two screenshots imported live; one deleted from history; its file remains in W.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        try await rig.running()
        let shots = try await importLive(rig, 2)
        let rows = await rig.rows()
        let doomed = try #require(rows.first { $0.lastCopiedAt == shots[0].born && $0.pixelWidth == shots[0].width })
        let survivor = try #require(rows.first { $0.id != doomed.id })
        _ = try await rig.database.delete(ids: [doomed.id]).get()
        #expect(try await rig.freshCount() == 1)
        // When / Then: wake and activation (same process) keep S absent.
        await rig.watcher.didWake()
        await letItSettle()
        _ = await pipelineEventually(seconds: 1.5) { await rig.count() != 1 }
        try await expectAbsent(rig, doomed.id, survivor.id, after: "wake")
        await rig.watcher.didBecomeActive()
        await letItSettle()
        _ = await pipelineEventually(seconds: 1.5) { await rig.count() != 1 }
        try await expectAbsent(rig, doomed.id, survivor.id, after: "activation")
        // And: a relaunch keeps it absent too. The persisted watermark was last set when pickup started, before S arrived.
        try await rig.relaunch()
        await letItSettle()
        _ = await pipelineEventually(seconds: 1.5) { await rig.count() != 1 }
        let reopened = try await rig.freshRows()
        #expect(reopened.count == 1)
        #expect(!reopened.map(\.id).contains(doomed.id))
    }

    private func expectAbsent(_ rig: PipelineRig, _ doomed: UUID, _ survivor: UUID, after event: String) async throws {
        let rows = try await rig.freshRows()
        #expect(rows.count == 1, "count changed after \(event)")
        #expect(!rows.map(\.id).contains(doomed), "deleted item reappeared after \(event)")
        #expect(rows.map(\.id) == [survivor], "survivor identity changed after \(event)")
    }

    @Test("OC-2084 an unwritable data folder: no item, the STO-IO-001 message in Notices, the file untouched")
    func unwritableDataFolderFailsCleanly() async throws {
        // Given: pickup running; the data folder (and every folder inside it) made unwritable; F's SHA-256 recorded.
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        try await rig.running()
        func setPermissions(_ mode: Int) {
            var directories: [URL] = [rig.dataFolder]
            if let walker = FileManager.default.enumerator(at: rig.dataFolder, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    directories.append(url)
                }
            }
            for directory in directories {
                try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
            }
        }
        setPermissions(0o500)
        defer { setPermissions(0o755) }
        let probe = rig.dataFolder.appendingPathComponent("pipeline-probe")
        #expect(!FileManager.default.createFile(atPath: probe.path, contents: Data()), "the data folder must really be unwritable")
        // When: a qualifying screenshot F is added.
        let shot = try rig.shot()
        rig.event(shot.url)
        let noticed = await pipelineEventually { await MainActor.run { rig.presenter.latestNotices.contains { $0.code == .stoIo001 } } }
        // Then: a STO-IO-001 Notice with the catalogue message; no item by that name; F unchanged.
        #expect(noticed, "no STO-IO-001 Notice appeared")
        let allNotices = await MainActor.run { rig.presenter.latestNotices }
        let notices = allNotices.filter { $0.code == .stoIo001 }
        #expect(notices.count == 1)
        #expect(notices.first?.message == "Flotsam couldn't write to its data folder. Check free disk space.")
        #expect(await rig.count(.all, text: shot.name) == 0)
        #expect(await rig.count() == 0)
        #expect(pipelineSHA256(ofFileAt: shot.url) == shot.sha)
        setPermissions(0o755)
        #expect(try await rig.freshCount() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.watched.path) == [shot.name])
    }

    @Test("OC-2070: an override folder named 'fold-zq7marker' never appears in the log, whatever the pickup does")
    func overrideFolderNameStaysOutOfTheLog() async throws {
        // Given: the override folder 'fold-zq7marker' is set and pickup is running on it (not on W).
        let rig = try PipelineRig()
        defer { rig.cleanUp() }
        let marker = "zq7marker"
        let chosen = try rig.temp.folder("home/fold-\(marker)")
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        try await rig.running()
        #expect(await rig.watcher.status == .watching)
        #expect(rig.source.running.count == 1)
        // When: a marker-named screenshot is imported, then a marker-named file that is not an image is rejected
        // (SSP-VAL-001 logged: provoked, not assumed), and the watcher ticks.
        let shot = try rig.shot("Screenshot \(marker)-\(UUID().uuidString).png", in: chosen)
        rig.event(shot.url)
        #expect(await rig.waitForCount(1), "the screenshot in the override folder never reached the Library")
        let bad = chosen.appendingPathComponent("Screenshot \(marker)-bad-\(UUID().uuidString).png")
        try Data("this is not an image".utf8).write(to: bad)
        try TempFolder.setScreenCaptureAttribute(true, on: bad)
        rig.event(bad)
        let logged = await pipelineEventually { rig.sink.records.contains { $0.headline.contains("SSP-VAL-001") } }
        #expect(logged, "SSP-VAL-001 was never logged, so the leak check would have nothing to find")
        await rig.tick()
        #expect(await rig.watcher.status == .watching)
        // Then: not one log record (headline, public or private context, message, cause) holds the marker; there are
        // records to search, and one of them is the SSP-VAL-001 event itself.
        let records = rig.sink.records
        #expect(records.contains { $0.headline.contains("SSP-VAL-001") })
        #expect(records.count >= 2)
        for record in records {
            let text = [record.headline, record.publicContext, record.privateContext, record.message ?? "",
                        String(describing: record.cause)].joined(separator: " ")
            #expect(!text.contains(marker), "log record leaks the override folder name: \(record.headline)")
        }
        // Control for the Library side: the item is still there through a fresh instance.
        #expect(try await rig.freshCount() == 1)
    }

    // MARK: Onboarding (package halves of OC-2060 / OC-2061)
    // The onboarding checkbox and its default live in App/Flotsam/OnboardingModel.swift (needs the App container; no
    // package seam). What the package owns is what "checked" and "unchecked" lead to: "Import recent screenshots" is
    // called (checked) or never called (unchecked), and a first launch imports nothing by itself.

    /// First run: no watermark yet, W already holds two qualifying screenshots from the last week (3 and 5 days old).
    private func firstRunWithAWeekOfScreenshots() async throws -> (PipelineRig, [PipelineShot]) {
        let rig = try PipelineRig()
        let now = rig.clock.now()
        let shots = [
            try rig.shot(width: 31, born: now.addingTimeInterval(-3 * 86_400)),
            try rig.shot(width: 32, born: now.addingTimeInterval(-5 * 86_400)),
        ]
        try await rig.launch(watermark: nil)
        return (rig, shots)
    }

    @Test("OC-2060 (package half): the import the checked box triggers brings in both screenshots from the last week")
    func checkedImportBringsInTheWeek() async throws {
        // Given: first run, W holds 2 qualifying screenshots from the last week; nothing in the Library.
        let (rig, shots) = try await firstRunWithAWeekOfScreenshots()
        defer { rig.cleanUp() }
        #expect(try await rig.freshCount() == 0)
        // When: onboarding completes with the box left checked, which calls "Import recent screenshots".
        let created = await rig.watcher.importRecent()
        // Then: count +2, both files by identity, read through a fresh instance; the files are untouched.
        #expect(created == 2)
        let rows = try await rig.freshRows()
        #expect(rows.count == 2)
        #expect(Set(rows.compactMap(\.pixelWidth)) == [31, 32], "the two files, by pixel width (their identity)")
        #expect(rows.allSatisfy { $0.kind == .screenshot })
        for shot in shots { #expect(pipelineSHA256(ofFileAt: shot.url) == shot.sha) }
    }

    @Test("OC-2061 (package half): with the box unchecked (import never called) neither week-old screenshot is imported")
    func uncheckedImportBringsInNothing() async throws {
        // Given: first run, W holds the same 2 qualifying screenshots, pickup is on and running.
        let (rig, shots) = try await firstRunWithAWeekOfScreenshots()
        defer { rig.cleanUp() }
        #expect(await rig.watcher.status == .watching)
        // When: onboarding completes without importing, and every automatic path runs (a tick, a wake, an activation,
        // a live event for each existing file).
        await rig.tick()
        await rig.watcher.didWake()
        await rig.watcher.didBecomeActive()
        for shot in shots { rig.event(shot.url) }
        await letItSettle()
        // Then: neither is in the Library (count delta 0, through a fresh instance), both files still in W.
        #expect(try await rig.freshCount() == 0)
        for shot in shots { #expect(pipelineSHA256(ofFileAt: shot.url) == shot.sha) }
    }
}
