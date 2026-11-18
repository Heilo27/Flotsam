import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-456 bug report (S2 real-app walk on ecd9f87): "Import Recent Screenshots" showed "Imported 0" when the run could
// not happen (database failed to open, folder paused or refused, every file failed to store). FRD-002 FR-002-12: a
// failed run shows the failure, never a count. Observed the way the app wires it: the HUD text each path hands `hud`.

@MainActor
private final class HUDLog {
    var messages: [String] = []
}

private func earlier() -> Date { Date().addingTimeInterval(-10) }

@Suite("TASK-456: Import Recent reports a failed run, never Imported 0", .serialized)
struct Task456ImportRecentFailureTests {
    private func announce(_ rig: WatcherRig) async -> [String] {
        let log = await HUDLog()
        await rig.watcher.importRecentAnnouncing { message in log.messages.append(message) }
        return await log.messages
    }

    @Test("a paused folder (override gone) shows the SSP-IO-003 message, not Imported 0")
    func pausedFolder() async throws {
        let rig = try WatcherRig(watermark: earlier())
        defer { rig.cleanUp() }
        let chosen = try rig.temp.folder("Pictures/Chosen")
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        _ = try rig.shot(in: chosen)
        rig.fileSystem.hide(chosen)
        #expect(await announce(rig) == [FlotsamStrings.message(for: FlotsamError(.sspIo003, "paused"))])
        #expect(rig.ingest.candidates.isEmpty)
    }

    @Test("a refused folder shows the SSP-PRM-001 message, not Imported 0")
    func refusedFolder() async throws {
        let rig = try WatcherRig(watermark: earlier())
        defer { rig.cleanUp() }
        _ = try rig.shot(in: rig.desktop)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        #expect(await announce(rig) == [FlotsamStrings.message(for: FlotsamError(.sspPrm001, "refused"))])
    }

    @Test("every file failing to store shows the storage failure, not Imported 0")
    func everyFileFailsToStore() async throws {
        let rig = try WatcherRig(watermark: earlier())
        defer { rig.cleanUp() }
        let failure = FlotsamError(.stoDb001, "the library could not be written")
        for name in ["Screenshot a.png", "Screenshot b.png", "Screenshot c.png"] {
            try rig.shot(in: rig.desktop, name)
            rig.ingest.fail(name, with: failure)
        }
        #expect(await announce(rig) == [FlotsamStrings.message(for: failure)])
    }

    @Test("a partial failure is still a run: the count of what was stored")
    func partialFailureStillCounts() async throws {
        let rig = try WatcherRig(watermark: earlier())
        defer { rig.cleanUp() }
        try rig.shot(in: rig.desktop, "Screenshot ok.png")
        try rig.shot(in: rig.desktop, "Screenshot bad.png")
        rig.ingest.fail("Screenshot bad.png", with: FlotsamError(.stoDb001, "the library could not be written"))
        #expect(await announce(rig) == ["Imported 1"])
    }

    @Test("importRecent returns the failure itself for a paused folder and a count for a good one")
    func importRecentResult() async throws {
        let rig = try WatcherRig(watermark: earlier())
        defer { rig.cleanUp() }
        _ = try rig.shot(in: rig.desktop)
        #expect(await rig.watcher.importRecent() == .success(1))
        let chosen = try rig.temp.folder("Pictures/Chosen")
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.hide(chosen)
        guard case .failure(let error) = await rig.watcher.importRecent() else {
            Issue.record("a paused folder must fail the run")
            return
        }
        #expect(error.code == .sspIo003)
    }
}

@MainActor
private final class CoordinatorLog {
    var hud: [String] = []
    var runs = 0
}

@MainActor
private func settles(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("TASK-456: the Import Recent entry before and after the library opens")
@MainActor
struct Task456ImportRecentCoordinatorTests {
    private let databaseError = FlotsamError(.stoDb001, "the library could not be opened")

    private func make(_ log: CoordinatorLog) -> ImportRecentCoordinator {
        ImportRecentCoordinator(hud: { log.hud.append($0) })
    }

    private func run(_ log: CoordinatorLog) -> ImportRecentCoordinator.Run {
        { @Sendable hud in
            await MainActor.run { log.runs += 1 }
            await hud(ScreenshotImportHUD.message(count: 3))
        }
    }

    // The S2 lie: a press after the database failed to open said "Imported 0".
    @Test("a press after the library failed to open shows the failure, not Imported 0, and runs nothing")
    func pressAfterOpenFailure() {
        let log = CoordinatorLog()
        let entry = make(log)
        entry.unavailable(databaseError)
        entry.request()
        #expect(log.hud == [FlotsamStrings.message(for: databaseError)])
        #expect(log.runs == 0)
    }

    // The second S2 lie: a press held while the library opened, then the open failed.
    @Test("a press held before the library opened, then the open failed, shows the failure, not Imported 0")
    func heldPressThenOpenFailure() {
        let log = CoordinatorLog()
        let entry = make(log)
        entry.request()
        #expect(log.hud.isEmpty, "nothing can be said before the outcome is known")
        entry.unavailable(databaseError)
        #expect(log.hud == [FlotsamStrings.message(for: databaseError)])
    }

    @Test("a press held before the library opened runs once when the watcher is ready")
    func heldPressRunsOnReady() async {
        let log = CoordinatorLog()
        let entry = make(log)
        entry.request()
        entry.request()
        entry.ready(run: run(log))
        // The run counts itself before it reports, so wait for the report, not for the count.
        #expect(await settles { log.hud.count == 2 })
        #expect(log.hud.first == ScreenshotImportHUD.importingMessage)
        #expect(log.hud.last == "Imported 3")
        #expect(log.runs == 1, "two presses before ready are one request")
    }

    @Test("a press after the watcher is ready shows Importing, then the run's own result")
    func pressWhenReady() async {
        let log = CoordinatorLog()
        let entry = make(log)
        entry.ready(run: run(log))
        entry.request()
        #expect(log.hud == [ScreenshotImportHUD.importingMessage])
        #expect(await settles { log.hud.count == 2 })
        #expect(log.hud == [ScreenshotImportHUD.importingMessage, "Imported 3"])
    }
}
