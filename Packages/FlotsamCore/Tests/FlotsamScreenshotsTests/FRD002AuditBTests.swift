import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamScreenshots
@testable import FlotsamStorage

// FRD-002 audit B: the contract IDs the existing ScreenshotWatcherTests.swift does not fully prove
// (.claude/oracle/frd-002-contract.json). Same rig as ScreenshotWatcherTests (WatcherSupport.swift): a real temporary
// tree, fake clock / events / ingest / watermark / notices. Nothing here touches NSPasteboard, defaults, a real
// database or ~/Library.
//
// Not testable at package level (no seam; see the audit table): OC-2055 HUD text, OC-2066 signposts and p95,
// OC-2069 `log show` / Copy Diagnostics / Notices window, OC-2085 button visibility and label.

private let auditBDay: TimeInterval = 86_400

/// A launch some time ago: files born "now" are newer than the watermark.
private func auditBEarlierLaunch() -> Date { Date().addingTimeInterval(-10) }

private func auditBRealPath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

/// A file nobody can read, born inside the watermark window.
@discardableResult
private func auditBUnreadable(_ rig: WatcherRig, _ name: String) throws -> URL {
    let url = try rig.shot(in: rig.desktop, name)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    return url
}

/// Log records that report a reconcile scan's outcome. `screenshot.imported` is a per-file record, not a scan record.
private func auditBScanOutcomeCount(_ records: [LogRecord]) -> Int {
    records.filter {
        let text = ($0.headline + " " + $0.publicContext).lowercased()
        return text.contains("scan") || text.contains("reconcile")
    }.count
}

/// Everything a record or a raised error could carry as text.
private func auditBText(of record: LogRecord) -> String {
    [record.headline, record.publicContext, record.privateContext, record.message ?? "", String(describing: record.cause)]
        .joined(separator: " ")
}

private func auditBText(of error: FlotsamError) -> String {
    "\(error.code.rawValue) \(error.internalMessage) \(error.context) \(String(describing: error.underlying))"
}

@Suite("FRD-002 audit B", .serialized)
struct FRD002AuditBTests {
    // MARK: Launch and reconcile

    @Test("OC-2033: a gif and a mov with the screenshot attribute are not imported and leave no log entry")
    func gifAndMovLeaveNoTrace() async throws {
        // given: pickup running on the Desktop, nothing in the log yet
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let recordsBefore = rig.sink.records.count
        let gif = try rig.shot(in: rig.desktop, "Screenshot e-\(UUID().uuidString).gif")
        let mov = try rig.shot(in: rig.desktop, "Screenshot f-\(UUID().uuidString).mov")

        // when: both arrive
        rig.event(gif)
        rig.event(mov)
        await letItSettle()

        // then: nothing imported, nothing logged, nothing raised
        #expect(rig.ingest.candidates.isEmpty)
        #expect(rig.sink.records.count == recordsBefore)
        #expect(rig.notices.entries.isEmpty)

        // control: the watcher is alive, so the silence above is not a stopped watcher. The png adds exactly one record.
        let png = try rig.shot(in: rig.desktop, "Screenshot g-\(UUID().uuidString).png")
        rig.event(png)
        #expect(await eventually { rig.ingest.names == [png.lastPathComponent] })
        #expect(await eventually { rig.sink.records.count == recordsBefore + 1 })
    }

    @Test("OC-2037: three screenshots added while Flotsam was quit are all imported at launch, and nothing else")
    func launchImportsExactlyTheNewThree() async throws {
        // given: files on disk before the watcher starts (Flotsam was quit), one of them not a screenshot
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        let added = try (0..<3).map { _ in try rig.shot(in: rig.desktop) }
        try rig.shot(in: rig.desktop, "holiday.png", attribute: nil)

        // when: Flotsam launches
        await rig.watcher.start()

        // then: exactly the three, once each
        #expect(await eventually { rig.ingest.candidates.count == 3 })
        await letItSettle()
        #expect(rig.ingest.candidates.count == 3)
        #expect(Set(rig.ingest.names) == Set(added.map(\.lastPathComponent)))
        #expect(rig.ingest.names.count == Set(rig.ingest.names).count)
    }

    @Test("OC-2040: twenty already-imported screenshots are not imported again by a relaunch")
    func relaunchDoesNotReimportTwenty() async throws {
        // given: a watermark 100 s back and 20 screenshots born 50 s back, imported by the first launch. (Born inside the
        // 5 s watermark slack of the scan they would qualify again by design; FR-002-08.)
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        let born = Date().addingTimeInterval(-50)
        let twenty = try (0..<20).map { _ in try rig.shot(in: rig.desktop, born: born).lastPathComponent }
        await rig.watcher.start()
        #expect(await eventually(timeout: .seconds(10)) { rig.ingest.candidates.count == 20 })
        let watermark = try #require(rig.marks.value)

        // when: relaunched over the same folder and watermark, no new files
        rig.relaunch()
        await rig.watcher.start()
        await letItSettle()

        // then: count delta 0 and the same 20 names; the persisted watermark did not go backwards
        #expect(rig.ingest.candidates.count == 20)
        #expect(Set(rig.ingest.names) == Set(twenty))
        #expect(try #require(rig.marks.value) >= watermark)
    }

    @Test("OC-2041: waking from sleep and activating the app each log a completed reconcile-scan outcome")
    func scanOutcomeIsLogged() async throws {
        // given: pickup running, folder listable, nothing to import
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()

        // when/then: wake
        let beforeWake = rig.sink.records.count
        await rig.watcher.didWake()
        #expect(await eventually(timeout: .seconds(1)) {
            auditBScanOutcomeCount(Array(rig.sink.records.dropFirst(beforeWake))) >= 1
        })

        // when/then: activation
        let beforeActive = rig.sink.records.count
        await rig.watcher.didBecomeActive()
        #expect(await eventually(timeout: .seconds(1)) {
            auditBScanOutcomeCount(Array(rig.sink.records.dropFirst(beforeActive))) >= 1
        })
    }

    // MARK: Import recent screenshots

    @Test("OC-2055/2056: 700 screenshots, Import recent takes exactly the 500 newest by name; a second run adds none")
    func backfillSevenHundred() async throws {
        // given: 700 qualifying files with distinct creation dates inside 30 days (index 0 is the newest), none imported
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        let now = Date()
        for index in 0..<700 {
            try rig.shot(in: rig.desktop, "Screenshot n\(index).png", born: now.addingTimeInterval(-Double(index) * 60))
        }
        let newest = Set((0..<500).map { "Screenshot n\($0).png" })
        let oldest = Set((500..<700).map { "Screenshot n\($0).png" })

        // when: Import recent screenshots runs
        let created = await rig.watcher.importRecentCount()

        // then: +500, each of the 500 newest found by name, none of the 200 oldest
        #expect(created == 500)
        #expect(rig.ingest.names.count == 500)
        #expect(Set(rig.ingest.names) == newest)
        #expect(Set(rig.ingest.names).isDisjoint(with: oldest))

        // when: run again. then: no item is created and no new file name appears (delta 0)
        #expect(await rig.watcher.importRecentCount() == 0)
        #expect(Set(rig.ingest.names) == newest)
    }

    @Test("OC-2057: with 7 day retention a 3 day old file is imported and a 10 day old one is not")
    func backfillHonoursSevenDayRetention() async throws {
        // given: retention 7 days; files 3 and 10 days old (older than the watermark)
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(RetentionPreset.d7, for: SettingKeys.storageRetention)
        let threeDays = try rig.shot(in: rig.desktop, "Screenshot 3d.png", born: Date().addingTimeInterval(-3 * auditBDay))
        try rig.shot(in: rig.desktop, "Screenshot 10d.png", born: Date().addingTimeInterval(-10 * auditBDay))

        // when / then: count +1, the 3 day file
        #expect(await rig.watcher.importRecentCount() == 1)
        #expect(rig.ingest.names == [threeDays.lastPathComponent])
    }

    @Test("OC-2057: the 7 day window has an edge: 6.5 days in, 7.5 days out")
    func backfillSevenDayBoundary() async throws {
        // given: retention 7 days; files either side of the edge
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(RetentionPreset.d7, for: SettingKeys.storageRetention)
        let inside = try rig.shot(in: rig.desktop, "Screenshot in.png", born: Date().addingTimeInterval(-6.5 * auditBDay))
        try rig.shot(in: rig.desktop, "Screenshot out.png", born: Date().addingTimeInterval(-7.5 * auditBDay))

        // when / then
        #expect(await rig.watcher.importRecentCount() == 1)
        #expect(rig.ingest.names == [inside.lastPathComponent])
    }

    @Test("OC-2058: with retention longer than 30 days the 20 day file is imported and the 40 day file is not",
          arguments: [RetentionPreset.y1, RetentionPreset.forever])
    func backfillThirtyDayCap(retention: RetentionPreset) async throws {
        // given: retention beyond the cap; files 20 and 40 days old, plus both sides of the 30 day edge
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(retention, for: SettingKeys.storageRetention)
        let twenty = try rig.shot(in: rig.desktop, "Screenshot 20d.png", born: Date().addingTimeInterval(-20 * auditBDay))
        let edgeIn = try rig.shot(in: rig.desktop, "Screenshot 29d.png", born: Date().addingTimeInterval(-29 * auditBDay))
        try rig.shot(in: rig.desktop, "Screenshot 31d.png", born: Date().addingTimeInterval(-31 * auditBDay))
        try rig.shot(in: rig.desktop, "Screenshot 40d.png", born: Date().addingTimeInterval(-40 * auditBDay))

        // when / then: the 20 and 29 day files only
        #expect(await rig.watcher.importRecentCount() == 2)
        #expect(Set(rig.ingest.names) == [twenty.lastPathComponent, edgeIn.lastPathComponent])
    }

    // MARK: Stuck file, burst

    @Test("OC-2065: five valid screenshots arrive within 2 s of a stuck one and are all imported")
    func validFilesPassTheStuckOne() async throws {
        // given: pickup running
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()

        // when: an unreadable screenshot arrives, then five valid ones one after another
        let stuck = try auditBUnreadable(rig, "Screenshot stuck-\(UUID().uuidString).png")
        rig.event(stuck)
        var good: [URL] = []
        for _ in 0..<5 {
            let url = try rig.shot(in: rig.desktop)
            good.append(url)
            rig.event(url)
        }

        // then: all five, by name, within 2.0 s of the last arrival; the stuck one was attempted and not imported
        #expect(await eventually(timeout: .seconds(2)) { rig.ingest.names.count == 5 })
        #expect(Set(rig.ingest.names) == Set(good.map(\.lastPathComponent)))
        #expect(!rig.ingest.names.contains(stuck.lastPathComponent))
        #expect(await eventually { rig.notices.raised(.sspIo002) >= 1 })
    }

    @Test("OC-2066: twenty screenshots in a burst are all imported within 2 s, at most 2 at a time (fake ingest)")
    func burstLatencyBound() async throws {
        // given: pickup running
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()

        // when: 20 files arrive one event each
        var arrived: [URL] = []
        for _ in 0..<20 {
            let url = try rig.shot(in: rig.desktop)
            arrived.append(url)
            rig.event(url)
        }

        // then: every one is handed to ingest within 2.0 s of the last arrival (so no file waited longer), never more
        // than 2 in flight. This proves the watcher's share of the p95 bound only: the real ingest and Library search
        // are not in the package-level rig.
        #expect(await eventually(timeout: .seconds(2)) { rig.ingest.candidates.count == 20 })
        #expect(Set(rig.ingest.names) == Set(arrived.map(\.lastPathComponent)))
        #expect(rig.ingest.peakInFlight <= ScreenshotWatcher.maxInFlight)
    }

    // MARK: No file names in the log

    @Test("OC-2069: the folder and file names never reach the log records or the raised notices")
    func markerNeverLeaks() async throws {
        // given: the system location is a folder named 'fold-zq7marker' that does not exist yet
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        let marker = "zq7marker"
        let folder = rig.temp.root.appendingPathComponent("fold-\(marker)", isDirectory: true)
        rig.preferences.set(location: folder.path)
        await rig.watcher.start()

        // when: SSP-IO-001 is provoked by the missing folder (provoked, not assumed)
        #expect(rig.notices.raised(.sspIo001) == 1)
        //   the folder appears; a marker-named screenshot imports; a marker-named one is rejected as oversized (SSP-LIM-001)
        try rig.temp.folder("fold-\(marker)")
        await rig.tick()
        #expect(await rig.watcher.status == .watching)
        let ok = try rig.shot(in: folder, "Screenshot \(marker)-\(UUID().uuidString).png")
        let big = try rig.shot(in: folder, "Screenshot \(marker)-big-\(UUID().uuidString).png")
        rig.ingest.fail(big.lastPathComponent, with: FlotsamError(.sspLim001, "Image over the size limit"))
        rig.source.emit(.changed([ok, big]))
        #expect(await eventually { rig.notices.raised(.sspLim001) == 1 })
        #expect(await eventually { rig.ingest.names.contains(ok.lastPathComponent) && rig.sink.records.count >= 2 })

        // then: the records and the errors raised carry none of it (and there is something to search)
        let records = rig.sink.records
        #expect(records.count >= 2)
        for record in records { #expect(!auditBText(of: record).contains(marker)) }
        #expect(rig.notices.reported.count >= 2)
        for error in rig.notices.reported { #expect(!auditBText(of: error).contains(marker)) }
        #expect(!rig.ingest.candidates.isEmpty)
    }

    // MARK: Which folder is watched

    @Test("OC-2073: after the location changes, a screenshot added to the old folder is not imported by any path")
    func oldFolderIsNeverScannedAgain() async throws {
        // given: watching W (the system location), then the location changes to N
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        let old = try rig.temp.folder("Pictures/W")
        let new = try rig.temp.folder("Pictures/N")
        rig.use(old)
        await rig.watcher.start()
        rig.use(new)
        await rig.tick()
        rig.clock.advance(by: 5)
        #expect(rig.source.running.map { auditBRealPath($0.folder) } == [auditBRealPath(new)])

        // when: a qualifying file lands in W, and every path that could notice it runs (an event on the live watch,
        // a wake scan, an activation scan, another tick)
        let inOld = try rig.shot(in: old)
        rig.source.emit(.changed([inOld]))
        await rig.watcher.didWake()
        await rig.watcher.didBecomeActive()
        await rig.tick()
        await letItSettle()

        // then: not imported; control: a file in N is
        #expect(rig.ingest.candidates.isEmpty)
        let inNew = try rig.shot(in: new)
        rig.event(inNew)
        #expect(await eventually { rig.ingest.names == [inNew.lastPathComponent] })
    }

    @Test("OC-2080: an override folder that is really deleted, then recreated, resumes pickup: one screenshot, kind screenshot")
    func recreatedOverrideResumes() async throws {
        // given: override O (a security-scoped bookmark), watching O
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        let override = try rig.temp.folder("Pictures/Chosen")
        rig.settings.set(try FolderOverride.choosing(override).get(), for: SettingKeys.screenshotsFolderOverride)
        await rig.watcher.start()
        #expect(rig.source.running.map { auditBRealPath($0.folder) } == [auditBRealPath(override)])

        // when: O is deleted for real, a tick runs, O is recreated, 35 s pass, a screenshot is added to O.
        // Production: an unresolvable bookmark reads as none and the stored override is dropped (SettingsStore.read,
        // FRD-008 AC-008-02), so the watcher falls back to the system folder, never raises SSP-IO-003 and never returns
        // to O. The unmount case that ScreenshotWatcherTests simulates with `hide` (a bookmark that still resolves) is
        // the only route to SSP-IO-003.
        try FileManager.default.removeItem(at: override)
        await rig.tick()
        let pausedWhileMissing = await rig.watcher.status == .paused
        let noticeStanding = rig.notices.standing(.sspIo003)
        try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
        await rig.tick()
        rig.clock.advance(by: 5)
        let shot = try rig.shot(in: override)
        rig.event(shot)
        let imported = await eventually(timeout: .seconds(2)) { rig.ingest.candidates.count == 1 }
        await letItSettle()

        // then: SSP-IO-003 stands while O is missing; after the return exactly one item, of kind screenshot
        await withKnownIssue("FRD-002 OC-2080: a really deleted override is dropped as an unresolvable bookmark (FRD-008 AC-008-02), so no SSP-IO-003 and pickup never resumes on O") {
            #expect(pausedWhileMissing)
            #expect(noticeStanding)
            #expect(imported)
            #expect(rig.ingest.names == [shot.lastPathComponent])
            let candidate = try #require(rig.ingest.candidates.first)
            #expect(candidate.kind == .screenshot)
            #expect(candidate.origin == .screenshotFile)
        }
    }

    @Test("OC-2085: after clearing the override a screenshot in the system location is imported, one in the old override is not")
    func clearedOverrideImportsFromSystem() async throws {
        // given: system location S, override O
        let rig = try WatcherRig(watermark: auditBEarlierLaunch())
        defer { rig.cleanUp() }
        let system = try rig.temp.folder("Pictures/System")
        let chosen = try rig.temp.folder("Pictures/Chosen")
        rig.use(system)
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        await rig.watcher.start()
        #expect(rig.source.running.map { auditBRealPath($0.folder) } == [auditBRealPath(chosen)])

        // when: "Use system setting" clears the override
        rig.settings.set(FolderOverride.none, for: SettingKeys.screenshotsFolderOverride)
        await rig.watcher.settingsDidChange()

        // then: the override reads as cleared, S is watched, S's screenshot imports, O's does not
        #expect(rig.settings.value(SettingKeys.screenshotsFolderOverride) == FolderOverride.none)
        #expect(await rig.watcher.status == .watching)
        #expect(rig.source.running.map { auditBRealPath($0.folder) } == [auditBRealPath(system)])
        let inSystem = try rig.shot(in: system)
        let inChosen = try rig.shot(in: chosen)
        rig.source.emit(.changed([inSystem, inChosen]))
        #expect(await eventually { rig.ingest.names == [inSystem.lastPathComponent] })
        await letItSettle()
        #expect(rig.ingest.names == [inSystem.lastPathComponent])
    }
}
