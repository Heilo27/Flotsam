import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import FlotsamBase
import FlotsamPayload
@testable import FlotsamScreenshots
@testable import FlotsamStorage

// FRD-002 contract tests for the Notice texts and the "log only" codes (OC-2002, 2003, 2012, 2016, 2035, 2063, 2064,
// 2076, 2077, 2078, 2079, 2081, 2082, 2083).
//
// Real: ScreenshotWatcher, IngestActor, FlotsamDatabase in a temp folder, ErrorReporter, the catalogue strings, real PNG
// files with real extended attributes, real atomic renames. Fakes sit only on the ports: the folder event source, the
// clock, `com.apple.screencapture` preferences, the settings key-value store, the error presenter and the log sink.
// Stored counts are read through a FRESH `FlotsamDatabase.open`, never an in-memory list.
//
// "The menu-bar warning dot" is drawn from the presenter's Notices list (App/Flotsam/ErrorPresenterAdapter.hasBadge is
// `!notices.isEmpty`), so here it is asserted as: the list the presenter was last handed holds a warning-severity
// Notice. The dot's pixels and the Settings status LABEL text are app-target (FRD-008) and are not reachable here; the
// watcher's `status` value they are drawn from is asserted instead.
//
// Every helper is private and prefixed `Notice8T` so it cannot collide with another suite in this target.

// MARK: - Fixtures

/// A PNG whose pixels are unique to this call, so no two files share a content key.
private func notice8TPNG(width: Int = 41, height: Int = 29) -> Data {
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

/// Polls an async condition until it holds or `seconds` pass.
private func notice8TEventually(seconds: Double = 20, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Records everything the reporter would draw: every Notices list it was handed, and every HUD.
private final class Notice8TPresenter: ErrorPresenter, @unchecked Sendable {
    /// The protocol methods run on the main actor; the state sits in a lock-guarded box so test code can read it
    /// from any context.
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var lists: [[Notice]] = []
        var huds: [String] = []
    }
    private let box = Box()
    func showHUD(message: String) { box.lock.withLock { box.huds.append(message) } }
    func noticesChanged(_ notices: [Notice]) { box.lock.withLock { box.lists.append(notices) } }
    func presentFatal(_ error: FlotsamError) {}
    /// The list the menu bar shows now.
    nonisolated var current: [Notice] { box.lock.withLock { box.lists.last ?? [] } }
    /// True when any list the presenter was ever handed held a Notice: the badge would have lit at some moment.
    nonisolated var everHadNotice: Bool { box.lock.withLock { box.lists.contains { !$0.isEmpty } } }
    nonisolated var hudCount: Int { box.lock.withLock { box.huds.count } }
    nonisolated func notices(_ code: ErrorCode) -> [Notice] { current.filter { $0.code == code } }
}

/// The probed local file system, plus a file whose size and modification date keep changing until the clock passes
/// `growsFor` seconds after `beginGrowing`, then hold. Everything else is the real file system.
private final class Notice8TFileSystem: FileSystemPort, @unchecked Sendable {
    let base = ProbedFileSystem()
    private let lock = NSLock()
    private var growing: (path: String, start: Date, seconds: TimeInterval, clock: any WallClock)?

    func beginGrowing(_ url: URL, for seconds: TimeInterval, clock: any WallClock) {
        lock.withLock { growing = (url.path, clock.now(), seconds, clock) }
    }

    /// The file stops changing: from now on it reports its real size and date.
    func stopGrowing() { lock.withLock { growing = nil } }

    func fileInfo(at url: URL) -> FileInfo? {
        guard let real = base.fileInfo(at: url) else { return nil }
        guard let growth = lock.withLock({ growing }), growth.path == url.path else { return real }
        let elapsed = growth.clock.now().timeIntervalSince(growth.start)
        guard elapsed < growth.seconds else { return real }
        return FileInfo(
            byteSize: real.byteSize + Int(elapsed * 1_000) + 1, modifiedAt: growth.clock.now(), createdAt: real.createdAt, kind: real.kind)
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { base.contentsOfDirectory(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { base.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { base.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { base.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { base.removeItem(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { base.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { base.writeFile(data, to: url, permissions: permissions) }
    func readFile(at url: URL) -> FlotsamResult<Data> { base.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { base.readFileNoFollow(at: url) }
    func availableCapacity(at url: URL) -> Int64? { base.availableCapacity(at: url) }
}

/// The real pipeline over a temp tree: watcher, ingest actor, database and reporter wired as AppContainer wires them.
/// `home/Desktop` exists; every other folder is made by the test.
private final class Notice8TRig: @unchecked Sendable {
    let temp: TempFolder
    let home: URL
    let desktop: URL
    let dataFolder: URL
    let clock = SteppedClock()
    let source = FakeFolderSource()
    let preferences = MutablePreferences()
    let pollTick = PollTick()
    let settings = SettingsStore(store: MemorySettingsBacking())
    let presenter = Notice8TPresenter()
    let sink = WatcherLogSink()
    let fileSystem = Notice8TFileSystem()
    private(set) var database: FlotsamDatabase!
    private(set) var watcher: ScreenshotWatcher!

    init() throws {
        temp = try TempFolder()
        home = try temp.folder("home")
        desktop = try temp.folder("home/Desktop")
        dataFolder = temp.root.appendingPathComponent("data", isDirectory: true)
    }

    /// Opens the database, writes the watermark a previous run left ("a moment ago"), and starts pickup.
    func launch() async throws {
        database = try await FlotsamDatabase.open(folder: dataFolder, logSink: sink).get()
        let database = self.database!
        _ = await DatabaseWatermarkStore(database: database).setLastScanAt(clock.now().addingTimeInterval(-3_600))
        let reporter = ErrorReporter(presenter: presenter, clock: clock, sink: sink)
        watcher = ScreenshotWatcher(
            fileSystem: fileSystem, preferences: preferences, home: home, clock: clock, eventSource: source,
            settings: settings, ingest: IngestActor(database: database, settings: settings),
            watermarkStore: DatabaseWatermarkStore(database: database),
            report: { error in await reporter.report(error, origin: .background) },
            clear: { code in await reporter.clearNotices(code: code) }, pollTick: pollTick, sink: sink)
        await watcher.start()
    }

    /// A system-style screenshot, arriving the way macOS delivers it: written under a hidden "."-prefixed name with the
    /// screen-capture attribute, then moved into place by an atomic rename.
    @discardableResult
    func arrive(
        in folder: URL, _ name: String = "Screenshot oc-\(UUID().uuidString).png", bytes: Data? = nil, attribute: Bool = true
    ) throws -> URL {
        let hidden = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        try (bytes ?? notice8TPNG()).write(to: hidden)
        if attribute { try TempFolder.setScreenCaptureAttribute(true, on: hidden) }
        try FileManager.default.setAttributes([.creationDate: clock.now()], ofItemAtPath: hidden.path)
        let final = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: hidden, to: final)
        return final
    }

    func event(_ url: URL) { source.emit(.changed([url])) }

    /// One 5 s poll of the fallback source: waits until the poll is asleep, then lets 5 s pass.
    func poll() async {
        _ = await notice8TEventually { clock.sleeping(seconds: 5) >= 1 }
        clock.advance(by: 5)
    }

    /// A fresh database instance on the data folder: what the Library shows after a relaunch.
    func fresh() async throws -> FlotsamDatabase { try await FlotsamDatabase.open(folder: dataFolder).get() }
    func freshCount() async throws -> Int { try await fresh().count(filter: .all).get() }
    func freshRows() async throws -> [ItemRow] { try await fresh().items(matching: LibraryQuery()).get().rows }
    func freshCount(named name: String) async throws -> Int { try await fresh().count(filter: .all, text: name).get() }
    /// Waits on the RUNNING database, then confirms through a fresh instance. Opening a fresh instance sweeps the data
    /// folder's `tmp/` (DataFolder leftovers), which would delete a blob an import is still staging, so a fresh
    /// instance is never opened while an import may be in flight.
    func waitForFreshCount(_ expected: Int) async throws -> Bool {
        let live = database!
        let arrived = await notice8TEventually { ((try? await live.count(filter: .all).get()) ?? -1) == expected }
        guard arrived else { return false }
        return try await freshCount() == expected
    }

    /// Log records whose headline starts with `code`.
    func logged(_ code: String) -> [LogRecord] { sink.records.filter { $0.headline.hasPrefix(code) } }

    func cleanUp() {
        if let walker = FileManager.default.enumerator(at: temp.root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        temp.cleanUp()
    }
}

/// What the Notice text must never carry: a folder path or the file's name (FR-000-06, FRD-002 SSP catalogue).
private func notice8TExpectNoLeak(_ message: String, rig: Notice8TRig, fileNames: [String] = []) {
    #expect(!message.contains("/"), "a path separator in: \(message)")
    #expect(!message.contains(rig.temp.root.lastPathComponent), "the temp tree's name in: \(message)")
    #expect(!message.lowercased().contains(".png"), "a file extension in: \(message)")
    for name in fileNames { #expect(!message.contains(name), "the file name in: \(message)") }
}

// MARK: - Batch 1: folder conditions (OC-2002, 2003, 2012, 2076, 2077, 2079)

@Suite("FRD002Notice folder conditions", .serialized)
struct FRD002NoticeFolderTests {
    private static let usingDesktopText = "Your screenshot folder isn't available, so Flotsam is watching the Desktop instead."
    private static let pausedText = "Your chosen screenshot folder is missing. Screenshot pickup is paused."
    private static let needsAccessText =
        "Flotsam can't read your screenshot folder. Allow access in System Settings › Privacy & Security › Files and Folders."

    /// Watching `home/Pictures/Shots`, then it is deleted and 35 s pass (a poll tick: the 30 s re-resolution).
    private func shotsDeleted(_ rig: Notice8TRig) async throws {
        let shots = try rig.temp.folder("home/Pictures/Shots")
        rig.preferences.set(location: shots.path)
        try await rig.launch()
        #expect(await rig.watcher.status == .watching)
        try FileManager.default.removeItem(at: shots)
        rig.clock.advance(by: 35)
        await rig.watcher.tickFired()
    }

    @Test("OC-2002 a deleted system folder falls back to the Desktop: one screenshot stored, SSP-IO-001 once, status Using Desktop")
    func deletedSystemFolderUsesDesktop() async throws {
        // given: pickup on Shots, running, nothing raised yet
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        try await shotsDeleted(rig)

        // when: after the 35 s, a qualifying screenshot is renamed into the Desktop
        let file = try rig.arrive(in: rig.desktop)
        rig.event(file)

        // then: exactly one screenshot item (count 0 -> 1), found by its file name, in a fresh instance
        #expect(try await rig.waitForFreshCount(1))
        let rows = try await rig.freshRows()
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .screenshot)
        #expect(try await rig.freshCount(named: file.lastPathComponent) == 1)
        // and: SSP-IO-001 shows exactly once, still once after another tick, and the status is Using Desktop
        await rig.watcher.tickFired()
        #expect(rig.presenter.notices(.sspIo001).count == 1)
        #expect(rig.presenter.current.count == 1)
        #expect(await rig.watcher.status == .usingDesktop)
    }

    @Test("OC-2002 before the folder disappears nothing is raised and status is Watching; the Desktop is not watched")
    func watchingShotsRaisesNothing() async throws {
        // given: pickup on an existing Shots folder
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        let shots = try rig.temp.folder("home/Pictures/Shots")
        rig.preferences.set(location: shots.path)
        try await rig.launch()

        // when: a screenshot lands on the Desktop (not the watched folder) and an event names it
        let onDesktop = try rig.arrive(in: rig.desktop)
        rig.event(onDesktop)
        try await Task.sleep(for: .milliseconds(150))

        // then: nothing stored, no Notice, status Watching
        #expect(try await rig.freshCount() == 0)
        #expect(!rig.presenter.everHadNotice)
        #expect(await rig.watcher.status == .watching)
    }

    @Test("OC-2077 SSP-IO-001 reads the Desktop-fallback text, as a warning on the menu bar, without a path or file name")
    func usingDesktopText() async throws {
        // given: Shots deleted and re-resolved
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        try await shotsDeleted(rig)

        // when: the Notice is read
        let notices = rig.presenter.notices(.sspIo001)

        // then: one Notice, the literal text, warning severity (the dot), no path, no file name, no HUD
        #expect(notices.count == 1)
        #expect(notices.first?.message == Self.usingDesktopText)
        #expect(notices.first?.severity == .warning)
        #expect(rig.presenter.current.count == 1)
        notice8TExpectNoLeak(notices.first?.message ?? "", rig: rig, fileNames: ["Shots", "Pictures"])
        #expect(rig.presenter.hudCount == 0)

        // and: the log record is a warning headed "SSP-IO-001 warning"
        #expect(rig.logged("SSP-IO-001").count == 1)
        #expect(rig.logged("SSP-IO-001").first?.headline == "SSP-IO-001 warning")
    }

    /// An override whose folder is gone (an unmounted volume: the bookmark still resolves, the folder cannot be read),
    /// with the system location valid and a screenshot in it and on the Desktop.
    private func pausedByMissingOverride(_ rig: Notice8TRig) async throws -> (system: URL, inSystem: URL, onDesktop: URL, chosen: URL) {
        let system = try rig.temp.folder("home/Pictures/System")
        let chosen = try rig.temp.folder("home/Pictures/Chosen")
        rig.preferences.set(location: system.path)
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.base.hide(chosen)
        try await rig.launch()
        let inSystem = try rig.arrive(in: system)
        let onDesktop = try rig.arrive(in: rig.desktop)
        rig.source.emit(.changed([inSystem, onDesktop]))
        rig.event(inSystem)
        try await Task.sleep(for: .milliseconds(150))
        return (system, inSystem, onDesktop, chosen)
    }

    @Test("OC-2003 a missing override pauses pickup: neither the system-folder nor the Desktop screenshot is stored; Notices SSP-IO-003; status Paused")
    func missingOverridePauses() async throws {
        // given: a valid system location S, an override folder that is gone
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }

        // when: one screenshot is renamed into S and one into the Desktop
        let scene = try await pausedByMissingOverride(rig)

        // then: count delta 0, SSP-IO-003 shown, status Paused, and nothing is watching
        #expect(try await rig.freshCount() == 0)
        #expect(try await rig.freshCount(named: scene.inSystem.lastPathComponent) == 0)
        #expect(try await rig.freshCount(named: scene.onDesktop.lastPathComponent) == 0)
        #expect(rig.presenter.notices(.sspIo003).count == 1)
        #expect(await rig.watcher.status == .paused)
        #expect(rig.source.running.isEmpty)
    }

    @Test("OC-2003 control: when the override folder comes back the held-back system-folder screenshot is stored and the Desktop one still is not")
    func overrideReturnsResumesPickup() async throws {
        // given: paused by a missing override, two screenshots added meanwhile
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        let scene = try await pausedByMissingOverride(rig)
        #expect(try await rig.freshCount() == 0)

        // when: the override folder is reachable again and a tick re-resolves
        rig.fileSystem.base.unhide(scene.chosen)
        let inChosen = try rig.arrive(in: scene.chosen)
        rig.clock.advance(by: 35)
        await rig.watcher.tickFired()
        rig.event(inChosen)

        // then: only the screenshot in the chosen folder arrives; the paused-time files in S and Desktop never do
        #expect(try await rig.waitForFreshCount(1))
        #expect(try await rig.freshCount(named: inChosen.lastPathComponent) == 1)
        #expect(try await rig.freshCount(named: scene.inSystem.lastPathComponent) == 0)
        #expect(try await rig.freshCount(named: scene.onDesktop.lastPathComponent) == 0)
        #expect(await rig.watcher.status == .watching)
        #expect(rig.presenter.notices(.sspIo003).isEmpty, "the paused Notice clears once pickup resumes")
    }

    @Test("OC-2079 SSP-IO-003 reads the paused text, as a warning on the menu bar, without a path or file name")
    func pausedText() async throws {
        // given: an override whose folder is missing
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        let scene = try await pausedByMissingOverride(rig)

        // when: the Notice is read
        let notices = rig.presenter.notices(.sspIo003)

        // then: one Notice, the literal text, warning severity, no path, no file name, no HUD
        #expect(notices.count == 1)
        #expect(notices.first?.message == Self.pausedText)
        #expect(notices.first?.severity == .warning)
        notice8TExpectNoLeak(
            notices.first?.message ?? "", rig: rig,
            fileNames: [scene.inSystem.lastPathComponent, scene.chosen.lastPathComponent, "Pictures"])
        #expect(rig.presenter.hudCount == 0)
    }

    /// Desktop refused (no execute or read permission, standing in for Files and Folders off), a screenshot already in
    /// it, pickup started and an event naming the file.
    private func accessDenied(_ rig: Notice8TRig) async throws -> URL {
        let file = try rig.arrive(in: rig.desktop)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        try await rig.launch()
        rig.event(file)
        try await Task.sleep(for: .milliseconds(150))
        return file
    }

    @Test("OC-2012 a refused folder imports nothing, shows the access Notice without path or file name, status Needs access")
    func accessDeniedImportsNothing() async throws {
        // given: Desktop watched but refused, a qualifying screenshot in it
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }

        // when: Flotsam starts and an event names the screenshot
        let file = try await accessDenied(rig)

        // then: count delta 0, the one Notice with the literal text, no path or name, status Needs access
        #expect(try await rig.freshCount() == 0)
        let notices = rig.presenter.notices(.sspPrm001)
        #expect(notices.count == 1)
        #expect(notices.first?.message == Self.needsAccessText)
        notice8TExpectNoLeak(notices.first?.message ?? "", rig: rig, fileNames: [file.lastPathComponent, "Desktop"])
        #expect(await rig.watcher.status == .needsAccess)
    }

    @Test("OC-2012 control: once access is allowed the screenshot is stored and the access Notice clears")
    func accessGrantedImports() async throws {
        // given: refused, nothing stored, the Notice standing
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        let file = try await accessDenied(rig)
        #expect(try await rig.freshCount() == 0)
        #expect(rig.presenter.notices(.sspPrm001).count == 1)

        // when: access is allowed and the next tick lists the folder
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.desktop.path)
        rig.clock.advance(by: 35)
        await rig.watcher.tickFired()

        // then: the screenshot arrives (by that name), the Notice is gone, status Watching
        #expect(try await rig.waitForFreshCount(1))
        #expect(try await rig.freshCount(named: file.lastPathComponent) == 1)
        #expect(rig.presenter.notices(.sspPrm001).isEmpty)
        #expect(await rig.watcher.status == .watching)
    }

    @Test("OC-2076 SSP-PRM-001 reads the access text as a warning on the menu bar, with no path or file name, and no HUD")
    func accessDeniedText() async throws {
        // given: folder access refused
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        let file = try await accessDenied(rig)

        // when: the Notice is read
        let notices = rig.presenter.notices(.sspPrm001)

        // then: literal text, warning severity (the dot), nothing identifying the folder or file, one entry in all
        #expect(notices.count == 1)
        #expect(notices.first?.message == Self.needsAccessText)
        #expect(notices.first?.severity == .warning)
        #expect(rig.presenter.current.count == 1)
        notice8TExpectNoLeak(notices.first?.message ?? "", rig: rig, fileNames: [file.lastPathComponent, "Desktop"])
        #expect(rig.presenter.hudCount == 0)
    }
}

// MARK: - Batch 2: polling fallback and the unsettled file (OC-2016, 2083, 2035, 2078)

@Suite("FRD002Notice polling and unsettled files", .serialized)
struct FRD002NoticePollingTests {
    private static let pollingText = "Live screenshot watching isn't working. Flotsam is checking every 5 seconds instead."

    @Test("OC-2016 with no event stream a screenshot is found by the 5 s poll, not before; SSP-OS-001 is raised once and status stays Watching")
    func pollingFindsScreenshot() async throws {
        // given: the event stream cannot start
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        rig.source.setFailing(true)
        try await rig.launch()
        #expect(await notice8TEventually { rig.presenter.notices(.sspOs001).count == 1 })
        #expect(await rig.watcher.status == .watching)

        // when: a screenshot is renamed into the Desktop, and no time passes
        let file = try rig.arrive(in: rig.desktop)
        try await Task.sleep(for: .milliseconds(150))

        // then: nothing yet (no event arrives and the poll has not fired)
        #expect(try await rig.freshCount() == 0)

        // when: 5 s of clock time pass
        await rig.poll()

        // then: exactly that screenshot is stored (count 0 -> 1), and the Notice is still the one
        #expect(try await rig.waitForFreshCount(1))
        #expect(try await rig.freshCount(named: file.lastPathComponent) == 1)
        #expect(try await rig.freshRows().first?.kind == .screenshot)
        #expect(rig.presenter.notices(.sspOs001).count == 1)

        // when: another 5 s pass with nothing new
        await rig.poll()
        try await Task.sleep(for: .milliseconds(150))

        // then: still one item, still one Notice
        #expect(try await rig.freshCount() == 1)
        #expect(rig.presenter.notices(.sspOs001).count == 1)
    }

    @Test("OC-2016 the poll is paced at 5 s: a poll is waiting on a 5 s sleep and 4 s of clock time does not fire it")
    func pollingIsFiveSeconds() async throws {
        // given: polling fallback running
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        rig.source.setFailing(true)
        try await rig.launch()
        #expect(await notice8TEventually { rig.clock.sleeping(seconds: 5) >= 1 })
        let file = try rig.arrive(in: rig.desktop)

        // when: 4 s pass
        rig.clock.advance(by: 4)
        try await Task.sleep(for: .milliseconds(150))

        // then: the 5 s sleeper is still asleep and nothing was stored
        #expect(rig.clock.sleeping(seconds: 5) >= 1)
        #expect(try await rig.freshCount() == 0)

        // when: the remaining 1 s passes
        rig.clock.advance(by: 1)

        // then: the poll fires and finds the file
        #expect(try await rig.waitForFreshCount(1))
        #expect(try await rig.freshCount(named: file.lastPathComponent) == 1)
    }

    @Test("OC-2016 control: with a working event stream no polling Notice is raised and no 5 s poll runs")
    func streamWorksNoFallback() async throws {
        // given: a stream that starts
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }

        // when: pickup starts
        try await rig.launch()
        try await Task.sleep(for: .milliseconds(150))

        // then: one live watch, no SSP-OS-001, no 5 s sleeper, status Watching
        #expect(rig.source.running.count == 1)
        #expect(!rig.presenter.everHadNotice)
        #expect(rig.clock.sleeping(seconds: 5) == 0)
        #expect(await rig.watcher.status == .watching)
    }

    @Test("OC-2083 SSP-OS-001 reads the polling text as a warning on the menu bar, with no path or file name, and no HUD")
    func pollingText() async throws {
        // given: the stream cannot start
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        rig.source.setFailing(true)
        try await rig.launch()
        #expect(await notice8TEventually { rig.presenter.notices(.sspOs001).count == 1 })

        // when: the Notice is read
        let notices = rig.presenter.notices(.sspOs001)

        // then: literal text, warning severity (the dot), no path, no file name, no HUD, the only entry
        #expect(notices.first?.message == Self.pollingText)
        #expect(notices.first?.severity == .warning)
        #expect(rig.presenter.current.count == 1)
        notice8TExpectNoLeak(notices.first?.message ?? "", rig: rig, fileNames: ["Desktop"])
        #expect(rig.presenter.hudCount == 0)
    }
}

@Suite("FRD002Notice unsettled file", .serialized)
struct FRD002NoticeUnsettledTests {
    /// A screenshot that keeps growing for the whole stability window (and beyond), named by an event.
    private func growingShot(_ rig: Notice8TRig) async throws -> URL {
        try await rig.launch()
        let file = try rig.arrive(in: rig.desktop)
        rig.fileSystem.beginGrowing(file, for: 10_000, clock: rig.clock)
        rig.event(file)
        return file
    }

    @Test("OC-2035 a file still changing after 5 s is skipped: SSP-IO-002 is logged at info level, nothing is stored")
    func unsettledIsLoggedOnly() async throws {
        // given: Desktop watched, a file that never stops changing
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }

        // when: an event names it and the stability window runs out
        let file = try await growingShot(rig)
        #expect(await notice8TEventually { !rig.logged("SSP-IO-002").isEmpty })

        // then: one info-level SSP-IO-002 record, count delta 0 (fresh instance), the file itself untouched
        let records = rig.logged("SSP-IO-002")
        #expect(records.count == 1)
        #expect(records.first?.headline == "SSP-IO-002 info")
        #expect(records.first?.level == .info)
        #expect(try await rig.freshCount() == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("OC-2078 SSP-IO-002 never reaches the user: no Notice, no HUD, no warning dot, now or after the file settles")
    func unsettledNeverSurfaces() async throws {
        // given: a file that never settles, skipped
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        _ = try await growingShot(rig)
        #expect(await notice8TEventually { !rig.logged("SSP-IO-002").isEmpty })

        // then: nothing was drawn for the user
        #expect(!rig.presenter.everHadNotice)
        #expect(rig.presenter.current.isEmpty)
        #expect(rig.presenter.hudCount == 0)

        // when: the file settles and the app becomes active (a reconcile scan)
        rig.fileSystem.stopGrowing()
        await rig.watcher.didBecomeActive()
        #expect(try await rig.waitForFreshCount(1))

        // then: still nothing drawn
        #expect(!rig.presenter.everHadNotice)
        #expect(rig.presenter.hudCount == 0)
    }

    @Test("OC-2078 once the file settles the scan finds it exactly once: one item, one copy, found by name")
    func settledFileFoundOnce() async throws {
        // given: skipped as unsettled, nothing stored
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        let file = try await growingShot(rig)
        #expect(await notice8TEventually { !rig.logged("SSP-IO-002").isEmpty })
        #expect(try await rig.freshCount() == 0)

        // when: it stops changing, the app becomes active, and a second scan follows
        rig.fileSystem.stopGrowing()
        await rig.watcher.didBecomeActive()
        #expect(try await rig.waitForFreshCount(1))
        await rig.watcher.didBecomeActive()
        try await Task.sleep(for: .milliseconds(200))

        // then: still exactly one item for that name, imported once (copy count 1)
        let rows = try await rig.freshRows()
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .screenshot)
        #expect(try await rig.freshCount(named: file.lastPathComponent) == 1)
        let id = try #require(rows.first?.id)
        #expect(try await rig.fresh().content(of: id).get().copyCount == 1)
    }

    @Test("OC-2035 control: a file that is stable from the first check is stored and logs no SSP-IO-002")
    func stableFileNoUnsettledLog() async throws {
        // given: Desktop watched
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        try await rig.launch()

        // when: an ordinary screenshot arrives
        let file = try rig.arrive(in: rig.desktop)
        rig.event(file)

        // then: it is stored (0 -> 1) and no SSP-IO-002 was logged
        #expect(try await rig.waitForFreshCount(1))
        #expect(try await rig.freshCount(named: file.lastPathComponent) == 1)
        #expect(rig.logged("SSP-IO-002").isEmpty)
    }
}

// MARK: - Batch 3: rejected content (OC-2063, 2082, 2064, 2081)

@Suite("FRD002Notice rejected content", .serialized)
struct FRD002NoticeRejectedTests {
    private static let tooLargeText = "A screenshot was too large to import (over 100 MB)."
    /// The per-item ceiling, as a literal: 100 MiB.
    private static let ceiling = 104_857_600

    /// A real PNG followed by zeros up to exactly `total` bytes: still decodes, but has the size under test.
    private func padded(to total: Int) -> Data {
        var data = notice8TPNG()
        data.append(Data(count: total - data.count))
        return data
    }

    @Test("OC-2063 a screenshot one byte over 100 MiB is not stored and raises SSP-LIM-001 once, even after another scan")
    func oversizeNotStored() async throws {
        // given: Desktop watched
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        try await rig.launch()

        // when: a file of 104,857,601 bytes is renamed in and named by an event
        let file = try rig.arrive(in: rig.desktop, bytes: padded(to: Self.ceiling + 1))
        rig.event(file)

        // then: count delta 0 (fresh instance), the Notice appears once, the original is left alone
        #expect(await notice8TEventually { rig.presenter.notices(.sspLim001).count == 1 })
        #expect(try await rig.freshCount() == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))

        // when: a reconcile scan runs again
        await rig.watcher.didBecomeActive()
        try await Task.sleep(for: .milliseconds(300))

        // then: still nothing stored and still one Notice (the file is not retried)
        #expect(try await rig.freshCount() == 0)
        #expect(rig.presenter.notices(.sspLim001).count == 1)
        #expect(rig.presenter.current.count == 1)
    }

    @Test("OC-2063 boundary: a screenshot of exactly 100 MiB is stored and raises no SSP-LIM-001")
    func atCeilingStored() async throws {
        // given: Desktop watched
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        try await rig.launch()

        // when: a file of exactly 104,857,600 bytes arrives
        let file = try rig.arrive(in: rig.desktop, bytes: padded(to: Self.ceiling))
        rig.event(file)

        // then: stored (0 -> 1) by name, and no Notice of any kind
        #expect(try await rig.waitForFreshCount(1))
        #expect(try await rig.freshCount(named: file.lastPathComponent) == 1)
        #expect(!rig.presenter.everHadNotice)
    }

    @Test("OC-2082 SSP-LIM-001 reads 'over 100 MB' as a warning on the menu bar, with no path or file name, and no HUD")
    func oversizeText() async throws {
        // given: an oversize screenshot rejected
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        try await rig.launch()
        let file = try rig.arrive(in: rig.desktop, "Screenshot too-big-name.png", bytes: padded(to: Self.ceiling + 1))
        rig.event(file)
        #expect(await notice8TEventually { rig.presenter.notices(.sspLim001).count == 1 })

        // when: the Notice is read
        let notices = rig.presenter.notices(.sspLim001)

        // then: {limit} renders as 100 MB; warning severity; no path or file name; no HUD
        #expect(notices.first?.message == Self.tooLargeText)
        #expect(notices.first?.severity == .warning)
        notice8TExpectNoLeak(notices.first?.message ?? "", rig: rig, fileNames: ["too-big-name", "Desktop"])
        #expect(rig.presenter.hudCount == 0)
    }

    @Test("OC-2064 bytes that are not an image are not stored; SSP-VAL-001 is logged at info level once, even after another scan")
    func notAnImageLoggedOnly() async throws {
        // given: Desktop watched
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        try await rig.launch()

        // when: a qualifying file whose bytes are text is renamed in and named by an event
        let file = try rig.arrive(in: rig.desktop, bytes: Data("this is not an image at all".utf8))
        rig.event(file)

        // then: one info-level SSP-VAL-001 record, count delta 0, the original untouched
        #expect(await notice8TEventually { !rig.logged("SSP-VAL-001").isEmpty })
        #expect(rig.logged("SSP-VAL-001").count == 1)
        #expect(rig.logged("SSP-VAL-001").first?.headline == "SSP-VAL-001 info")
        #expect(rig.logged("SSP-VAL-001").first?.level == .info)
        #expect(try await rig.freshCount() == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))

        // when: a reconcile scan runs again
        await rig.watcher.didBecomeActive()
        try await Task.sleep(for: .milliseconds(300))

        // then: not retried: still one record, still nothing stored
        #expect(rig.logged("SSP-VAL-001").count == 1)
        #expect(try await rig.freshCount() == 0)
    }

    @Test("OC-2081 SSP-VAL-001 never reaches the user, and pickup carries on: the next real screenshot is stored")
    func notAnImageNeverSurfaces() async throws {
        // given: a non-image file rejected
        let rig = try Notice8TRig()
        defer { rig.cleanUp() }
        try await rig.launch()
        let bad = try rig.arrive(in: rig.desktop, bytes: Data("not an image".utf8))
        rig.event(bad)
        #expect(await notice8TEventually { !rig.logged("SSP-VAL-001").isEmpty })

        // then: nothing drawn for the user
        #expect(!rig.presenter.everHadNotice)
        #expect(rig.presenter.current.isEmpty)
        #expect(rig.presenter.hudCount == 0)

        // when: a real screenshot arrives afterwards
        let good = try rig.arrive(in: rig.desktop)
        rig.event(good)

        // then: only the real one is stored (0 -> 1), by name; the bad name never is; still nothing drawn
        #expect(try await rig.waitForFreshCount(1))
        #expect(try await rig.freshCount(named: good.lastPathComponent) == 1)
        #expect(try await rig.freshCount(named: bad.lastPathComponent) == 0)
        #expect(!rig.presenter.everHadNotice)
        #expect(rig.presenter.hudCount == 0)
    }
}
