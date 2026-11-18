import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// FRD-002 watcher contract, batch 8T: OC-2005, 2014, 2026-2032, 2034, 2075, 2086 (.claude/oracle/frd-002-contract.json).
// Files and extended attributes are real, in a temporary tree. Time, the folder event stream, ingest, the watermark
// and the notices are the fakes of WatcherSupport.swift. A folder event is `rig.event(url)`.
//
// Not testable here (a real system is needed): the TCC prompt itself (OC-2014), `defaults write` + a real relaunch
// (OC-2005, OC-2030: modelled by the preference fake), the Settings pane's "Use system setting" button and folder label
// (OC-2086, App/Flotsam/Settings/GeneralPane.swift). See each test for what is covered.

private func watcher8TReal(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

/// A launch some time ago: files born "now" are newer than the watermark.
private func watcher8TEarlierLaunch() -> Date { Date().addingTimeInterval(-10) }

/// `com.apple.screencapture` with a settable `name`, which the shared `MutablePreferences` does not offer.
private final class Watcher8TPreferences: ScreenCapturePreferences, @unchecked Sendable {
    private let lock = NSLock()
    private var locationValue: String?
    private var nameValue: String?
    init(location: String? = nil, name: String? = nil) { locationValue = location; nameValue = name }
    func location() -> String? { lock.withLock { locationValue } }
    func name() -> String? { lock.withLock { nameValue } }
}

/// A watcher over the rig's fakes but with preferences (and optionally a file system) of this suite's own.
private func watcher8TMakeWatcher(
    _ rig: WatcherRig, preferences: any ScreenCapturePreferences, fileSystem: (any FileSystemPort)? = nil
) -> ScreenshotWatcher {
    let notices = rig.notices
    return ScreenshotWatcher(
        fileSystem: fileSystem ?? rig.fileSystem, preferences: preferences, home: rig.home, clock: rig.clock,
        eventSource: rig.source, settings: rig.settings, ingest: rig.ingest, watermarkStore: rig.marks,
        report: { notices.raise($0) }, clear: { notices.clear($0) }, pollTick: rig.pollTick, sink: rig.sink)
}

/// The file system with one file's `fileInfo` scripted like a screenshot written in 0.5 s chunks (6 chunks = 3 s of
/// writing, then final). The real file holds the final bytes. A folder event is emitted at chunk 2, 4 and 6, as the
/// system does while a file grows. Records the writing time elapsed at every read of the bytes.
private final class Watcher8TGrowingFileSystem: FileSystemPort, @unchecked Sendable {
    static let chunks = 6
    static let chunkSeconds = 0.5

    private let base: ProbedFileSystem
    private let clock: SteppedClock
    private let onChunk: @Sendable (URL) -> Void
    private let lock = NSLock()
    private var targetPath: String?
    private var began = Date()
    private var emitted: Set<Int> = []
    private var readTimes: [TimeInterval] = []

    init(base: ProbedFileSystem, clock: SteppedClock, onChunk: @escaping @Sendable (URL) -> Void) {
        self.base = base
        self.clock = clock
        self.onChunk = onChunk
    }

    /// Writing of `url` starts now.
    func begin(_ url: URL) {
        lock.withLock {
            targetPath = watcher8TReal(url)
            began = clock.now()
            emitted = []
            readTimes = []
        }
    }

    /// Seconds of writing elapsed at each read of the file's bytes.
    var elapsedAtEachRead: [TimeInterval] { lock.withLock { readTimes } }

    func fileInfo(at url: URL) -> FileInfo? {
        guard let real = base.fileInfo(at: url) else { return nil }
        let (isTarget, started) = lock.withLock { (watcher8TReal(url) == targetPath, began) }
        guard isTarget else { return real }
        let elapsed = clock.now().timeIntervalSince(started)
        let chunk = min(Self.chunks, Int(elapsed / Self.chunkSeconds + 1e-6))
        if chunk > 0, chunk % 2 == 0, lock.withLock({ emitted.insert(chunk).inserted }) { onChunk(url) }
        return FileInfo(
            byteSize: real.byteSize * chunk / Self.chunks,
            modifiedAt: started.addingTimeInterval(Double(chunk) * Self.chunkSeconds),
            createdAt: real.createdAt, kind: real.kind)
    }

    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> {
        let (isTarget, started) = lock.withLock { (watcher8TReal(url) == targetPath, began) }
        if isTarget { lock.withLock { readTimes.append(clock.now().timeIntervalSince(started)) } }
        return base.readFileNoFollow(at: url)
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
    func availableCapacity(at url: URL) -> Int64? { base.availableCapacity(at: url) }
}

@Suite("FRD-002 watcher contract (8T)", .serialized)
struct Watcher8TContractTests {
    // MARK: - OC-2005

    /// Red if `~` is not expanded against the home folder (the watch would land on the Desktop or a literal "~" path),
    /// or if the hidden temporary name were imported alongside the final one.
    @Test("OC-2005 a literal-tilde system location is expanded to the home folder and a renamed-in screenshot is imported once")
    func tildeLocationIsExpanded() async throws {
        // given: system location "~/Pictures/Tilde" (literal tilde), the folder exists, pickup on, no override
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        let tilde = try rig.temp.folder("home/Pictures/Tilde")
        rig.preferences.set(location: "~/Pictures/Tilde")
        await rig.watcher.start()
        #expect(await rig.watcher.status == .watching)
        #expect(rig.source.running.map { watcher8TReal($0.folder) } == [watcher8TReal(tilde)])

        // when: a qualifying file arrives by atomic rename from a hidden temp name
        let name = "Screenshot oc-\(UUID().uuidString).png"
        let hidden = try rig.shot(in: tilde, ".\(name)")
        rig.event(hidden)
        let final = tilde.appendingPathComponent(name)
        try FileManager.default.moveItem(at: hidden, to: final)
        rig.event(final)
        let onDesktop = try rig.shot(in: rig.desktop)
        rig.event(onDesktop)

        // then: exactly one item, for the final name; the Desktop file is not picked up
        #expect(await eventually { rig.ingest.names.count >= 1 })
        await letItSettle()
        #expect(rig.ingest.names == [name])
        #expect(rig.ingest.candidates.map(\.kind) == [.screenshot])
    }

    // MARK: - OC-2014

    /// Red if a refused folder is only retried on the 30 s tick (the file would wait for the tick), or if activation
    /// does not clear the standing SSP-PRM-001 once the folder lists.
    @Test("OC-2014 granting access then activating resumes pickup at once, with no tick")
    func accessGrantedThenActivation() async throws {
        // given: SSP-PRM-001 standing because the watched folder is refused
        let rig = try WatcherRig(watermark: nil)
        defer { rig.cleanUp() }
        let folder = try rig.temp.folder("home/Pictures/W")
        rig.use(folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        await rig.watcher.start()
        #expect(await rig.watcher.status == .needsAccess)
        #expect(rig.notices.standing(.sspPrm001))
        await rig.watcher.didBecomeActive()
        #expect(await rig.watcher.status == .needsAccess, "still refused: activation alone does not pretend")
        #expect(rig.notices.raised(.sspPrm001) == 1)

        // when: access is granted, Flotsam is activated at once, and a file is renamed in 1 s later
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        await rig.watcher.didBecomeActive()
        rig.clock.advance(by: 1)
        let name = "Screenshot oc-\(UUID().uuidString).png"
        let hidden = try rig.shot(in: folder, ".\(name)")
        let final = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: hidden, to: final)
        rig.event(final)

        // then: watching again, the notice cleared, and the file imported once (no 30 s tick was needed)
        #expect(await rig.watcher.status == .watching)
        #expect(rig.notices.cleared(.sspPrm001) == 1)
        #expect(await eventually { rig.ingest.names == [name] })
        await letItSettle()
        #expect(rig.ingest.names == [name])
    }

    // MARK: - OC-2026

    /// Red if the extension test is case-sensitive or drops any of jpeg, tif, tiff or heic.
    @Test("OC-2026 .PNG .JPEG .jpeg .TIF .tiff and .heic are all imported as screenshots; .gif is not")
    func imageExtensions() async throws {
        // given: pickup on, capture mode Active, folder listable
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let extensions = ["PNG", "JPEG", "jpeg", "TIF", "tiff", "heic"]
        let names = extensions.map { "Screenshot oc-\(UUID().uuidString).\($0)" }

        // when: the six are added, with a .gif that has the attribute
        var urls = try names.map { try rig.shot(in: rig.desktop, $0) }
        urls.append(try rig.shot(in: rig.desktop, "Screenshot oc-\(UUID().uuidString).gif"))
        rig.source.emit(.changed(urls))

        // then: count +6, each found by name, each of kind screenshot; the .gif adds nothing
        #expect(await eventually { rig.ingest.names.count >= 6 })
        await letItSettle()
        #expect(rig.ingest.names.count == 6)
        #expect(Set(rig.ingest.names) == Set(names))
        #expect(rig.ingest.candidates.allSatisfy { $0.kind == .screenshot })
    }

    // MARK: - OC-2027

    /// Red if recognition falls back to the name for a file that carries the attribute, or ignores the attribute.
    @Test("OC-2027 an unprefixed file with the screen-capture attribute is imported; without it, it is not")
    func attributeWithoutPrefix() async throws {
        // given: pickup on and a watched folder
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()

        // when: 'capture-<uuid>.png' with the attribute, and an otherwise identical file without it
        let marked = try rig.shot(in: rig.desktop, "capture-\(UUID().uuidString).png", attribute: true)
        let unmarked = try rig.shot(in: rig.desktop, "capture-\(UUID().uuidString).png", attribute: nil)
        rig.source.emit(.changed([marked, unmarked]))

        // then: exactly the marked one, of kind screenshot (count +1)
        #expect(await eventually { rig.ingest.names.count >= 1 })
        await letItSettle()
        #expect(rig.ingest.names == [marked.lastPathComponent])
        #expect(rig.ingest.candidates.map(\.kind) == [.screenshot])
    }

    // MARK: - OC-2028

    /// Red if a missing attribute rejects a file instead of falling back to the name prefix, or if "Screen Shot"
    /// (the pre-12 name) is dropped from the prefixes.
    @Test("OC-2028 with no attribute, 'Screenshot ' and 'Screen Shot ' names are imported; an unrelated name is not")
    func prefixWithoutAttribute() async throws {
        // given: pickup on and a watched folder
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()

        // when: both prefixed names without the attribute, plus an unrelated name without it
        let a = try rig.shot(in: rig.desktop, "Screenshot a-\(UUID().uuidString).png", attribute: nil)
        let b = try rig.shot(in: rig.desktop, "Screen Shot b-\(UUID().uuidString).png", attribute: nil)
        let other = try rig.shot(in: rig.desktop, "Holiday d-\(UUID().uuidString).png", attribute: nil)
        rig.source.emit(.changed([a, b, other]))

        // then: count +2, exactly the two prefixed names
        #expect(await eventually { rig.ingest.names.count >= 2 })
        await letItSettle()
        #expect(rig.ingest.names.count == 2)
        #expect(Set(rig.ingest.names) == [a.lastPathComponent, b.lastPathComponent])
    }

    // MARK: - OC-2029

    /// Red if the name prefix is applied to a file whose attribute is present and false.
    @Test("OC-2029 a 'Screenshot' name with the attribute present and false is not imported (count delta 0)")
    func attributeFalseBeatsPrefix() async throws {
        // given: pickup on and a watched folder
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()

        // when: the false-attribute file, and a control with the same style of name but no attribute
        let falseFlag = try rig.shot(in: rig.desktop, "Screenshot c-\(UUID().uuidString).png", attribute: false)
        let control = try rig.shot(in: rig.desktop, "Screenshot c-\(UUID().uuidString).png", attribute: nil)
        rig.source.emit(.changed([falseFlag, control]))
        #expect(await eventually { rig.ingest.names.count >= 1 })
        await rig.watcher.didBecomeActive()
        await letItSettle()

        // then: only the control is imported, by live event and by the reconcile scan alike
        #expect(rig.ingest.names == [control.lastPathComponent])
    }

    // MARK: - OC-2030

    /// Red if the custom `name` of com.apple.screencapture is not read, or is not applied as a prefix.
    @Test("OC-2030 with screencapture name 'Grab', 'Grab <uuid>.png' without the attribute is imported")
    func customPrefixImported() async throws {
        // given: name = Grab, Flotsam relaunched (a new watcher), watching the Desktop
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        let watcher = watcher8TMakeWatcher(rig, preferences: Watcher8TPreferences(name: "Grab"))
        await watcher.start()

        // when: a Grab file and an unrelated file, neither with the attribute
        let grab = try rig.shot(in: rig.desktop, "Grab \(UUID().uuidString).png", attribute: nil)
        let other = try rig.shot(in: rig.desktop, "Holiday \(UUID().uuidString).png", attribute: nil)
        rig.source.emit(.changed([grab, other]))

        // then: exactly the Grab file (count +1), of kind screenshot
        #expect(await eventually { rig.ingest.names.count >= 1 })
        await letItSettle()
        #expect(rig.ingest.names == [grab.lastPathComponent])
        #expect(rig.ingest.candidates.map(\.kind) == [.screenshot])
    }

    /// Red if 'Grab' were treated as a system prefix regardless of the preference.
    @Test("OC-2030 without the custom name, the same 'Grab <uuid>.png' is not imported")
    func customPrefixNeedsThePreference() async throws {
        // given: no custom name set
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()

        // when: a Grab file without the attribute, then a marker that must import
        let grab = try rig.shot(in: rig.desktop, "Grab \(UUID().uuidString).png", attribute: nil)
        let marker = try rig.shot(in: rig.desktop)
        rig.source.emit(.changed([grab, marker]))

        // then: only the marker is imported
        #expect(await eventually { rig.ingest.names.count >= 1 })
        await letItSettle()
        #expect(rig.ingest.names == [marker.lastPathComponent])
    }

    // MARK: - OC-2031

    /// Prefixes below are the `Screenshot` entries of screencaptureui's Localizable.loctable read on this machine
    /// (macOS 26.x, /System/Library/CoreServices/screencaptureui.app): fr, de, es, nl (with its soft hyphen), it, ja,
    /// zh_CN, zh_TW, ko. Red if any of those languages' prefix is missing from `ScreenshotNamePrefixes.system`.
    @Test("OC-2031 the macOS prefixes of French, German, Spanish, Dutch, Italian, Japanese, Chinese (Simplified, Traditional) and Korean are imported with no attribute")
    func localizedPrefixes() async throws {
        // given: pickup on, nine fixtures named with each language's prefix
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let prefixes = [
            "Capture d\u{2019}écran", "Bildschirmfoto", "Captura de pantalla", "Scherm\u{00AD}afbeelding", "Screenshot",
            "スクリーンショット", "截屏", "截圖", "스크린샷",
        ]
        let names = prefixes.map { "\($0) \(UUID().uuidString).png" }

        // when: each is added without the attribute, with an unrelated name as control
        var urls = try names.map { try rig.shot(in: rig.desktop, $0, attribute: nil) }
        urls.append(try rig.shot(in: rig.desktop, "Holiday \(UUID().uuidString).png", attribute: nil))
        rig.source.emit(.changed(urls))

        // then: all 9 imported (count +9), the control is not
        #expect(await eventually { rig.ingest.names.count >= 9 })
        await letItSettle()
        #expect(rig.ingest.names.count == 9)
        #expect(Set(rig.ingest.names.map { $0.precomposedStringWithCanonicalMapping })
            == Set(names.map { $0.precomposedStringWithCanonicalMapping }))
    }

    /// The other Traditional Chinese catalogue entry (zh_HK).
    @Test("OC-2031 the Hong Kong Traditional Chinese prefix is imported with no attribute")
    func traditionalChineseHongKong() async throws {
        // given: pickup on
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()

        // when: a zh_HK-prefixed file with no attribute
        let file = try rig.shot(in: rig.desktop, "螢幕截圖 \(UUID().uuidString).png", attribute: nil)
        rig.event(file)

        // then: imported once
        #expect(await eventually { rig.ingest.names.count == 1 })
        await letItSettle()
        #expect(rig.ingest.names.count == 1)
    }

    // MARK: - OC-2032

    /// Red if a hidden name is imported, or if the rename is not picked up (event or scan) or is picked up twice.
    @Test("OC-2032 a hidden '.Screenshot' file imports nothing for 5 s; renamed visible it imports exactly once")
    func hiddenThenRenamed() async throws {
        // given: pickup on and a watched folder
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()

        // when: the hidden file with the attribute appears (an event for it, and another as it is touched) and 5 s pass
        let name = "Screenshot d-\(UUID().uuidString).png"
        let hidden = try rig.shot(in: rig.desktop, ".\(name)")
        rig.event(hidden)
        rig.clock.advance(by: 2.5)
        rig.event(hidden)
        rig.clock.advance(by: 2.5)
        await letItSettle()

        // then: nothing imported while hidden
        #expect(rig.ingest.names.isEmpty)

        // when: it is renamed to its final name
        let final = rig.desktop.appendingPathComponent(name)
        try FileManager.default.moveItem(at: hidden, to: final)
        rig.event(final)

        // then: exactly one item (count +1), also after a following scan
        #expect(await eventually { rig.ingest.names == [name] })
        await rig.watcher.didBecomeActive()
        await letItSettle()
        #expect(rig.ingest.names == [name])
    }

    // MARK: - OC-2034

    /// Red if the watcher reads the file before it stops changing (elapsed at read < 3 s), or imports it more than once
    /// for the burst of events a growing file raises.
    @Test("OC-2034 a screenshot written in chunks for 3 s is read and imported once, after it stops changing")
    func chunkedWriteImportedOnce() async throws {
        // given: pickup on, a file system that reports the file growing in 6 chunks of 0.5 s
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        let growing = Watcher8TGrowingFileSystem(base: rig.fileSystem, clock: rig.clock) { rig.event($0) }
        let watcher = watcher8TMakeWatcher(rig, preferences: rig.preferences, fileSystem: growing)
        await watcher.start()

        // when: the file starts being written, and events arrive as it grows
        let file = try rig.shot(in: rig.desktop)
        growing.begin(file)
        rig.event(file)

        // then: one item; the bytes were read only once the 3 s of writing were over; later scans add nothing
        #expect(await eventually { rig.ingest.names.count >= 1 })
        await letItSettle()
        await watcher.didBecomeActive()
        await letItSettle()
        #expect(rig.ingest.names == [file.lastPathComponent])
        #expect(growing.elapsedAtEachRead.count == 1)
        #expect((growing.elapsedAtEachRead.first ?? 0) >= 3.0, "read while the file was still changing")
    }

    // MARK: - OC-2075

    /// The AC-002-05 seven-file set in the folder a place resolves to; returns every URL.
    private func watcher8TFixtureSet(in folder: URL, rig: WatcherRig) throws -> [URL] {
        let sub = try rig.temp.folder(folder.path.replacingOccurrences(of: rig.temp.root.path + "/", with: "") + "/Sub")
        return [
            try rig.shot(in: folder, "Screenshot shot.png"),
            try rig.shot(in: folder, "Screenshot shot.jpg"),
            try rig.shot(in: folder, "Screenshot shot.mov"),
            try rig.shot(in: folder, "Screenshot shot.pdf"),
            try rig.shot(in: folder, ".Screenshot temp.png"),
            try rig.shot(in: sub, "Screenshot nested.png"),
            try rig.shot(in: folder, "holiday.png", attribute: nil),
        ]
    }

    /// Red if the recognition rule differs by where the folder came from (system, Desktop fallback, override), or by
    /// how the file reached the watcher (live event or launch scan).
    @Test("OC-2075 the seven-file set imports the same 2 files from the system folder, the Desktop fallback and an override")
    func sameRuleEverywhere() async throws {
        for place in ["system", "desktop-fallback", "override"] {
            for delivery in ["event", "scan"] {
                // given: a fresh run (history cleared) with the folder chosen the way this place does it
                let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
                defer { rig.cleanUp() }
                let folder: URL
                switch place {
                case "system":
                    folder = try rig.temp.folder("home/Pictures/System")
                    rig.use(folder)
                case "desktop-fallback":
                    folder = rig.desktop
                    rig.preferences.set(location: rig.home.appendingPathComponent("Pictures/Gone").path)
                default:
                    folder = try rig.temp.folder("home/Pictures/Override")
                    rig.settings.set(try FolderOverride.choosing(folder).get(), for: SettingKeys.screenshotsFolderOverride)
                }
                var urls: [URL] = []
                if delivery == "scan" { urls = try watcher8TFixtureSet(in: folder, rig: rig) }

                // when: the set is present at launch (scan) or added while running (events)
                await rig.watcher.start()
                if delivery == "event" {
                    urls = try watcher8TFixtureSet(in: folder, rig: rig)
                    rig.source.emit(.changed(urls))
                }

                // then: exactly the png and the jpg screenshot
                let expected = ["Screenshot shot.jpg", "Screenshot shot.png"]
                #expect(await eventually { rig.ingest.names.count >= 2 }, "\(place)/\(delivery)")
                await letItSettle()
                #expect(rig.ingest.names.sorted() == expected, "\(place)/\(delivery)")
                let expectedStatus: ScreenshotPickupStatus = place == "desktop-fallback" ? .usingDesktop : .watching
                #expect(await rig.watcher.status == expectedStatus, "\(place)/\(delivery)")
            }
        }
    }

    // MARK: - OC-2086

    /// Covers the behavior behind UI-002-2: choosing a folder at run time makes the override a value ("Use system
    /// setting" is enabled exactly when the value is not `.none`, GeneralPane.swift:35), it resolves to O, and pickup
    /// moves to O. UNTESTABLE-AT-PACKAGE: the SwiftUI button's visibility and the label text (App target, no seam).
    @Test("OC-2086 choosing folder O sets a resolvable override and a screenshot added to O is imported")
    func chosenFolderIsWatched() async throws {
        // given: no override, pickup running on the Desktop
        let rig = try WatcherRig(watermark: watcher8TEarlierLaunch())
        defer { rig.cleanUp() }
        #expect(rig.settings.value(SettingKeys.screenshotsFolderOverride) == .none)
        await rig.watcher.start()
        let chosen = try rig.temp.folder("Pictures/O")

        // when: folder O is chosen and a qualifying screenshot (plus a Desktop one) is added
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        await rig.watcher.settingsDidChange()
        let inO = try rig.shot(in: chosen)
        let onDesktop = try rig.shot(in: rig.desktop)
        rig.source.emit(.changed([inO, onDesktop]))

        // then: the override is set and points at O, pickup watches only O, and only the O screenshot is imported
        let stored = rig.settings.value(SettingKeys.screenshotsFolderOverride)
        #expect(stored != .none)
        #expect(stored.resolvedURL.map(watcher8TReal) == watcher8TReal(chosen))
        #expect(rig.source.running.map { watcher8TReal($0.folder) } == [watcher8TReal(chosen)])
        #expect(await eventually { rig.ingest.names.count >= 1 })
        await letItSettle()
        #expect(rig.ingest.names == [inO.lastPathComponent])
    }
}
