import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-446 blind QA, FRD-002 FR-002-12 / FRD-008 FR-008-04 (OC-2020, OC-2055, OC-2062). The HUD is observed the way the
// app wires it: `importRecentAnnouncing` over the real watcher, real file tree, recording ingest. Each record pairs the
// message with how many files had been ingested when it was shown.

@MainActor
private final class HUDRecord {
    var shown: [(message: String, ingestedAtShow: Int)] = []
    var messages: [String] { shown.map(\.message) }
}

private func earlierLaunch() -> Date { Date().addingTimeInterval(-10) }

@Suite("TASK-446 Worf: Imported {n} HUD", .serialized)
struct Worf446ImportHUDTests {
    private func run(_ rig: WatcherRig, into record: HUDRecord) async {
        let ingest = rig.ingest
        await rig.watcher.importRecentAnnouncing { message in
            record.shown.append((message, ingest.candidates.count))
        }
    }

    // Red if the HUD shows the files found instead of the items created, or a hardcoded number.
    @Test("OC-2020: the HUD counts items created: 3, then 2 new beside 3 already in, then 0")
    func countsCreatedNotFound() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        _ = try (0..<3).map { _ in try rig.shot(in: rig.desktop) }
        let record = await HUDRecord()
        await run(rig, into: record)
        _ = try (0..<2).map { _ in try rig.shot(in: rig.desktop) }
        await run(rig, into: record)
        await run(rig, into: record)
        #expect(await record.messages == ["Imported 3", "Imported 2", "Imported 0"])
        #expect(Set(rig.ingest.names).count == 5, "five distinct screenshots reached ingest across the three runs")
    }

    // Red if the HUD is skipped on 0 (empty folder), or shown twice, or the empty result is a different text.
    @Test("FR-002-12: an empty folder still shows exactly one HUD, Imported 0")
    func emptyFolderShowsZero() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let record = await HUDRecord()
        await run(rig, into: record)
        #expect(await record.messages == ["Imported 0"])
        #expect(rig.ingest.candidates.isEmpty)
    }

    // Red if the HUD is shown before the import has finished, so the number cannot be real.
    @Test("OC-2020: the HUD appears only after every file is ingested")
    func hudAfterImport() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        _ = try (0..<4).map { _ in try rig.shot(in: rig.desktop) }
        let record = await HUDRecord()
        await run(rig, into: record)
        let shown = await record.shown
        #expect(shown.count == 1)
        #expect(shown.first?.message == "Imported 4")
        #expect(shown.first?.ingestedAtShow == 4)
    }

    // Red if the count is clamped wrong or the cap is not reflected (700 in the oracle; 520 here to stay fast).
    @Test("OC-2055: more than 500 qualifying files shows Imported 500")
    func cappedAt500() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let now = Date()
        for index in 0..<520 { try rig.shot(in: rig.desktop, "Screenshot \(index).png", born: now.addingTimeInterval(-Double(index))) }
        let record = await HUDRecord()
        await run(rig, into: record)
        #expect(await record.messages == ["Imported 500"])
        #expect(rig.ingest.candidates.count == 500)
    }

    // Boundary 1 and the retention cut: only the file inside the window is counted.
    @Test("FR-002-12: one file in the window and one outside shows Imported 1")
    func oneInsideOneOutside() async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        let day: TimeInterval = 86_400
        let kept = try rig.shot(in: rig.desktop, "Screenshot recent.png", born: Date().addingTimeInterval(-2 * day))
        try rig.shot(in: rig.desktop, "Screenshot ancient.png", born: Date().addingTimeInterval(-45 * day))
        let record = await HUDRecord()
        await run(rig, into: record)
        #expect(await record.messages == ["Imported 1"])
        #expect(rig.ingest.names == [kept.lastPathComponent])
    }

    // The button is never disabled by capture mode (FR-002-12): Paused with pickup off still imports and still announces.
    @Test("FR-002-12: Paused capture mode and pickup off still import and announce", arguments: [CaptureMode.paused, CaptureMode.active])
    func notGatedByMode(mode: CaptureMode) async throws {
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        rig.settings.set(mode, for: SettingKeys.captureMode)
        _ = try (0..<2).map { _ in try rig.shot(in: rig.desktop) }
        let record = await HUDRecord()
        await run(rig, into: record)
        #expect(await record.messages == ["Imported 2"])
    }
}
