import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamScreenshots

// ScreenshotWatcher behavior (FRD-002), one test per observable the blind oracle (.claude/oracle/frd-002-contract.json)
// names. The file tree is real; time, events, ingest, watermark and notices are the fakes in WatcherSupport.swift.

/// A launch some time ago: files born "now" are newer than the watermark, files born 60 s before it are not.
private func earlierLaunch() -> Date { Date().addingTimeInterval(-10) }

private func realPath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

@Suite("ScreenshotWatcher: what is watched", .serialized)
struct WatcherLocationTests {
    @Test("OC-2001/2004/2006/2072: the system folder is watched, the Desktop and others are not")
    func systemFolderIsWatched() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let shots = try rig.temp.folder("Pictures/Shots")
        rig.use(shots)
        await rig.watcher.start()

        #expect(await rig.watcher.status == .watching)
        #expect(rig.source.running.map { realPath($0.folder) } == [realPath(shots)])

        let wanted = try rig.shot(in: shots)
        let onDesktop = try rig.shot(in: rig.desktop)
        rig.source.emit(.changed([wanted, onDesktop]))
        #expect(await eventually { rig.ingest.names == [wanted.lastPathComponent] })
        await letItSettle()
        #expect(rig.ingest.names == [wanted.lastPathComponent])
    }

    @Test("FR-002-01: with no system location the Desktop is watched with no warning")
    func desktopByDefault() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        #expect(await rig.watcher.status == .watching)
        #expect(rig.notices.entries.isEmpty)
        let shot = try rig.shot(in: rig.desktop)
        rig.event(shot)
        #expect(await eventually { rig.ingest.names == [shot.lastPathComponent] })
    }

    @Test("OC-2002/2008/2077: a missing system folder falls back to the Desktop, noticed once per change of state")
    func missingSystemFolderUsesDesktop() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let missing = rig.temp.root.appendingPathComponent("gone")
        rig.preferences.set(location: missing.path)
        await rig.watcher.start()

        #expect(await rig.watcher.status == .usingDesktop)
        #expect(rig.notices.raised(.sspIo001) == 1)
        for _ in 0..<6 { await rig.tick() }
        #expect(rig.notices.raised(.sspIo001) == 1, "re-resolving does not re-raise an unchanged state")

        let shot = try rig.shot(in: rig.desktop)
        rig.event(shot)
        #expect(await eventually { rig.ingest.names == [shot.lastPathComponent] })

        // The folder returns: watch it, clear the notice.
        let back = try rig.temp.folder("gone")
        await rig.tick()
        #expect(await rig.watcher.status == .watching)
        #expect(rig.notices.cleared(.sspIo001) == 1)
        #expect(rig.source.running.map { realPath($0.folder) } == [realPath(back)])
    }

    @Test("OC-2009/2011/2073: a changed location is picked up at the next tick, and the files already there are scanned")
    func locationChangeRebuilds() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let first = try rig.temp.folder("Pictures/First")
        let second = try rig.temp.folder("Pictures/Second")
        rig.use(first)
        await rig.watcher.start()
        let oldWatch = try #require(rig.source.watches.last)

        let waiting = try rig.shot(in: second)
        rig.use(second)
        await rig.tick()

        #expect(oldWatch.stopped)
        #expect(rig.source.running.map { realPath($0.folder) } == [realPath(second)])
        #expect(await eventually { rig.ingest.names == [waiting.lastPathComponent] }, "reconcile scan of the rebuilt watcher")

        // The old stream is gone; a late event from it is not trusted.
        let stray = try rig.shot(in: first)
        rig.source.emit(.changed([stray]), on: oldWatch)
        await letItSettle()
        #expect(rig.ingest.names == [waiting.lastPathComponent])
    }

    @Test("OC-2010: activating the app re-resolves at once")
    func activationReresolves() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let first = try rig.temp.folder("Pictures/First")
        let second = try rig.temp.folder("Pictures/Second")
        rig.use(first)
        await rig.watcher.start()
        rig.use(second)
        await rig.watcher.didBecomeActive()
        #expect(rig.source.running.map { realPath($0.folder) } == [realPath(second)])
    }

    @Test("OC-2004/2072/2079/2080: an override wins, goes unusable -> paused with SSP-IO-003, and resumes when it returns")
    func overrideFolderLifecycle() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let system = try rig.temp.folder("Pictures/System")
        let chosen = try rig.temp.folder("Pictures/Chosen")
        rig.use(system)
        let override = try FolderOverride.choosing(chosen).get()
        rig.settings.set(override, for: SettingKeys.screenshotsFolderOverride)
        await rig.watcher.start()

        #expect(await rig.watcher.status == .watching)
        #expect(rig.source.running.map { realPath($0.folder) } == [realPath(chosen)])
        let inChosen = try rig.shot(in: chosen)
        let inSystem = try rig.shot(in: system)
        let onDesktop = try rig.shot(in: rig.desktop)
        rig.source.emit(.changed([inChosen, inSystem, onDesktop]))
        #expect(await eventually { rig.ingest.names == [inChosen.lastPathComponent] })

        // The override folder becomes unusable (an unmounted volume): paused, nothing else is watched.
        rig.fileSystem.hide(chosen)
        await rig.tick()
        #expect(await rig.watcher.status == .paused)
        #expect(rig.notices.raised(.sspIo003) == 1)
        #expect(rig.source.running.isEmpty)
        await rig.tick()
        #expect(rig.notices.raised(.sspIo003) == 1)

        rig.fileSystem.unhide(chosen)
        await rig.tick()
        #expect(await rig.watcher.status == .watching)
        #expect(rig.notices.cleared(.sspIo003) == 1)
        let after = try rig.shot(in: chosen)
        rig.event(after)
        #expect(await eventually { rig.ingest.names.contains(after.lastPathComponent) })
    }

    @Test("OC-2085: clearing the override returns to the system location")
    func clearingOverride() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let system = try rig.temp.folder("Pictures/System")
        let chosen = try rig.temp.folder("Pictures/Chosen")
        rig.use(system)
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        await rig.watcher.start()
        rig.settings.set(FolderOverride.none, for: SettingKeys.screenshotsFolderOverride)
        await rig.watcher.settingsDidChange()
        #expect(rig.source.running.map { realPath($0.folder) } == [realPath(system)])
    }
}

@Suite("ScreenshotWatcher: what is imported", .serialized)
struct WatcherImportTests {
    @Test("OC-2025/2033: only qualifying direct children are imported")
    func onlyQualifying() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let png = try rig.shot(in: rig.desktop, "Screenshot a.png")
        let jpg = try rig.shot(in: rig.desktop, "Screenshot b.jpg")
        let movie = try rig.shot(in: rig.desktop, "Screenshot c.mov")
        let gif = try rig.shot(in: rig.desktop, "Screenshot d.gif")
        let hidden = try rig.shot(in: rig.desktop, ".Screenshot e.png")
        let plain = try rig.shot(in: rig.desktop, "holiday.png", attribute: nil)
        let nested = try rig.shot(in: try rig.temp.folder("home/Desktop/sub"), "Screenshot f.png")
        rig.source.emit(.changed([png, jpg, movie, gif, hidden, plain, nested]))
        #expect(await eventually { rig.ingest.names.count == 2 })
        await letItSettle()
        #expect(Set(rig.ingest.names) == ["Screenshot a.png", "Screenshot b.jpg"])
    }

    @Test("OC-2018: a symbolic link is not imported")
    func symbolicLinkIgnored() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let outside = try rig.shot(in: try rig.temp.folder("elsewhere"))
        await rig.watcher.start()
        let link = rig.desktop.appendingPathComponent("Screenshot link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        rig.event(link)
        await letItSettle()
        #expect(rig.ingest.names.isEmpty)
    }

    @Test("OC-2049: repeated events for one file import it once")
    func repeatedEventsAreIdempotent() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let shot = try rig.shot(in: rig.desktop)
        rig.event(shot)
        rig.event(shot)
        #expect(await eventually { rig.ingest.names.count == 1 })
        rig.event(shot)
        await rig.watcher.didBecomeActive()
        await letItSettle()
        #expect(rig.ingest.candidates.count == 1)
    }

    @Test("FR-002-09: the item is a screenshot dated by the file, from the screenshot source, counted as a copy")
    func candidateShape() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let born = Date().addingTimeInterval(-3)
        let shot = try rig.shot(in: rig.desktop, born: born)
        rig.event(shot)
        #expect(await eventually { rig.ingest.candidates.count == 1 })
        let candidate = try #require(rig.ingest.candidates.first)
        #expect(candidate.source?.bundleId == "com.apple.screencaptureui")
        #expect(candidate.countsAsCopy)
        #expect(abs(candidate.occurredAt.timeIntervalSince(born)) < 1)
    }

    @Test("OC-2037/2039/2040: a launch imports what is newer than the watermark and nothing older, and not again")
    func launchReconcile() async throws {
        let mark = Date().addingTimeInterval(-100)
        let rig = try WatcherRig(watermark: mark)
        defer { rig.cleanUp() }
        let fresh = try rig.shot(in: rig.desktop, born: mark.addingTimeInterval(30))
        try rig.shot(in: rig.desktop, born: mark.addingTimeInterval(-60))
        await rig.watcher.start()
        #expect(await eventually { rig.ingest.names == [fresh.lastPathComponent] })
        #expect(try #require(rig.marks.value) > mark)

        await rig.relaunch()
        await rig.watcher.start()
        await letItSettle()
        #expect(rig.ingest.candidates.count == 1, "the watermark persisted across the launch")
    }

    @Test("FR-002-08: a new library imports nothing and only records the watermark")
    func firstLaunchSeedsWatermark() async throws {
        let rig = try WatcherRig(watermark: nil)
        defer { rig.cleanUp() }
        try rig.shot(in: rig.desktop, born: Date().addingTimeInterval(-20))
        await rig.watcher.start()
        await letItSettle()
        #expect(rig.ingest.candidates.isEmpty)
        #expect(rig.marks.value != nil)
        let later = try rig.shot(in: rig.desktop)
        rig.event(later)
        #expect(await eventually { rig.ingest.names == [later.lastPathComponent] })
    }

    @Test("OC-2041/2074: waking from sleep scans; a file older than the watermark stays out")
    func wakeScans() async throws {
        let mark = Date().addingTimeInterval(-100)
        let rig = try WatcherRig(watermark: mark)
        defer { rig.cleanUp() }
        let old = try rig.shot(in: rig.desktop, born: mark.addingTimeInterval(-60))
        await rig.watcher.start()
        let during = try rig.shot(in: rig.desktop)
        await rig.watcher.didWake()
        #expect(await eventually { rig.ingest.names == [during.lastPathComponent] })
        #expect(!rig.ingest.names.contains(old.lastPathComponent))
    }

    @Test("OC-2066: a burst imports every file with at most 2 in flight")
    func burstIsPaced() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let shots = try (0..<20).map { _ in try rig.shot(in: rig.desktop) }
        rig.source.emit(.changed(shots))
        #expect(await eventually(timeout: .seconds(20)) { rig.ingest.candidates.count == 20 })
        #expect(rig.ingest.peakInFlight <= ScreenshotWatcher.maxInFlight)
        #expect(rig.ingest.peakInFlight == ScreenshotWatcher.maxInFlight, "the bound is used, not just respected")
    }

    @Test("OC-2064/2063: a rejected file is noticed once and never retried")
    func rejectedIsFinal() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let bad = try rig.shot(in: rig.desktop)
        rig.ingest.fail(bad.lastPathComponent, with: FlotsamError(.sspVal001, "Not an image"))
        rig.event(bad)
        #expect(await eventually { rig.notices.raised(.sspVal001) == 1 })
        for _ in 0..<3 { await rig.watcher.didBecomeActive() }
        await letItSettle()
        #expect(rig.ingest.candidates.count == 1)
        #expect(rig.notices.raised(.sspVal001) == 1)
    }

    @Test("OC-2069: the log carries outcome and size, never the file name")
    func logHasNoFileName() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let shot = try rig.shot(in: rig.desktop, "Screenshot zq7marker.png")
        rig.event(shot)
        #expect(await eventually { !rig.sink.records.isEmpty })
        for record in rig.sink.records {
            let text = [record.headline, record.publicContext, record.privateContext, record.message ?? ""].joined(separator: " ")
            #expect(!text.contains("zq7marker"))
        }
    }
}

@Suite("ScreenshotWatcher: retry list (FR-002-07)", .serialized)
struct WatcherRetryTests {
    /// A file that can never be read, born inside the watermark window so every scan selects it.
    @discardableResult
    private func unreadable(_ rig: WatcherRig, _ name: String = "Screenshot stuck.png") throws -> URL {
        let url = try rig.shot(in: rig.desktop, name)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        return url
    }

    @Test("OC-2036: an unreadable file is tried 4 times in all, however many scans find it")
    func triesAreBounded() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        try unreadable(rig)
        await rig.watcher.start()
        for scan in 1...6 {
            _ = await eventually { rig.notices.raised(.sspIo002) >= min(scan, 4) }
            await rig.watcher.didBecomeActive()
        }
        await letItSettle()
        #expect(rig.ingest.candidates.isEmpty)
        #expect(rig.notices.raised(.sspIo002) == 4)
    }

    @Test("FR-002-07: the 30 s tick retries too, inside the same budget")
    func tickRetriesShareTheBudget() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        try unreadable(rig)
        await rig.watcher.start()
        for tick in 1...6 {
            _ = await eventually { rig.notices.raised(.sspIo002) >= min(tick, 4) }
            await rig.tick()
        }
        await letItSettle()
        #expect(rig.notices.raised(.sspIo002) == 4)
    }

    @Test("FR-002-07: a file that settles on a retry is imported")
    func settlesOnRetry() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let url = try unreadable(rig)
        await rig.watcher.start()
        _ = await eventually { rig.notices.raised(.sspIo002) >= 1 }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        await rig.watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.names == [url.lastPathComponent] })
    }

    @Test("OC-2065: a stuck file does not hold up the others")
    func stuckFileDoesNotBlock() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let stuck = try unreadable(rig)
        await rig.watcher.start()
        let good = try (0..<5).map { _ in try rig.shot(in: rig.desktop) }
        rig.source.emit(.changed([stuck] + good))
        #expect(await eventually { rig.ingest.names.count == 5 })
        #expect(Set(rig.ingest.names) == Set(good.map(\.lastPathComponent)))
    }
}

@Suite("ScreenshotWatcher: settings and modes (FR-002-05)", .serialized)
struct WatcherSettingsTests {
    @Test("OC-2019/2022: pickup off touches no folder; turning it on imports nothing from the time it was off")
    func offThenOn() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.start()
        #expect(await rig.watcher.status == .off)
        #expect(rig.source.watches.isEmpty)
        #expect(rig.fileSystem.listingCount == 0)

        try (0..<3).forEach { _ in try rig.shot(in: rig.desktop, born: rig.clock.now().addingTimeInterval(-60)) }
        rig.clock.advance(by: 60)
        rig.settings.set(true, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.settingsDidChange()
        #expect(await rig.watcher.status == .watching)
        await letItSettle()
        #expect(rig.ingest.candidates.isEmpty)
    }

    @Test("OC-2020/2056: Import recent screenshots imports the files once; a second run creates nothing")
    func backfill() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        let shots = try (0..<3).map { _ in try rig.shot(in: rig.desktop) }
        #expect(await rig.watcher.importRecentCount() == 3, "available while pickup is off")
        #expect(Set(rig.ingest.names) == Set(shots.map(\.lastPathComponent)))
        #expect(rig.ingest.candidates.allSatisfy { !$0.countsAsCopy })
        #expect(await rig.watcher.importRecentCount() == 0)
    }

    @MainActor
    private final class HUDLog { var messages: [String] = [] }

    @Test("OC-2062/2020/2055: the one import action shows Imported {n} with the real count, 0 included")
    func importShowsCountHUD() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        _ = try (0..<3).map { _ in try rig.shot(in: rig.desktop) }
        let log = await HUDLog()
        await rig.watcher.importRecentAnnouncingWithin { message in log.messages.append(message) }
        await rig.watcher.importRecentAnnouncingWithin { message in log.messages.append(message) }
        #expect(await log.messages == ["Imported 3", "Imported 0"])
    }

    @Test("FR-002-12: two overlapping Import actions show exactly one HUD, with the real count")
    func overlappingImportsShowOneHUD() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let shots = try (0..<20).map { _ in try rig.shot(in: rig.desktop) }
        #expect(shots.count == 20)
        let log = await HUDLog()
        async let first: Void = rig.watcher.importRecentAnnouncingWithin { message in log.messages.append(message) }
        async let second: Void = rig.watcher.importRecentAnnouncingWithin { message in log.messages.append(message) }
        _ = await (first, second)
        #expect(await log.messages == ["Imported 20"])
    }

    @Test("FR-002-12: live pickup goes ahead of a running backfill")
    func livePickupBeatsBackfill() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let now = Date()
        for index in 0..<500 {
            try rig.shot(in: rig.desktop, "Screenshot old \(index).png", born: now.addingTimeInterval(-Double(index) - 60))
        }
        let backfill = Task { await rig.watcher.importRecentCount() }
        #expect(await eventually { rig.ingest.candidates.count >= 4 }, "the backfill is under way")
        let live = try rig.shot(in: rig.desktop, "Screenshot live.png")
        rig.event(live)
        #expect(await backfill.value == 500)
        #expect(await eventually { rig.ingest.names.contains(live.lastPathComponent) })
        let position = try #require(rig.ingest.names.firstIndex(of: live.lastPathComponent))
        #expect(position < 500, "the live file was imported before the backfill drained, not after it")
    }

    @Test("OC-2020: Import recent screenshots is available in a capture mode that does not import")
    func backfillWhilePaused() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        try rig.shot(in: rig.desktop)
        #expect(await rig.watcher.importRecentCount() == 1)
    }

    @Test("OC-2057/2058: Import recent screenshots stops at the retention window and the 30 day cap")
    func backfillAgeBounds() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let day: TimeInterval = 86_400
        let recent = try rig.shot(in: rig.desktop, "Screenshot recent.png", born: Date().addingTimeInterval(-3 * day))
        try rig.shot(in: rig.desktop, "Screenshot ancient.png", born: Date().addingTimeInterval(-40 * day))
        #expect(await rig.watcher.importRecentCount() == 1)
        #expect(rig.ingest.names == [recent.lastPathComponent])
    }

    @Test("OC-2055: Import recent screenshots takes the 500 newest")
    func backfillCount() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let now = Date()
        for index in 0..<520 { try rig.shot(in: rig.desktop, "Screenshot \(index).png", born: now.addingTimeInterval(-Double(index))) }
        #expect(await rig.watcher.importRecentCount() == 500)
        let imported = Set(rig.ingest.names)
        #expect(imported.contains("Screenshot 0.png") && imported.contains("Screenshot 499.png"))
        #expect(!imported.contains("Screenshot 500.png") && !imported.contains("Screenshot 519.png"))
    }

    @Test("OC-2023/2024: nothing taken while capture is not active is imported afterwards")
    func pausedModeImportsNothing() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        await rig.watcher.settingsDidChange()

        let during = try rig.shot(in: rig.desktop)
        rig.event(during)
        await rig.watcher.didBecomeActive()
        await letItSettle()
        #expect(rig.ingest.candidates.isEmpty)

        rig.clock.advance(by: 60)
        rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
        await rig.watcher.settingsDidChange()
        await rig.relaunch()
        await rig.watcher.start()
        await rig.watcher.didBecomeActive()
        await letItSettle()
        #expect(rig.ingest.candidates.isEmpty, "the watermark moved through the pause, also across a relaunch")

        let after = try rig.shot(in: rig.desktop)
        rig.event(after)
        #expect(await eventually { rig.ingest.names == [after.lastPathComponent] })
    }

    @Test("FR-002-05: turning pickup off stops the watch and ends every condition it raised")
    func turnOffTearsDown() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        await rig.watcher.start()
        #expect(rig.notices.standing(.sspIo001))

        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.settingsDidChange()
        #expect(await rig.watcher.status == .off)
        #expect(rig.source.running.isEmpty)
        #expect(!rig.notices.standing(.sspIo001))
        #expect(rig.pollTick.registrationCount == 0, "no periodic work is left registered")
    }
}

@Suite("ScreenshotWatcher: access and the event mechanism", .serialized)
struct WatcherEnvironmentTests {
    @Test("OC-2012/2013/2076: a refused folder is noticed once, retried each tick, and picked up when allowed")
    func accessDeniedThenGranted() async throws {
        let rig = try WatcherRig(watermark: nil)
        defer { rig.cleanUp() }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        await rig.watcher.start()

        #expect(await rig.watcher.status == .needsAccess)
        #expect(rig.notices.raised(.sspPrm001) == 1)
        #expect(rig.marks.value != nil, "a refused first launch still records where it is")
        #expect(rig.source.running.isEmpty)
        await rig.tick()
        await rig.tick()
        #expect(rig.notices.raised(.sspPrm001) == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.desktop.path)
        await rig.tick()
        #expect(await rig.watcher.status == .watching)
        #expect(rig.notices.cleared(.sspPrm001) == 1)
        let shot = try rig.shot(in: rig.desktop)
        rig.event(shot)
        #expect(await eventually { rig.ingest.names == [shot.lastPathComponent] })
    }

    @Test("OC-2016/2017: no event stream means polling every 5 s, noticed once, and leaving the fallback clears it")
    func fallbackPolling() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        rig.source.setFailing(true)
        await rig.watcher.start()

        #expect(await eventually { rig.notices.raised(.sspOs001) == 1 })
        #expect(await rig.watcher.status == .watching)
        let shot = try rig.shot(in: rig.desktop)
        await rig.poll()
        #expect(await eventually { rig.ingest.names == [shot.lastPathComponent] })
        #expect(rig.notices.raised(.sspOs001) == 1)

        rig.source.setFailing(false)
        await rig.tick()
        #expect(await eventually { rig.notices.cleared(.sspOs001) == 1 })
        #expect(rig.source.running.count == 1)
    }

    @Test("FR-002-03/FR-002-01 (TASK-420): a standing SSP-PRM-001 is cleared when the folder resolves to paused")
    func deniedThenPaused() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        let chosen = try rig.temp.folder("Pictures/Chosen")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.desktop.path)
            rig.cleanUp()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        await rig.watcher.start()
        #expect(await rig.watcher.status == .needsAccess)
        #expect(rig.notices.standing(.sspPrm001))

        // The override now points at a folder that cannot be used: nothing is watched, so nothing is refused.
        let override = try FolderOverride.choosing(chosen).get()
        rig.settings.set(override, for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.hide(chosen)
        await rig.tick()
        #expect(await rig.watcher.status == .paused)
        #expect(rig.notices.standing(.sspIo003))
        #expect(!rig.notices.standing(.sspPrm001), "the refusal belonged to the previous folder")
        #expect(rig.notices.cleared(.sspPrm001) == 1)
    }

    @Test("FR-002-04/FR-002-01 (TASK-420): a standing SSP-OS-001 is cleared when the folder resolves to paused")
    func fallbackThenPaused() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let chosen = try rig.temp.folder("Pictures/Chosen")
        rig.source.setFailing(true)
        await rig.watcher.start()
        #expect(await eventually { rig.notices.standing(.sspOs001) })

        let override = try FolderOverride.choosing(chosen).get()
        rig.settings.set(override, for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.hide(chosen)
        await rig.tick()
        #expect(await rig.watcher.status == .paused)
        #expect(rig.notices.standing(.sspIo003))
        #expect(await eventually { !rig.notices.standing(.sspOs001) }, "polling stopped with the folder")
        #expect(rig.notices.cleared(.sspOs001) == 1)
    }

    @Test("FR-002-03 (TASK-420): leaving paused for a folder that is still refused raises SSP-PRM-001 again, once")
    func pausedThenStillDenied() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        let chosen = try rig.temp.folder("Pictures/Chosen")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.desktop.path)
            rig.cleanUp()
        }
        // given: Desktop refused, then an override that cannot be used pauses pickup
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        await rig.watcher.start()
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.hide(chosen)
        await rig.tick()
        #expect(await rig.watcher.status == .paused)
        await rig.tick()
        await rig.watcher.didBecomeActive()
        #expect(rig.notices.raised(.sspPrm001) == 1)
        #expect(rig.notices.cleared(.sspPrm001) == 1, "cleared once on entering paused, not on every tick while paused")
        #expect(rig.notices.raised(.sspIo003) == 1)
        #expect(rig.notices.cleared(.sspIo003) == 0, "SSP-IO-003 is the notice that stands while paused")

        // when: the override goes away and Desktop, still refused, is the folder again
        rig.settings.set(FolderOverride.none, for: SettingKeys.screenshotsFolderOverride)
        await rig.watcher.settingsDidChange()

        // then: the refusal is a new one, so it is raised a second time and stands; IO-003 clears
        #expect(await rig.watcher.status == .needsAccess)
        #expect(rig.notices.raised(.sspPrm001) == 2)
        #expect(rig.notices.standing(.sspPrm001))
        #expect(rig.notices.cleared(.sspIo003) == 1)
        #expect(!rig.notices.standing(.sspIo003))
        #expect(rig.source.running.isEmpty)
    }

    @Test("FR-002-04 (TASK-420): leaving paused for a folder whose stream still fails re-enters the fallback and raises SSP-OS-001 again")
    func pausedThenFallbackAgain() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let chosen = try rig.temp.folder("Pictures/Chosen")
        // given: polling fallback standing, then paused by an invalid override
        rig.source.setFailing(true)
        await rig.watcher.start()
        #expect(await eventually { rig.notices.raised(.sspOs001) == 1 })
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.hide(chosen)
        await rig.tick()
        #expect(await eventually { rig.notices.cleared(.sspOs001) == 1 })
        await rig.tick()
        #expect(rig.notices.cleared(.sspOs001) == 1, "no further clears while paused")

        // when: the override goes away; the stream still cannot be created
        rig.settings.set(FolderOverride.none, for: SettingKeys.screenshotsFolderOverride)
        await rig.watcher.settingsDidChange()

        // then: a new fallback is a new notice, and polling imports a screenshot
        #expect(await eventually { rig.notices.raised(.sspOs001) == 2 })
        #expect(rig.notices.standing(.sspOs001))
        #expect(await rig.watcher.status == .watching)
        let shot = try rig.shot(in: rig.desktop)
        await rig.poll()
        #expect(await eventually { rig.ingest.names == [shot.lastPathComponent] })
    }

    @Test("FR-002-03/04 (TASK-420): paused with no refusal and no fallback clears nothing but SSP-IO-001/003 bookkeeping")
    func pausedClearsNothingElse() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let chosen = try rig.temp.folder("Pictures/Chosen")
        // given: a healthy watch, then an invalid override
        await rig.watcher.start()
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.hide(chosen)
        await rig.tick()

        // then: only the paused notice was raised; nothing was cleared that was never raised
        #expect(await rig.watcher.status == .paused)
        #expect(rig.notices.entries == [.raised(.sspIo003)])
        // and a stream that works again after paused neither raises a fallback nor refusal
        rig.fileSystem.unhide(chosen)
        await rig.tick()
        #expect(await rig.watcher.status == .watching)
        #expect(rig.notices.entries == [.raised(.sspIo003), .cleared(.sspIo003)])
        #expect(rig.source.running.count == 1)
    }

    @Test("FR-002-03/04 (TASK-420): a refusal and a fallback cleared by disabling are not cleared a second time when re-enabled onto a paused folder")
    func disabledThenPaused() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        let chosen = try rig.temp.folder("Pictures/Chosen")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.desktop.path)
            rig.cleanUp()
        }
        // given: a standing PRM-001, switched off (cleared by FR-002-05)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        await rig.watcher.start()
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.settingsDidChange()
        #expect(rig.notices.cleared(.sspPrm001) == 1)

        // when: an invalid override is set while off, then pickup is switched on
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.hide(chosen)
        rig.settings.set(true, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.settingsDidChange()

        // then: paused with IO-003 only; the earlier refusal is neither re-raised nor cleared again
        #expect(await rig.watcher.status == .paused)
        #expect(rig.notices.standing(.sspIo003))
        #expect(rig.notices.raised(.sspPrm001) == 1)
        #expect(rig.notices.cleared(.sspPrm001) == 1)
        #expect(rig.notices.cleared(.sspOs001) == 0)
        #expect(rig.source.running.isEmpty)
    }

    @Test("FR-002-04: a stream that goes invalid falls back to polling")
    func invalidatedStream() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        rig.source.emit(.invalidated)
        #expect(await eventually { rig.notices.raised(.sspOs001) == 1 })
        #expect(await eventually { rig.clock.sleeping(seconds: 5) >= 1 })
    }
}
