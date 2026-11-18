import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamScreenshots

// FRD-002 audit A: gap tests for the oracle assertions (.claude/oracle/frd-002-contract.json) that
// ScreenshotWatcherTests.swift does not fully prove. Everything runs on WatcherRig (WatcherSupport.swift): a real
// temporary tree, fake clock / folder events / ingest / watermark / notices. No pasteboard, no real defaults, no app.
//
// Not testable at the package seam (see the audit report): the menu-bar dot, Settings labels, the 'Imported 3' HUD,
// the fs_usage trace itself, and a real disk-image eject. Their package-level proxies are tested here instead.

private func auditAEarlierLaunch() -> Date { Date().addingTimeInterval(-10) }

private func auditAPath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

/// Every file-system call the watcher makes, by path, so "no access to the folder" is an assertion on what happened.
private final class AuditAAccessLog: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var paths: [String] = []

    private func note(_ url: URL) { lock.withLock { paths.append(auditAPath(url)) } }

    /// How many calls touched `folder` or anything inside it.
    func touches(under folder: URL) -> Int {
        let root = auditAPath(folder)
        return lock.withLock { paths.filter { $0 == root || $0.hasPrefix(root + "/") }.count }
    }

    func fileExists(at url: URL) -> Bool { note(url); return real.fileExists(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { note(url); return real.fileInfo(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { note(url); return real.contentsOfDirectory(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { note(url); return real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { note(source); return real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { note(source); return real.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { note(url); return real.removeItem(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { note(url); return real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { note(url); return real.writeFile(data, to: url, permissions: permissions) }
    func readFile(at url: URL) -> FlotsamResult<Data> { note(url); return real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { note(url); return real.readFileNoFollow(at: url) }
    func availableCapacity(at url: URL) -> Int64? { note(url); return real.availableCapacity(at: url) }
}

@Suite("FRD-002 audit A: gap tests", .serialized)
struct FRD002AuditATests {
    // MARK: Location (OC-2001, 2006, 2007, 2009, 2010)

    // Fails if: a `~/…` system location is not expanded against home, or the hidden temp name macOS renames from is
    // imported (twice, or instead of the final name).
    @Test("OC-2001: a ~/Pictures/Shots location is watched; a rename from a hidden temp name imports once")
    func tildeLocationAndAtomicRename() async throws {
        // given: location "~/Pictures/Shots", the folder existing, pickup on by default
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        let shots = try rig.temp.folder("home/Pictures/Shots")
        rig.preferences.set(location: "~/Pictures/Shots")
        await rig.watcher.start()
        #expect(await rig.watcher.status == .watching)
        #expect(rig.source.running.map { auditAPath($0.folder) } == [auditAPath(shots)])

        // when: a screenshot is written under a hidden temp name, then renamed into place
        let temp = try rig.shot(in: shots, ".Screenshot oc-1.png")
        rig.event(temp)
        await letItSettle()
        #expect(rig.ingest.names.isEmpty, "the hidden temp name is not a screenshot")
        let final = shots.appendingPathComponent("Screenshot oc-1.png")
        try FileManager.default.moveItem(at: temp, to: final)
        rig.source.emit(.changed([temp, final]))

        // then: exactly one item, under the final name
        #expect(await eventually { rig.ingest.names == ["Screenshot oc-1.png"] })
        await letItSettle()
        #expect(rig.ingest.names == ["Screenshot oc-1.png"])
        #expect(rig.notices.entries.isEmpty)
    }

    // Fails if: a system location that is a regular file is treated as usable, or the Desktop is not watched, or
    // SSP-IO-001 is not raised exactly once. (The existing 'FR-002-01' no-location test covers an ABSENT location, a different given.)
    @Test("OC-2006: a system location that is a regular file falls back to the Desktop with SSP-IO-001")
    func locationIsARegularFile() async throws {
        // given: pickup on, no override, location pointing at a regular file
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        let notAFolder = try rig.temp.file("home/not-a-folder.txt")
        rig.preferences.set(location: notAFolder.path)
        await rig.watcher.start()

        // when: a screenshot arrives on the Desktop (rename from a hidden temp name)
        let temp = try rig.shot(in: rig.desktop, ".Screenshot oc-6.png")
        let final = rig.desktop.appendingPathComponent("Screenshot oc-6.png")
        try FileManager.default.moveItem(at: temp, to: final)
        rig.source.emit(.changed([temp, final]))

        // then: imported once, SSP-IO-001 standing once, status 'Using Desktop', only the Desktop watched
        #expect(await eventually { rig.ingest.names == ["Screenshot oc-6.png"] })
        #expect(await rig.watcher.status == .usingDesktop)
        #expect(rig.notices.raised(.sspIo001) == 1)
        #expect(rig.notices.standing(.sspIo001))
        #expect(rig.source.running.map { auditAPath($0.folder) } == [auditAPath(rig.desktop)])
    }

    // The real disk-image eject is not reachable from a package test; `ProbedFileSystem.hide` makes the folder vanish
    // exactly as an unmounted volume does (no file info, listing fails). Fails if the watcher keeps watching a
    // vanished system folder, or does not fall back to the Desktop.
    @Test("OC-2007: a system folder that vanishes (unmounted volume) falls back to the Desktop within one tick")
    func systemFolderVanishes() async throws {
        // given: the system location is a folder on a volume that is mounted
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        let volumeFolder = try rig.temp.folder("Volumes/Image/Shots")
        rig.use(volumeFolder)
        await rig.watcher.start()
        #expect(await rig.watcher.status == .watching)
        #expect(rig.notices.raised(.sspIo001) == 0)

        // when: the volume goes away and 35 s pass, then a screenshot lands on the Desktop
        rig.fileSystem.hide(volumeFolder)
        await rig.tick()
        let onVolume = try rig.shot(in: volumeFolder)
        let onDesktop = try rig.shot(in: rig.desktop)
        rig.source.emit(.changed([onVolume, onDesktop]))

        // then: the Desktop file is imported (count +1), the vanished folder's file is not, SSP-IO-001 is raised once
        #expect(await eventually { rig.ingest.names == [onDesktop.lastPathComponent] })
        await letItSettle()
        #expect(rig.ingest.names == [onDesktop.lastPathComponent])
        #expect(await rig.watcher.status == .usingDesktop)
        #expect(rig.notices.raised(.sspIo001) == 1)
        #expect(rig.source.running.map { auditAPath($0.folder) } == [auditAPath(rig.desktop)])
    }

    // Fails if: after a location change the new watch is not the one delivering, or the old folder is still imported
    // from. (The existing 'OC-2009' test checks the reconcile scan; it never delivers a live event on the new watch.)
    @Test("OC-2009: after a location change a file in N is imported live and a file in W is not")
    func locationChangeLiveDelivery() async throws {
        // given: W is the watched system location
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        let folderW = try rig.temp.folder("Pictures/W")
        let folderN = try rig.temp.folder("Pictures/N")
        rig.use(folderW)
        await rig.watcher.start()
        let oldWatch = try #require(rig.source.watches.last)

        // when: the location changes to N, 30 s pass (no restart: the same watcher), then files land in N and in W
        rig.use(folderN)
        await rig.tick()
        let newWatch = try #require(rig.source.running.last)
        let inN = try rig.shot(in: folderN)
        let inW = try rig.shot(in: folderW)
        rig.source.emit(.changed([inN, inW]), on: newWatch)

        // then: only N's file (count +1); the old watch is stopped and exactly one new watch exists
        #expect(await eventually { rig.ingest.names == [inN.lastPathComponent] })
        await letItSettle()
        #expect(rig.ingest.names == [inN.lastPathComponent])
        #expect(oldWatch.stopped)
        #expect(rig.source.running.count == 1)
        #expect(rig.source.watches.count == 2)
    }

    // Fails if: activation re-resolves but the new stream is not live (no event delivery), or re-resolution waits for
    // the 30 s tick. The clock is not advanced, so the 2.0 s budget cannot be met by a tick.
    @Test("OC-2010: activation re-resolves at once and a file in N is imported within 2 s, with no tick")
    func activationThenLiveImport() async throws {
        // given: W watched
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        let folderW = try rig.temp.folder("Pictures/W")
        let folderN = try rig.temp.folder("Pictures/N")
        rig.use(folderW)
        await rig.watcher.start()
        let before = rig.clock.now()

        // when: the location changes to N (not yet noticed), the app is activated, a file lands in N
        rig.use(folderN)
        #expect(rig.source.running.map { auditAPath($0.folder) } == [auditAPath(folderW)], "no re-resolution before activation")
        await rig.watcher.didBecomeActive()
        let inN = try rig.shot(in: folderN)
        rig.event(inN)

        // then: imported within 2 s real time, and no 30 s tick elapsed to make it so
        #expect(await eventually(timeout: .seconds(2)) { rig.ingest.names == [inN.lastPathComponent] })
        // (the 0.5 s stability check moves the stepped clock a little; a 30 s tick would move it by 30)
        #expect(rig.clock.now().timeIntervalSince(before) < 30, "no tick elapsed")
        #expect(rig.source.running.map { auditAPath($0.folder) } == [auditAPath(folderN)])
    }

    // MARK: Access and fallback (OC-2017)

    // Fails if: leaving the polling fallback clears the notice but leaves no live stream (existing test stops at
    // `running.count == 1`), or the notice stays standing.
    @Test("OC-2017: after the fallback ends the notice is clear and a new screenshot arrives on the new stream")
    func fallbackEndsAndStreamDelivers() async throws {
        // given: the event stream cannot be created, SSP-OS-001 raised
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        rig.source.setFailing(true)
        await rig.watcher.start()
        #expect(await eventually { rig.notices.standing(.sspOs001) })

        // when: the failure is removed and the next tick re-creates the stream
        rig.source.setFailing(false)
        await rig.tick()
        #expect(await eventually { !rig.notices.standing(.sspOs001) })
        let stream = try #require(rig.source.running.last)
        let shot = try rig.shot(in: rig.desktop)
        rig.source.emit(.changed([shot]), on: stream)

        // then: notice cleared exactly once, the screenshot is found within 2 s
        #expect(await eventually(timeout: .seconds(2)) { rig.ingest.names == [shot.lastPathComponent] })
        #expect(rig.notices.cleared(.sspOs001) == 1)
        #expect(rig.notices.raised(.sspOs001) == 1)
    }

    // MARK: Filtering (OC-2018, OC-2025)

    // Fails if: a symlink or a subfolder file is imported by an event OR by the activation scan. The existing
    // 'OC-2018' test sends one event for the link only and never the subfolder, never a scan.
    @Test("OC-2018: neither a subfolder file nor a symbolic link is imported, by event or by scan")
    func subfolderAndSymlinkIgnored() async throws {
        // given: W watched, a qualifying screenshot outside W
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        let outside = try rig.shot(in: try rig.temp.folder("elsewhere"))
        await rig.watcher.start()

        // when: a screenshot goes into W/sub and a link to the outside one is created in W
        let nested = try rig.shot(in: try rig.temp.folder("home/Desktop/sub"))
        let link = rig.desktop.appendingPathComponent("Screenshot link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        rig.source.emit(.changed([nested, link]))
        await rig.watcher.didBecomeActive()
        await rig.tick()
        await letItSettle()

        // then: delta 0, and the watcher is demonstrably alive (a real file is still picked up)
        #expect(rig.ingest.candidates.isEmpty)
        let real = try rig.shot(in: rig.desktop)
        rig.event(real)
        #expect(await eventually { rig.ingest.names == [real.lastPathComponent] })
    }

    // Fails if: a PDF with the screen-capture attribute (the oracle's own file set) is imported. The existing
    // 'OC-2025' test uses a .gif where the oracle names a PDF.
    @Test("OC-2025: png and jpg import, and the .mov, PDF, hidden temp, subfolder and attribute-less files do not")
    func exactOracleFileSet() async throws {
        // given: W watched
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()

        // when: W receives the seven files of the oracle
        let png = try rig.shot(in: rig.desktop, "Screenshot a.png")
        let jpg = try rig.shot(in: rig.desktop, "Screenshot b.jpg")
        let mov = try rig.shot(in: rig.desktop, "Screen Recording c.mov")
        let pdf = try rig.shot(in: rig.desktop, "Screenshot d.pdf")
        let hidden = try rig.shot(in: rig.desktop, ".Screenshot x.png")
        let nested = try rig.shot(in: try rig.temp.folder("home/Desktop/sub"), "Screenshot e.png")
        let holiday = try rig.shot(in: rig.desktop, "holiday.png", attribute: nil)
        rig.source.emit(.changed([png, jpg, mov, pdf, hidden, nested, holiday]))
        #expect(await eventually { rig.ingest.names.count == 2 })
        await rig.watcher.didBecomeActive()
        await letItSettle()

        // then: exactly 2 items (count +2), by event and by the scan
        #expect(Set(rig.ingest.names) == ["Screenshot a.png", "Screenshot b.jpg"])
        #expect(rig.ingest.names.count == 2)
    }

    // MARK: Settings and modes (OC-2019, 2020, 2021, 2022, 2023, 2024)

    // Fails if: enabling pickup does not move the watermark to the time it was enabled. The existing 'OC-2019' test
    // births its files 60 s BEFORE the launch watermark, so it passes even if the watermark never advanced.
    @Test("OC-2019: files added while pickup was off, born after launch, are not imported when it is turned on")
    func offThenOnDiscriminates() async throws {
        // given: pickup off from launch (watermark earlier than anything below)
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.start()

        // when: 3 screenshots, newer than the launch watermark, are added; pickup is turned on; time passes
        try (0..<3).forEach { _ in try rig.shot(in: rig.desktop) }
        rig.clock.advance(by: 60)
        rig.settings.set(true, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.settingsDidChange()
        await rig.watcher.didBecomeActive()
        await rig.tick()
        await letItSettle()

        // then: none imported (delta 0); a screenshot taken afterwards still is
        #expect(rig.ingest.candidates.isEmpty)
        #expect(await rig.watcher.status == .watching)
        let after = try rig.shot(in: rig.desktop, born: rig.clock.now().addingTimeInterval(1))
        rig.event(after)
        #expect(await eventually { rig.ingest.names == [after.lastPathComponent] })
    }

    // Given 'pickup on' (the existing 'OC-2020' test runs with pickup off). The 'Imported 3' HUD text is a UI string:
    // `importRecent` returns the count the HUD shows, which is asserted here.
    @Test("OC-2020: with pickup on, Import recent imports the 3 files, then a second run creates nothing")
    func backfillWithPickupOn() async throws {
        // given: pickup on, 3 screenshots older than the watermark (so live pickup did not take them)
        let rig = try WatcherRig(watermark: Date())
        defer { rig.cleanUp() }
        let old = rig.clock.now().addingTimeInterval(-3600)
        let shots = try (0..<3).map { _ in try rig.shot(in: rig.desktop, born: old) }
        await rig.watcher.start()
        await letItSettle()
        #expect(rig.ingest.candidates.isEmpty)

        // when / then: first run creates 3 (the HUD count), second creates 0
        #expect(await rig.watcher.importRecentCount() == 3)
        #expect(Set(rig.ingest.names) == Set(shots.map(\.lastPathComponent)))
        #expect(rig.ingest.names.count == 3)
        #expect(await rig.watcher.importRecentCount() == 0)
    }

    // Fails if the default of `screenshots.enabled` becomes false, or the watcher does not start on defaults. The
    // Settings screen's toggle itself is a SwiftUI view bound to this same value (no package seam).
    @Test("OC-2021: on a fresh install Pick up screenshots is on, and the watcher starts watching")
    func freshInstallDefaultsOn() async throws {
        // given: nothing set
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }

        // when / then
        #expect(rig.settings.value(SettingKeys.screenshotsEnabled) == true)
        #expect(await rig.watcher.status == .off, "before launch nothing is watched")
        await rig.watcher.start()
        #expect(await rig.watcher.status == .watching)
        #expect(rig.source.running.count == 1)
    }

    // The fs_usage trace is not reachable here; every file-system call the watcher can make goes through
    // `FileSystemPort`, so a recording port is the same observation one layer down. The control half proves the
    // recorder can see an access (so the zero is not a dead recorder).
    @Test("OC-2022: with pickup off no file-system call touches the screenshot folders, across every entry point")
    func noFolderAccessWhileOff() async throws {
        // given: pickup off from launch, a system folder holding screenshots
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        let shots = try rig.temp.folder("Pictures/Shots")
        rig.use(shots)
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        let log = AuditAAccessLog()
        let notices = rig.notices
        func makeWatcher() -> ScreenshotWatcher {
            ScreenshotWatcher(
                fileSystem: log, preferences: rig.preferences, home: rig.home, clock: rig.clock, eventSource: rig.source,
                settings: rig.settings, ingest: rig.ingest, watermarkStore: rig.marks,
                report: { notices.raise($0) }, clear: { notices.clear($0) }, pollTick: rig.pollTick, sink: rig.sink)
        }
        let watcher = makeWatcher()

        // when: it runs, ticks, is activated, wakes and is told about unrelated settings, while screenshots arrive
        await watcher.start()
        try (0..<3).forEach { _ in try rig.shot(in: shots) }
        for _ in 0..<4 {
            await watcher.tickFired()
            await watcher.didBecomeActive()
            await watcher.didWake()
            await watcher.settingsDidChange()
        }

        // then: the screenshot folders were never touched and nothing was imported
        #expect(log.touches(under: shots) == 0)
        #expect(log.touches(under: rig.desktop) == 0)
        #expect(rig.source.watches.isEmpty)
        #expect(rig.ingest.candidates.isEmpty)

        // control: with pickup on, the same recorder does see the folder
        rig.settings.set(true, for: SettingKeys.screenshotsEnabled)
        let enabled = makeWatcher()
        await enabled.start()
        #expect(log.touches(under: shots) > 0)
    }

    // Fails if: resuming imports what was taken during the pause, checked before AND after the relaunch (the
    // existing 'OC-2023' test only checks after both), and still imports what is taken afterwards.
    @Test("OC-2023: a screenshot taken while paused is not imported after resume, nor after relaunch")
    func pausedThenResumedThenRelaunched() async throws {
        // given: capture Paused, W watched
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        await rig.watcher.settingsDidChange()

        // when: a screenshot is added, capture resumes
        let during = try rig.shot(in: rig.desktop)
        rig.event(during)
        rig.clock.advance(by: 60)
        rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
        await rig.watcher.settingsDidChange()
        await rig.watcher.didBecomeActive()
        await rig.tick()
        await letItSettle()

        // then: not imported after resume; nor after quit and relaunch
        #expect(rig.ingest.candidates.isEmpty)
        rig.relaunch()
        await rig.watcher.start()
        await rig.watcher.didBecomeActive()
        await letItSettle()
        #expect(rig.ingest.candidates.isEmpty)
        let after = try rig.shot(in: rig.desktop, born: rig.clock.now().addingTimeInterval(1))
        rig.event(after)
        #expect(await eventually { rig.ingest.names == [after.lastPathComponent] })
    }

    // The existing 'OC-2020' test shows Import recent works in a non-importing mode but never asserts that nothing is
    // imported in Curated. 'Save Clipboard is invoked' is the clipboard path (no watcher seam, no NSPasteboard here);
    // activation is the watcher's side of that sentence.
    @Test("OC-2024: in Curated mode a screenshot is not imported, by event, activation or tick")
    func curatedImportsNothing() async throws {
        // given: capture mode Curated, W watched
        let rig = try WatcherRig(watermark: auditAEarlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(CaptureMode.curated, for: SettingKeys.captureMode)
        await rig.watcher.start()
        #expect(await rig.watcher.status == .watching)

        // when: a screenshot is added, and the app is activated (as after Save Clipboard)
        let shot = try rig.shot(in: rig.desktop)
        rig.event(shot)
        await rig.watcher.didBecomeActive()
        await rig.tick()
        await letItSettle()

        // then: delta 0, including after returning to Active
        #expect(rig.ingest.candidates.isEmpty)
        rig.clock.advance(by: 60)
        rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
        await rig.watcher.settingsDidChange()
        await rig.watcher.didBecomeActive()
        await letItSettle()
        #expect(rig.ingest.candidates.isEmpty)
    }
}
