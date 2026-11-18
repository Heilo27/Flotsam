import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots
@testable import FlotsamStorage

// WORF-490 (FRD-002 FR-002-05, FR-002-12): blind adversarial tests for TASK-490's off-path fixes in
// `ScreenshotWatcher`: the reports in `finish` (`mayReport`), `reportWhileLive`, `importRecent`'s refusal
// (`raiseAccessDenied` / `markAccessGranted` while off), `deactivate`'s clear loop (`isRaised`) and `rebuild`'s
// `location = nil`.
//
// Every test parks the watcher at named suspensions, drives off / on / off across them, and judges what the user
// sees: notices raised and cleared, the watch, the status and the import log. Mutation map in the comment above
// each group; each mutation was applied by hand and the named test went red.

/// A watermark store whose loads and writes can be parked and failed. Distinct from the builder's private rig.
private final class Worf490Store: ScreenshotWatermarkStore, @unchecked Sendable {
    private let inner: MemoryWatermarkStore
    let loadGate = WorfGate()
    let writeGate = WorfGate()
    private let lock = NSLock()
    private var loadFails = false
    private var writeFails = false

    init(_ inner: MemoryWatermarkStore) { self.inner = inner }

    func failLoads() { lock.withLock { loadFails = true } }
    func failWrites() { lock.withLock { writeFails = true } }

    func lastScanAt() async -> FlotsamResult<Date?> {
        await loadGate.pass()
        if lock.withLock({ loadFails }) { return .failure(FlotsamError(.stoDb001, "load failed")) }
        return await inner.lastScanAt()
    }

    func setLastScanAt(_ date: Date) async -> FlotsamResult<Void> {
        await writeGate.pass()
        if lock.withLock({ writeFails }) { return .failure(FlotsamError(.stoDb001, "write failed")) }
        return await inner.setLastScanAt(date)
    }
}

/// The rig's ingest where every created item carries two warnings.
private struct Worf490TwoWarningsIngest: ScreenshotIngesting {
    let inner: IngestRecorder
    func ingest(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult> {
        switch await inner.ingest(candidate) {
        case .success(let result):
            .success(IngestResult(outcome: result.outcome, warnings: [
                FlotsamError(.sspLim001, "first warning"), FlotsamError(.stoDb001, "second warning")]))
        case .failure(let error): .failure(error)
        }
    }
}

@Suite("WORF-490: FR-002-05 off-path leftovers (adversarial)", .serialized)
struct Worf490AdversarialTests {
    // MARK: Rig helpers

    /// `clear` takes effect first and then waits at `holdClear`'s gate (the real reporter applies a clear at the start of
    /// the call); `report` records first and then waits at `holdReport`'s gate.
    private func makeWatcher(
        _ rig: WatcherRig, ingest: (any ScreenshotIngesting)? = nil, marks: (any ScreenshotWatermarkStore)? = nil,
        files: (any FileSystemPort)? = nil, holdClear: (code: ErrorCode, gate: WorfGate)? = nil, holdReport: WorfGate? = nil
    ) -> ScreenshotWatcher {
        let notices = rig.notices
        return ScreenshotWatcher(
            fileSystem: files ?? rig.fileSystem, preferences: rig.preferences, home: rig.home, clock: rig.clock,
            eventSource: rig.source, settings: rig.settings, ingest: ingest ?? rig.ingest,
            watermarkStore: marks ?? rig.marks,
            report: { error in
                notices.raise(error)
                if let holdReport { await holdReport.pass() }
            },
            clear: { code in
                notices.clear(code)
                if let holdClear, holdClear.code == code { await holdClear.gate.pass() }
            },
            pollTick: rig.pollTick, sink: rig.sink)
    }

    private func setPickup(_ on: Bool, _ rig: WatcherRig, _ watcher: ScreenshotWatcher) async {
        rig.settings.set(on, for: SettingKeys.screenshotsEnabled)
        await watcher.settingsDidChange()
    }

    private func run(_ work: @escaping @Sendable () async -> Void) -> Handoff<Bool> {
        let done = Handoff<Bool>()
        Task {
            await work()
            done.set(true)
        }
        return done
    }

    private func lastNotice(_ rig: WatcherRig, _ code: ErrorCode) -> NoticeLog.Entry? {
        rig.notices.entries.last { $0 == .raised(code) || $0 == .cleared(code) }
    }

    private func deny(_ rig: WatcherRig) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
    }

    private func allow(_ rig: WatcherRig) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.desktop.path)
    }

    private let rejection = FlotsamError(.sspVal001, "Not a regular file inside the screenshot folder")
    private let storeFailure = FlotsamError(.stoDb001, "the library could not be written")

    /// A live screenshot held in flight at the ingest, pickup on.
    private func liveImportInFlight(_ rig: WatcherRig, _ watcher: ScreenshotWatcher, name: String) async throws {
        await watcher.start()
        rig.ingest.holdIngests()
        let url = try rig.shot(in: rig.desktop, name)
        rig.event(url)
        try #require(await eventually { rig.ingest.heldIngests >= 1 }, "the live import is in flight at the ingest")
    }

    private func finishIngests(_ rig: WatcherRig, expecting count: Int) async throws {
        rig.ingest.releaseIngests()
        try #require(await eventually { rig.ingest.candidates.count >= count }, "the imports ended")
        await letItSettle()
    }

    // MARK: F1 — `mayReport` in `finish`
    // Mutations: (a) `.rejected` report unconditional; (b) `.failed` report unconditional; (c) warnings loop unconditional;
    // (d) `mayReport` returns true for every job (press jobs and live jobs alike); (e) `mayReport` returns `job.session == session`
    // only for press jobs, i.e. `batch == nil` (a press job's notice dropped).

    @Test("OC-W490-01 a live import of the first session rejected after off, on, off again reports nothing")
    func liveRejectedAcrossOffOnOff() async throws {
        // given: a live import in flight in session 1, which fails on a rejection
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig)
        rig.ingest.fail("Screenshot a.png", with: rejection)
        try await liveImportInFlight(rig, watcher, name: "Screenshot a.png")

        // when: off, on (a second session), off again, and only then does the import end
        await setPickup(false, rig, watcher)
        rig.clock.advance(by: 10)
        await setPickup(true, rig, watcher)
        await setPickup(false, rig, watcher)
        try await finishIngests(rig, expecting: 1)

        // then: nothing is raised for a file nobody watches, and pickup stays off
        #expect(rig.notices.raised(.sspVal001) == 0)
        #expect(await watcher.status == .off)
        #expect(rig.source.running.isEmpty, "no watch left running after the final off")
    }

    @Test("OC-W490-02 a live import that failed to store, ending after off, reports nothing")
    func liveFailedAfterOff() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig)
        rig.ingest.fail("Screenshot a.png", with: storeFailure)
        try await liveImportInFlight(rig, watcher, name: "Screenshot a.png")

        await setPickup(false, rig, watcher)
        try await finishIngests(rig, expecting: 1)

        #expect(rig.notices.raised(.stoDb001) == 0)
    }

    @Test("OC-W490-03 a live import with two warnings: the second, after off, is not raised (the check runs per warning)")
    func warningsStopMidLoop() async throws {
        // given: the first warning's report parks at the presenter; off arrives while it waits
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let reportGate = WorfGate()
        let watcher = makeWatcher(rig, ingest: Worf490TwoWarningsIngest(inner: rig.ingest), holdReport: reportGate)
        await watcher.start()
        reportGate.close()
        let url = try rig.shot(in: rig.desktop, "Screenshot a.png")
        rig.event(url)
        try #require(await eventually { reportGate.waiting >= 1 }, "the first warning is parked in its report")
        try #require(rig.notices.raised(.sspLim001) == 1, "control: the first warning was raised while pickup was on")

        // when: pickup goes off, then the first report returns
        await setPickup(false, rig, watcher)
        reportGate.open()
        await letItSettle()

        // then: the second warning is not raised after off
        #expect(rig.notices.raised(.stoDb001) == 0, "a warning raised after off outlives pickup")
        #expect(rig.notices.raised(.sspLim001) == 1)
    }

    @Test("OC-W490-04 control: a live rejection while pickup stays on raises exactly once")
    func liveRejectedWhileOn() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig)
        rig.ingest.fail("Screenshot a.png", with: rejection)
        try await liveImportInFlight(rig, watcher, name: "Screenshot a.png")

        try await finishIngests(rig, expecting: 1)

        #expect(rig.notices.raised(.sspVal001) == 1)
    }

    @Test("OC-W490-05 a press's rejected and failed imports still report after pickup goes off (FR-002-12)")
    func pressJobsReportAfterOff() async throws {
        // given: pickup on, two old files, a press whose two imports are in flight: one rejected, one failed to store
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig)
        let old = rig.clock.now().addingTimeInterval(-3600)
        try rig.shot(in: rig.desktop, "Screenshot p1.png", born: old)
        try rig.shot(in: rig.desktop, "Screenshot p2.png", born: old.addingTimeInterval(1))
        rig.ingest.fail("Screenshot p1.png", with: rejection)
        rig.ingest.fail("Screenshot p2.png", with: storeFailure)
        await watcher.start()
        rig.ingest.holdIngests()
        let result = Handoff<FlotsamResult<Int>>()
        let press = run { result.set(await watcher.importRecent()) }
        try #require(await eventually { rig.ingest.heldIngests >= 2 }, "both press imports are in flight")

        // when: pickup goes off while they run, then they end
        await setPickup(false, rig, watcher)
        try await finishIngests(rig, expecting: 2)
        try #require(await eventually { press.value == true }, "the press ended")

        // then: the user's own request reports each failure once
        #expect(rig.notices.raised(.sspVal001) == 1, "the press's rejection must still be raised after off")
        #expect(rig.notices.raised(.stoDb001) == 1, "the press's store failure must still be raised after off")
    }

    @Test("OC-W490-06 a press's import across off and on again still reports; a live import of the old session beside it does not")
    func pressReportsLiveSilentAcrossOffOn() async throws {
        // given: a live import (rejected) and a press import (store failure) both in flight
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig)
        rig.ingest.fail("Screenshot live.png", with: rejection)
        rig.ingest.fail("Screenshot press.png", with: storeFailure)
        try rig.shot(in: rig.desktop, "Screenshot press.png", born: rig.clock.now().addingTimeInterval(-3600))
        await watcher.start()
        rig.ingest.holdIngests()
        let live = try rig.shot(in: rig.desktop, "Screenshot live.png")
        rig.event(live)
        try #require(await eventually { rig.ingest.heldIngests >= 1 }, "the live import is in flight")
        let press = run { _ = await watcher.importRecent() }
        try #require(await eventually { rig.ingest.heldIngests >= 2 }, "the press import is in flight too")

        // when: off then on, then both end
        await setPickup(false, rig, watcher)
        rig.clock.advance(by: 10)
        await setPickup(true, rig, watcher)
        try await finishIngests(rig, expecting: 2)
        try #require(await eventually { press.value == true }, "the press ended")

        // then: the press reports, the old session's live import does not
        #expect(rig.notices.raised(.stoDb001) == 1)
        #expect(rig.notices.raised(.sspVal001) == 0)
    }

    // MARK: F2 — `reportWhileLive` (mutations: (a) body is just `await report(error)`; (b) compares nothing but `active`)

    @Test("OC-W490-07 two watermark loads parked across off and on: only the live session's failure is raised")
    func loadFailureAcrossOffOnRaisesOnce() async throws {
        // given: session 1's first watermark load parks; pickup is turned off and on again, and session 2's load parks too
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let store = Worf490Store(rig.marks)
        let watcher = makeWatcher(rig, marks: store)
        store.loadGate.close()
        let first = run { await watcher.start() }
        try #require(await eventually { store.loadGate.waiting >= 1 }, "session 1 parked in its watermark load")
        store.failLoads()
        await setPickup(false, rig, watcher)
        rig.clock.advance(by: 10)
        let second = run { await self.setPickup(true, rig, watcher) }
        try #require(await eventually { store.loadGate.waiting >= 2 }, "session 2 parked in its watermark load")

        // when: both loads fail
        store.loadGate.open()
        try #require(await eventually { first.value == true && second.value == true }, "both ended")
        await letItSettle()

        // then: one notice, from the session that is live
        #expect(rig.notices.raised(.stoDb001) == 1, "the first session's failure was raised on behalf of a pickup that ended")
    }

    @Test("OC-W490-08 two watermark writes parked across off and on: only the live session's failure is raised")
    func writeFailureAcrossOffOnRaisesOnce() async throws {
        // given: activation 1 parks in its watermark write; off; the clock moves; on again parks in its own write
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let store = Worf490Store(rig.marks)
        let watcher = makeWatcher(rig, marks: store)
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        store.writeGate.close()
        store.failWrites()
        let first = run { await self.setPickup(true, rig, watcher) }
        try #require(await eventually { store.writeGate.waiting >= 1 }, "activation 1 parked in its watermark write")
        await setPickup(false, rig, watcher)
        rig.clock.advance(by: 10)
        let second = run { await self.setPickup(true, rig, watcher) }
        try #require(await eventually { store.writeGate.waiting >= 2 }, "activation 2 parked in its watermark write")

        // when: both writes fail
        store.writeGate.open()
        try #require(await eventually { first.value == true && second.value == true }, "both ended")
        await letItSettle()

        // then: the live session's failure only
        #expect(rig.notices.raised(.stoDb001) == 1)
    }

    @Test("OC-W490-09 a watermark write failing in the same session still reports (the gate is not a blanket mute)")
    func writeFailureWhileOnReports() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let store = Worf490Store(rig.marks)
        store.failWrites()
        let watcher = makeWatcher(rig, marks: store)

        await watcher.start()
        rig.clock.advance(by: 10)
        await watcher.didBecomeActive()
        await letItSettle()

        #expect(rig.notices.raised(.stoDb001) >= 1, "a live session's watermark failure must be raised")
    }

    // MARK: Residual: the watermark write after off. FR-002-05 lists reports, watcher, timer and folder access; a
    // completed import's watermark must still be recorded.

    @Test("OC-W490-10 an import in flight at off: no duplicate on the next activation, and no notice standing")
    func importEndingAfterOffIsNotImportedAgain() async throws {
        // given: a live import in flight; pickup goes off and the import then ends
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig)
        try await liveImportInFlight(rig, watcher, name: "Screenshot a.png")
        await setPickup(false, rig, watcher)
        try await finishIngests(rig, expecting: 1)

        // when: pickup is turned on again and everything has had time to run
        rig.clock.advance(by: 10)
        await setPickup(true, rig, watcher)
        rig.clock.advance(by: ScreenshotWatcher.tickInterval); await watcher.tickFired()
        await letItSettle()

        // then: the file was imported once, not again, and nothing is raised
        #expect(rig.ingest.names == ["Screenshot a.png"], "the file must be imported exactly once")
        #expect(rig.notices.entries.filter { if case .raised = $0 { true } else { false } }.isEmpty)
    }

    // MARK: F3 — repeated denials (mutations: (a) `importRecent` reports directly instead of `raiseAccessDenied`;
    // (b) drop `if !active { await markAccessGranted() }`; (c) drop the `guard !accessDenied` in `raiseAccessDenied`)

    @Test("OC-W490-11 three refused presses while off raise once; the first press that can read the folder clears it, once")
    func repeatedDenialsRaiseOnceAndClearOnce() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        try deny(rig)

        for _ in 0..<3 { _ = await rig.watcher.importRecentWithin() }
        #expect(rig.notices.raised(.sspPrm001) == 1, "one condition, one notice")
        #expect(rig.notices.cleared(.sspPrm001) == 0)

        try allow(rig)
        let result = await rig.watcher.importRecentWithin()
        #expect((try? result?.get()) == 0)
        #expect(rig.notices.cleared(.sspPrm001) == 1)
        #expect(!rig.notices.standing(.sspPrm001))

        // and a denial after that is a new condition: raised again
        try deny(rig)
        _ = await rig.watcher.importRecentWithin()
        #expect(rig.notices.raised(.sspPrm001) == 2)
        #expect(rig.notices.standing(.sspPrm001))
    }

    @Test("OC-W490-12 a press's refusal while off is cleared when pickup turns on and can read the folder")
    func pressRefusalClearedByActivation() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        try deny(rig)
        _ = await rig.watcher.importRecentWithin()
        try #require(rig.notices.standing(.sspPrm001), "control: the press raised the refusal")

        try allow(rig)
        await setPickup(true, rig, rig.watcher)
        await letItSettle()

        #expect(!rig.notices.standing(.sspPrm001), "access returned, so the notice must go (nothing ever cleared it before)")
        #expect(await rig.watcher.status == .watching)
    }

    @Test("OC-W490-13 pickup on and refused, a refused press adds no second notice; off clears the one notice")
    func pressDenialWhileLiveDeniedIsOneNotice() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        try deny(rig)
        await rig.watcher.start()
        try #require(rig.notices.standing(.sspPrm001), "control: live pickup raised the refusal")
        _ = await rig.watcher.importRecentWithin()
        #expect(rig.notices.raised(.sspPrm001) == 1, "the press must not raise a second notice for the same refusal")

        await setPickup(false, rig, rig.watcher)

        #expect(!rig.notices.standing(.sspPrm001))
        #expect(rig.notices.cleared(.sspPrm001) == 1)
    }

    @Test("OC-W490-14 pickup on and refused, folder readable again: a press that succeeds leaves clearing to live pickup's next tick")
    func pressSuccessWhileOnThenTickClears() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        try deny(rig)
        await rig.watcher.start()
        try #require(rig.notices.standing(.sspPrm001), "control")
        try allow(rig)

        let result = await rig.watcher.importRecentWithin()
        #expect((try? result?.get()) == 0)
        // the press does not end live pickup's refusal: no watch exists yet, so the status must not claim one
        #expect(rig.notices.standing(.sspPrm001), "live pickup's refusal stands until its own next scan succeeds")
        #expect(await rig.watcher.status == .needsAccess)
        await rig.tick()
        await letItSettle()

        #expect(!rig.notices.standing(.sspPrm001), "the tick after access returned clears it")
        #expect(await rig.watcher.status == .watching)
        #expect(rig.source.running.count == 1, "live pickup is watching the folder again")
        let url = try rig.shot(in: rig.desktop, "Screenshot after.png")
        rig.event(url)
        #expect(await eventually { rig.ingest.names == ["Screenshot after.png"] }, "a screenshot taken afterward is imported (AC-002-03)")
    }

    // MARK: F4 — `deactivate`'s clear loop (mutation: drop `where !isRaised(code)`; or `isRaised` answering false for a code)

    @Test("OC-W490-15 off parked clearing the location notice, on again: the new activation's refusal notice survives the stale clear")
    func staleClearSkipsRefusalNotice() async throws {
        // given: Desktop used under SSP-IO-001 and refused (SSP-PRM-001); off parks on its first clear (SSP-IO-001), with
        // SSP-PRM-001 and SSP-OS-001 still to clear
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        try deny(rig)
        await watcher.start()
        try #require(rig.notices.standing(.sspIo001) && rig.notices.standing(.sspPrm001), "control: both conditions stand")
        gate.close()
        let off = run { await self.setPickup(false, rig, watcher) }
        try #require(await eventually { gate.waiting >= 1 }, "off parked on its first clear")

        // when: pickup is turned on again (the folder is still refused: it raises its own notice), then the off resumes
        rig.clock.advance(by: 10)
        await setPickup(true, rig, watcher)
        try #require(lastNotice(rig, .sspPrm001) == .raised(.sspPrm001), "control: the new activation raised the refusal")
        gate.open()
        try #require(await eventually { off.value == true }, "the off ended")

        // then: the refusal stands, as the watcher's state says it does
        #expect(lastNotice(rig, .sspPrm001) == .raised(.sspPrm001), "the stale off wiped the notice of a refusal that stands")
        #expect(await watcher.status == .needsAccess)
    }

    @Test("OC-W490-16 off, on, off again while the first off is parked: after everything, nothing is left standing")
    func offOnOffLeavesNothingStanding() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        rig.source.setFailing(true)
        try deny(rig)
        await watcher.start()
        try #require(rig.notices.standing(.sspIo001), "control")
        gate.close()
        let firstOff = run { await self.setPickup(false, rig, watcher) }
        try #require(await eventually { gate.waiting >= 1 }, "the first off parked")

        rig.clock.advance(by: 10)
        await setPickup(true, rig, watcher)
        gate.open()
        await setPickup(false, rig, watcher)
        try #require(await eventually { firstOff.value == true }, "the first off ended")

        for code in [ErrorCode.sspIo001, .sspPrm001, .sspOs001] {
            #expect(!rig.notices.standing(code), "\(code) left standing after the last off")
        }
        #expect(await watcher.status == .off)
        #expect(rig.source.running.isEmpty)
    }

    // MARK: F5 — `location = nil` in `rebuild` (mutation: drop it)

    @Test("OC-W490-17 a parked rebuild, then a settings change to a third folder: the latest settings win, one watch runs")
    func parkedRebuildOvertakenByThirdFolder() async throws {
        // given: rebuild A (to folder X) parks clearing SSP-IO-001
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        await watcher.start()
        try #require(rig.notices.standing(.sspIo001), "control")
        let x = try rig.temp.folder("Pictures/X")
        let y = try rig.temp.folder("Pictures/Y")
        rig.settings.set(try FolderOverride.choosing(x).get(), for: SettingKeys.screenshotsFolderOverride)
        gate.close()
        let rebuildA = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "rebuild A parked")

        // when: the user picks Y while A waits, then A resumes
        rig.settings.set(try FolderOverride.choosing(y).get(), for: SettingKeys.screenshotsFolderOverride)
        await watcher.settingsDidChange()
        gate.open()
        try #require(await eventually { rebuildA.value == true }, "rebuild A ended")

        // then: a screenshot appearing in Y is picked up; one in X is not; exactly one watch runs
        #expect(rig.source.running.count == 1)
        let inY = try rig.shot(in: y, "Screenshot y.png")
        rig.event(inY)
        #expect(await eventually { rig.ingest.names.contains("Screenshot y.png") }, "the watcher follows the latest folder")
        #expect(await watcher.status == .watching)
    }

    @Test("OC-W490-18 a parked rebuild, then the same folder asked again: no second watch is leaked")
    func parkedRebuildThenSameFolderAgain() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        await watcher.start()
        let x = try rig.temp.folder("Pictures/X")
        rig.settings.set(try FolderOverride.choosing(x).get(), for: SettingKeys.screenshotsFolderOverride)
        gate.close()
        let rebuildA = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "rebuild A parked")

        await watcher.settingsDidChange()
        gate.open()
        try #require(await eventually { rebuildA.value == true }, "rebuild A ended")

        #expect(rig.source.running.count == 1, "exactly one watch after two rebuilds of the same folder")
        #expect(rig.source.running.count == rig.source.watches.filter { !$0.stopped }.count)
        #expect(await watcher.status == .watching)
    }

    @Test("OC-W490-19 a parked rebuild, then pickup off: nothing is installed, no watch runs, SSP-IO-001 is not left standing")
    func parkedRebuildThenOff() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        await watcher.start()
        let x = try rig.temp.folder("Pictures/X")
        rig.settings.set(try FolderOverride.choosing(x).get(), for: SettingKeys.screenshotsFolderOverride)
        gate.close()
        let rebuildA = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "rebuild A parked")

        await setPickup(false, rig, watcher)
        gate.open()
        try #require(await eventually { rebuildA.value == true }, "rebuild A ended")

        #expect(await watcher.status == .off)
        #expect(rig.source.running.isEmpty)
        #expect(!rig.notices.standing(.sspIo001))
    }

    @Test("OC-W490-20 a parked rebuild, then a capture-mode change: the watch is installed once and imports resume")
    func parkedRebuildThenCaptureModeChange() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        await watcher.start()
        let x = try rig.temp.folder("Pictures/X")
        rig.settings.set(try FolderOverride.choosing(x).get(), for: SettingKeys.screenshotsFolderOverride)
        gate.close()
        let rebuildA = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "rebuild A parked")

        rig.settings.set(CaptureMode.curated, for: SettingKeys.captureMode)
        await watcher.settingsDidChange()
        rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
        rig.clock.advance(by: 10)
        await watcher.settingsDidChange()
        gate.open()
        try #require(await eventually { rebuildA.value == true }, "rebuild A ended")
        await letItSettle()

        #expect(rig.source.running.count == 1)
        let inX = try rig.shot(in: x, "Screenshot x.png")
        rig.event(inX)
        #expect(await eventually { rig.ingest.names.contains("Screenshot x.png") }, "live pickup resumed in the chosen folder")
    }

    // MARK: F1 unstable outcome and F4 fallback notice (added after the first mutation run)
    // Mutations: M02 `.unstable` report unconditional -> OC-W490-21; `isRaised(.sspOs001)` false -> OC-W490-23.

    /// Pickup on, a live import held at its read; the file then vanishes, so the import ends `unstable` (SSP-IO-002).
    private func unstableLiveImport(_ rig: WatcherRig, _ files: WorfHeldReadFileSystem, _ watcher: ScreenshotWatcher) async throws -> URL {
        await watcher.start()
        let url = try rig.shot(in: rig.desktop, "Screenshot gone.png")
        files.holdReads()
        rig.event(url)
        try #require(await eventually { files.blockedReads >= 1 }, "the import is in flight at its read")
        try FileManager.default.removeItem(at: url)
        return url
    }

    @Test("OC-W490-21 a live import that ends unstable after off reports no SSP-IO-002")
    func unstableLiveImportAfterOff() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let files = WorfHeldReadFileSystem(rig.fileSystem)
        let watcher = makeWatcher(rig, files: files)
        _ = try await unstableLiveImport(rig, files, watcher)

        await setPickup(false, rig, watcher)
        files.releaseReads()
        try #require(await eventually { files.blockedReads == 0 }, "the import ended")
        await letItSettle()

        #expect(rig.notices.raised(.sspIo002) == 0, "SSP-IO-002 for a file of a pickup that ended")
        #expect(rig.ingest.names.isEmpty)
    }

    @Test("OC-W490-22 control: the same unstable import with pickup still on raises SSP-IO-002 once")
    func unstableLiveImportWhileOn() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let files = WorfHeldReadFileSystem(rig.fileSystem)
        let watcher = makeWatcher(rig, files: files)
        _ = try await unstableLiveImport(rig, files, watcher)

        files.releaseReads()
        try #require(await eventually { rig.notices.raised(.sspIo002) >= 1 }, "the unstable import was reported")
        await letItSettle()

        #expect(rig.notices.raised(.sspIo002) == 1)
    }

    @Test("OC-W490-23 off parked clearing SSP-IO-001, on again in the fallback: the new SSP-OS-001 survives the stale clear")
    func staleClearSkipsFallbackNotice() async throws {
        // given: Desktop under SSP-IO-001 and the stream unavailable (SSP-OS-001); off parks on its first clear
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        rig.source.setFailing(true)
        await watcher.start()
        try #require(rig.notices.standing(.sspIo001) && rig.notices.standing(.sspOs001), "control: both conditions stand")
        gate.close()
        let off = run { await self.setPickup(false, rig, watcher) }
        try #require(await eventually { gate.waiting >= 1 }, "off parked on its first clear")

        // when: pickup comes back on while the stream is still unavailable, then the off resumes
        rig.clock.advance(by: 10)
        await setPickup(true, rig, watcher)
        try #require(lastNotice(rig, .sspOs001) == .raised(.sspOs001), "control: the new activation raised the fallback notice")
        gate.open()
        try #require(await eventually { off.value == true }, "the off ended")

        // then: the fallback notice stands
        #expect(lastNotice(rig, .sspOs001) == .raised(.sspOs001), "the stale off wiped the notice of a fallback that is in use")
    }

    @Test("OC-W490-24 a parked rebuild, then the override removed: Desktop is what is watched, and a Desktop screenshot imports")
    func parkedRebuildThenOverrideRemoved() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        await watcher.start()
        let x = try rig.temp.folder("Pictures/X")
        rig.settings.set(try FolderOverride.choosing(x).get(), for: SettingKeys.screenshotsFolderOverride)
        gate.close()
        let rebuildA = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "rebuild A parked")

        rig.settings.set(FolderOverride.none, for: SettingKeys.screenshotsFolderOverride)
        await watcher.settingsDidChange()
        gate.open()
        try #require(await eventually { rebuildA.value == true }, "rebuild A ended")
        await letItSettle()

        #expect(await watcher.status == .usingDesktop)
        #expect(rig.source.running.count == 1)
        let inX = try rig.shot(in: x, "Screenshot inx.png")
        rig.event(inX)
        let onDesktop = try rig.shot(in: rig.desktop, "Screenshot desk.png")
        rig.event(onDesktop)
        #expect(await eventually { rig.ingest.names.contains("Screenshot desk.png") }, "Desktop is watched")
        #expect(!rig.ingest.names.contains("Screenshot inx.png"), "the stale rebuild's folder is not")
    }
}
