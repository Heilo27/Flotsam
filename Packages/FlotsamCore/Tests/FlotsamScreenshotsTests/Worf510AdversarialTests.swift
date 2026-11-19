import Foundation
import Testing
@testable import FlotsamBase
@testable import FlotsamScreenshots

// WORF-510 (blind QA of TASK-510 / TASK-509): adversarial cover for `ScreenshotWatcher.stop()` and the scoped-signpost seam
// that Task510WatcherStopTests does not pin. Every wait is a deadline-bound condition that fails with a message.

@Suite("WORF-510: ScreenshotWatcher.stop edges", .serialized, .timeLimit(.minutes(1)))
struct Worf510StopEdgeTests {
    /// OC-WORF510-01. given a reconcile scan suspended inside its folder listing, when `stop()` is called and the listing
    /// then returns a selectable file, then nothing is ingested and nothing is running. Red if a scan that was already
    /// on its way when `stop()` ran still enqueues its files afterwards (the doc says it is discarded).
    @Test("OC-WORF510-01 a scan in flight when stop() runs is discarded")
    func scanInFlightAcrossStop() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        try rig.shot(in: rig.desktop, "Screenshot mid-scan.png")
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let scan = Task { await watcher.didBecomeActive() }
        #expect(await eventually(timeout: .seconds(20)) { rig.fileSystem.listingIsHeld }, "the scan never reached its listing")
        await watcher.stop()
        rig.fileSystem.releaseListing()
        await scan.value
        #expect(await watcher.untilIdle(), "an import was started by the discarded scan")
        await letItSettle()
        #expect(rig.ingest.names.isEmpty, "a scan in flight across stop() ingested: \(rig.ingest.names)")
        #expect(await watcher.importsRunning == 0)
    }

    /// OC-WORF510-02. given a press suspended inside its listing, when `stop()` runs and the listing then returns, then
    /// the press resolves (it must not hang its caller) and, once stop() has returned, no import is left running.
    /// Red if stop() returns while the press's files are still being imported, or if the press never resolves.
    @Test("OC-WORF510-02 a press in flight across stop() resolves and leaves nothing running when stop() returned")
    func pressInFlightAcrossStop() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        try rig.shot(in: rig.desktop, "Screenshot press-a.png")
        try rig.shot(in: rig.desktop, "Screenshot press-b.png")
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let resolved = Handoff<FlotsamResult<Int>>()
        Task { resolved.set(await watcher.importRecent()) }
        #expect(await eventually(timeout: .seconds(20)) { rig.fileSystem.listingIsHeld }, "the press never reached its listing")
        await watcher.stop()
        let runningAtReturn = await watcher.importsRunning
        rig.fileSystem.releaseListing()
        #expect(await eventually(timeout: .seconds(20)) { resolved.value != nil }, "the press never resolved after stop()")
        #expect(await watcher.untilIdle(), "imports never ended")
        #expect(runningAtReturn == 0, "stop() returned with \(runningAtReturn) imports running")
        // DEFECT (WORF-510 D1, Minor): a press already scanning when stop() ran goes on to ingest after stop() returned;
        // `stop()` only gates new presses. Pinned until fixed; flip to a plain #expect when it is.
        withKnownIssue("a press mid-scan across stop() still ingests after stop() returned (TASK-510 QA D1)") {
            #expect(rig.ingest.names.isEmpty, "a press in flight across stop() ingested after stop returned: \(rig.ingest.names)")
        }
    }

    /// OC-WORF510-03. given a watcher never started, when stop() is called twice and then a start, then both return and
    /// the watcher stays off. Boundary: 0 imports. Red if stop() needs an active watcher, or start() revives it.
    @Test("OC-WORF510-03 stop on a never-started watcher, twice, then start: off")
    func stopNeverStartedAndTwice() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = rig.watcher!
        #expect(await finishes { await watcher.stop(); await watcher.stop() }, "stop() hung on a watcher that was never started")
        await watcher.start()
        #expect(rig.source.watches.isEmpty, "start() after stop() created a watch")
        #expect(await watcher.status == .off)
    }

    /// OC-WORF510-04. given two stop() calls racing while one import is held, then both return once it ends (the waiter
    /// list resumes every caller, not just the first). Red if only one waiter is resumed.
    @Test("OC-WORF510-04 two concurrent stop() calls both return after the held import ends")
    func concurrentStops() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let held = try rig.shot(in: rig.desktop, "Screenshot held2.png")
        rig.ingest.holdIngest(named: held.lastPathComponent)
        rig.event(held)
        #expect(await eventually(timeout: .seconds(20)) { rig.ingest.heldIngests == 1 })
        let watcher = rig.watcher!
        let first = Handoff<Bool>()
        let second = Handoff<Bool>()
        Task { await watcher.stop(); first.set(true) }
        Task { await watcher.stop(); second.set(true) }
        await letItSettle()
        #expect(first.value == nil && second.value == nil, "a stop() returned while an import was held")
        rig.ingest.releaseIngest(named: held.lastPathComponent)
        #expect(await eventually(timeout: .seconds(20)) { first.value == true && second.value == true },
                "first \(String(describing: first.value)) second \(String(describing: second.value))")
    }

    /// OC-WORF510-05. given 5 files picked up by one reconcile with every ingest held (2 run, 3 queue), when stop() is
    /// called, then it waits for all 5 (count delta 5, each name once) and importsRunning is 0 when it returns.
    /// Boundary max (2) + 3. Red if stop() drains only the jobs already running, or returns before the queue is empty.
    @Test("OC-WORF510-05 stop drains the queued imports as well as the running ones")
    func stopDrainsQueue() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        rig.ingest.holdIngests()
        await rig.watcher.start()
        var names: [String] = []
        for i in 0..<5 { names.append(try rig.shot(in: rig.desktop, "Screenshot q\(i).png").lastPathComponent) }
        await rig.watcher.didBecomeActive()
        #expect(await eventually(timeout: .seconds(20)) { rig.ingest.heldIngests == ScreenshotWatcher.maxInFlight }, "jobs never reached the ingest")
        let watcher = rig.watcher!
        let returned = Handoff<Int>()
        Task { await watcher.stop(); returned.set(await watcher.importsRunning) }
        await letItSettle()
        #expect(returned.value == nil, "stop() returned with imports queued")
        rig.ingest.releaseIngests()
        #expect(await eventually(timeout: .seconds(20)) { returned.value != nil }, "stop() never returned")
        #expect(returned.value == 0)
        #expect(rig.ingest.names.sorted() == names.sorted(), "ingested \(rig.ingest.names)")
    }

    /// OC-WORF510-11. given an import held in the ingest and stop() waiting on it, when a new file's event arrives on the
    /// old watch, and a tick, a wake, an activation and a settings change fire, then none of them starts new work: only
    /// the held file is ever ingested. Red if stop() leaves the watch or the entry points live while it drains ("new
    /// work stops at once").
    @Test("OC-WORF510-11 while stop() drains, no new event, tick, wake, activation or settings change adds work")
    func nothingNewWhileDraining() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let held = try rig.shot(in: rig.desktop, "Screenshot draining.png")
        rig.ingest.holdIngest(named: held.lastPathComponent)
        rig.event(held)
        #expect(await eventually(timeout: .seconds(20)) { rig.ingest.heldIngests == 1 })
        let oldWatch = try #require(rig.source.watches.last)
        let watcher = rig.watcher!
        let returned = Handoff<Bool>()
        Task { await watcher.stop(); returned.set(true) }
        await letItSettle()
        let late = try rig.shot(in: rig.desktop, "Screenshot late-drain.png")
        rig.source.emit(.changed([late]), on: oldWatch)
        rig.source.emit(.rescan, on: oldWatch)
        // A folder change the settings and the tick would act on: re-resolving it would start a watch on the new folder.
        let other = rig.temp.root.appendingPathComponent("OtherShots", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        rig.use(other)
        await watcher.settingsDidChange()
        await rig.tick()
        await watcher.didWake()
        await watcher.didBecomeActive()
        await letItSettle()
        #expect(rig.source.running.isEmpty, "a watch was running or started while stop() drained: \(rig.source.running.map(\.folder.lastPathComponent))")
        rig.ingest.releaseIngest(named: held.lastPathComponent)
        #expect(await eventually(timeout: .seconds(20)) { returned.value == true }, "stop() never returned")
        await letItSettle()
        #expect(rig.ingest.names == [held.lastPathComponent], "work was added while stop() drained: \(rig.ingest.names)")
    }

    /// OC-WORF510-12. given a press that never resolves (its listing is held), then `importRecentWithin` gives up at its
    /// timeout and returns nil. Boundary: zero results. Red (a clean time-limit failure, not a hang of the whole run) if
    /// the helper stops honouring its timeout, which every TASK-479 style bounded press relies on.
    @Test("OC-WORF510-12 importRecentWithin returns nil at its timeout when the press is stuck")
    func importRecentWithinHonoursTimeout() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        try rig.shot(in: rig.desktop, "Screenshot stuck.png")
        rig.fileSystem.holdNextListing()
        defer { rig.fileSystem.releaseListing() }
        // The helper is called inside its own outer deadline, so a helper that ignores its timeout fails here with a
        // message instead of hanging the run (a cooperative time limit cannot interrupt a continuation that never resumes).
        let result = Handoff<FlotsamResult<Int>?>()
        let watcher = rig.watcher!
        let returned = await finishes(within: .seconds(5)) { result.set(await watcher.importRecentWithin(.milliseconds(300))) }
        rig.fileSystem.releaseListing()
        #expect(returned, "importRecentWithin did not return within 5 s of a 300 ms timeout")
        if let outcome = result.value { #expect(outcome == nil, "a stuck press returned \(String(describing: outcome))") }
    }

    /// OC-WORF510-06. given a stopped watcher, when a new watcher over the same folder starts (the relaunch), then the
    /// new one imports a file once while the old one adds nothing: count delta exactly 1, identity of the file.
    @Test("OC-WORF510-06 after relaunch only the new watcher imports, exactly once")
    func relaunchOnlyNewImports() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let oldWatch = try #require(rig.source.watches.last)
        await rig.relaunch()
        await rig.watcher.start()
        let file = try rig.shot(in: rig.desktop, "Screenshot after-relaunch.png")
        rig.source.emit(.changed([file]), on: oldWatch)
        rig.event(file)
        #expect(await eventually(timeout: .seconds(20)) { rig.ingest.names == [file.lastPathComponent] }, "names \(rig.ingest.names)")
        await rig.watcher.stop()
        await letItSettle()
        #expect(rig.ingest.names == [file.lastPathComponent], "ingested \(rig.ingest.names)")
    }
}

@Suite("WORF-510: scoped signposts", .serialized, .timeLimit(.minutes(1)))
struct Worf510ScopedSignpostTests {
    final class Tap: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [ScopedSignpostEdge] = []
        let scope: UInt32
        init(scope: UInt32) {
            self.scope = scope
            Signposts.observe(scope: scope) { [weak self] edge in self?.lock.withLock { self?.kept.append(edge) } }
        }
        deinit { Signposts.stopObserving(scope: scope) }
        var edges: [ScopedSignpostEdge] { lock.withLock { kept } }
        func stop() { Signposts.stopObserving(scope: scope) }
    }

    /// OC-WORF510-07. given an observer on scope A and another on scope B, when only scope A opens and closes an interval,
    /// then A sees exactly begin+end with one serial and B sees nothing. Red if observers are not keyed by scope.
    @Test("OC-WORF510-07 an observer sees only its own scope")
    func scopeIsolation() {
        let a = SignpostScopes.next()
        let b = SignpostScopes.next()
        let tapA = Tap(scope: a)
        let tapB = Tap(scope: b)
        defer { tapA.stop(); tapB.stop() }
        Signposts.begin(.librarySearch, scope: a).end()
        let edges = tapA.edges
        #expect(edges.map(\.kind) == [.begin, .end], "\(edges)")
        #expect(Set(edges.map(\.serial)).count == 1 && edges.allSatisfy { $0.scope == a && $0.interval == .librarySearch })
        #expect(tapB.edges.isEmpty, "scope B saw scope A's interval")
    }

    /// OC-WORF510-08. given an observer registered under scope 0, when production-style unscoped intervals are opened,
    /// then it is never called (scope 0 pays nothing and reports nothing). Red if `notify` loses its `scope != 0` guard.
    @Test("OC-WORF510-08 unscoped (production) intervals are never reported")
    func unscopedIsNotReported() {
        let tap = Tap(scope: 0)
        defer { tap.stop() }
        Signposts.begin(.librarySearch).end()
        _ = Signposts.measure(.librarySearch) { 1 }
        #expect(tap.edges.isEmpty, "an unscoped interval was reported: \(tap.edges)")
    }

    /// OC-WORF510-09. given 200 intervals opened and held open under one scope, then every serial is distinct and each
    /// end pairs with exactly one begin (count delta 200 begins, 200 ends). Boundary: many. Red if the counter repeats.
    @Test("OC-WORF510-09 serials are distinct across many open intervals")
    func serialsDistinct() {
        let scope = SignpostScopes.next()
        let tap = Tap(scope: scope)
        defer { tap.stop() }
        let spans = (0..<200).map { _ in Signposts.begin(.librarySearch, scope: scope) }
        for span in spans { span.end() }
        let begins = tap.edges.filter { $0.kind == .begin }.map(\.serial)
        let ends = tap.edges.filter { $0.kind == .end }.map(\.serial)
        #expect(begins.count == 200 && Set(begins).count == 200, "begins \(begins.count) distinct \(Set(begins).count)")
        #expect(ends.count == 200 && Set(ends) == Set(begins))
    }

    /// OC-WORF510-10. given two intervals of the same name opened on the UNSCOPED production path and held open together,
    /// then the real signpost stream shows them with two different ids. The scoped path makes its own ids, so before this
    /// test nothing covered the id production uses. Red if the unscoped path shares one id between intervals.
    @Test("OC-WORF510-10 the unscoped production path gives each interval its own real signpost id")
    func unscopedIdsDistinct() async throws {
        let probe = SignpostProbe()
        do {
            try await probe.start()
            let one = Signposts.begin(.retentionClearHistory)
            let two = Signposts.begin(.retentionClearHistory)
            one.end()
            two.end()
            let seen = try await probe.wait { $0.filter { $0.event.name == "retention.clearHistory" && $0.event.type == "begin" }.count >= 2 }
            try await probe.flush()
            let begins = probe.marks().filter { $0.event.name == "retention.clearHistory" && $0.event.type == "begin" }
            await probe.stop()
            #expect(seen, "the stream never delivered both begins")
            let ids = begins.map(\.id)
            #expect(Set(ids).count == ids.count, "two intervals began with the same real id: \(ids)")
        } catch {
            await probe.stop()
            throw error
        }
    }
}
