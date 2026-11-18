import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8V remediation B: the storage halves of OC-7032, OC-7034, OC-7098, OC-7106 and OC-7118.
//
// Layer notes (what is NOT asserted here, and why):
//   - OC-7032: "dropped on the Shelf" and "screenshot imported" are FlotsamShelf / FlotsamCapture UI and capture
//     paths. Storage's half is the code the ingest returns (STO-DB-001, never CAP-IO-001) and item count delta 0
//     for a text and a screenshot candidate. The surfacing half is deferred to TASK-363.
//   - OC-7034: windows, the Recent list and the Shelf strip are UI. Storage's half is the event a window
//     subscribes to (published after commit, once per saved copy, never for a failed one) and the Library query
//     and sidebar count that event makes the windows re-read. UI half deferred to TASK-363.
//   - OC-7098: the progress sheet, HUD string and release-build timing are UI / 9F. Storage's half is the work:
//     10,000 items (2,000 images with blobs) cleared, count 0, deletedCount 10,000, progress reported up to
//     (10,000, 10,000), inside the 5 s budget (the budget is applied to a debug build here, so it is a floor, and is load-normalized, TASK-475).
//   - OC-7106: the menu item and the poll are Capture / app-shell. Storage's half is the CaptureMode logic the menu
//     label and the poll gate both read, and that the chosen mode persists. UI half deferred to TASK-363.
//   - OC-7118: the Notice throttle and the five log lines are written by Capture (FlotsamCapture is an empty
//     module today; storage logs nothing for a disk-guard refusal). Storage's half is five refusals, each
//     STO-LIM-002 as a warning, nothing stored. Deferred to TASK-363.

private let png16 = TestImage.make(width: 16, height: 16, format: .png)

@Suite struct Unmapped007IngestTests {
    // MARK: OC-7032 (storage half)

    private func fillDisk(_ rig: Rig) async throws {
        try await rig.store.database.pool.write { db in
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count")!
            try db.execute(sql: "PRAGMA max_page_count = \(pages)")
        }
    }

    private func failure(_ result: FlotsamResult<IngestResult>) -> FlotsamError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    /// OC-7032 storage half. Red if the write failure is mapped to another code (CAP-IO-001 included), swallowed
    /// as a success, or leaves a row or a blob behind for either the text or the screenshot.
    @Test("OC-7032 a forced write failure gives STO-DB-001 and item count delta 0 for a dropped text and an imported screenshot")
    func oc7032_forcedWriteFailureLeavesNothing() async throws {
        // given one stored item and a database that cannot grow
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let survivor = try await rig.create(rig.text("k-7032-survivor", "stays"))
        let blobsBefore = rig.blobFiles()
        #expect(try rig.itemCount() == 1)
        try await fillDisk(rig)
        let hugeKey = String(repeating: "k", count: 1_000_000)

        // when a text is dropped on the Shelf, and separately a screenshot is imported (each needs new pages)
        let text = await rig.ingest.ingest(rig.text(hugeKey + "-text", String(repeating: "t", count: 1_000_000), origin: .shelfDrop))
        let shot = await rig.ingest.ingest(rig.image(hugeKey + "-shot", png16, kind: .screenshot, origin: .screenshotFile))

        // then each fails with the storage code, not the capture code, and the item count did not move
        #expect(failure(text)?.code == .stoDb001)
        #expect(failure(shot)?.code == .stoDb001)
        #expect(failure(text)?.code.rawValue == "STO-DB-001")
        #expect(failure(shot)?.code.rawValue == "STO-DB-001")
        #expect(try rig.itemCount() == 1)
        #expect(try rig.store.presentIdStrings() == [survivor.uuidString])
        #expect(try rig.store.count("representation") == 0)
        #expect(rig.blobFiles() == blobsBefore)
    }

    // MARK: OC-7034 (storage half)

    /// OC-7034 storage half. Red if the event is not published, is published before the commit (the observer reads
    /// the old count), is published twice for one copy, or a failed copy publishes one.
    @Test("OC-7034 a saved copy publishes itemsChanged once, after the commit, and the Library and sidebar already show it")
    func oc7034_savedCopyPublishesAfterCommit() async throws {
        // given a Library with text count C = 2 and a window-like observer that reads the database when told
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        _ = try await rig.create(rig.text("k-7034-a", "alpha"))
        rig.store.clock.advance(ms: 1_000)
        _ = try await rig.create(rig.text("k-7034-b", "bravo"))
        let before = try await rig.store.database.sidebarCounts().get()
        #expect(before.kinds[.text] == 2)

        let seen = Locked<[Int]>([])
        let store = rig.store
        let unsubscribe = rig.store.database.events.subscribe { event in
            guard case .itemsChanged = event else { return }
            let visible = (try? store.count("item")) ?? -1
            seen.mutate { $0.append(visible) }
        }
        defer { unsubscribe() }

        // when a new text is copied
        rig.store.clock.advance(ms: 1_000)
        let created = try await rig.create(rig.text("k-7034-c", "charlie"))

        // then exactly one event arrived, the committed row was already visible when it did, and the windows'
        // queries show it at the top of Recent with the Text count at C+1
        #expect(seen.value == [3])
        let page = try await rig.store.database.items(matching: LibraryQuery(filter: .all, text: "", sort: .recent, page: 0)).get()
        #expect(page.totalCount == 3)
        #expect(page.rows.first?.id == created)
        let after = try await rig.store.database.sidebarCounts().get()
        #expect(after.kinds[.text] == 3)
        #expect(after.all == 3)

        // when the next copy fails (database full), then no event is published and the count stays
        try await fillDisk(rig)
        let failed = await rig.ingest.ingest(rig.text("k-7034-d", String(repeating: "x", count: 1_000_000)))
        #expect(failure(failed)?.code == .stoDb001)
        #expect(seen.value == [3])
        #expect(try rig.itemCount() == 3)
    }

    // MARK: OC-7098 (storage half)

    /// OC-7098 storage half. Red if Clear History stops after a batch (count stays above 0), under-reports
    /// deletedCount, skips progress, leaves blobs or representation rows, or passes 5 s.
    @Test("OC-7098 Clear History All time on 10,000 items including 2,000 images finishes inside 5 s with everything gone")
    func oc7098_clearAllTimeOnTenThousand() async throws {
        // given 10,000 non-exempt items, 2,000 of them images with a blob each
        let s = try await Store.make()
        defer { s.cleanUp() }
        var specs: [Spec] = []
        for n in 1...8_000 { specs.append(Spec(n: n, ageMs: Int64(n) * 1_000)) }
        for n in 8_001...10_000 { specs.append(Spec(n: n, kind: .image, ageMs: Int64(n) * 1_000, blobs: 1, repBytes: 10)) }
        try await s.insert(specs)
        #expect(try s.count("item") == 10_000)
        #expect(try s.count("representation") == 2_000)

        let progress = Locked<[[Int]]>([])
        let events = EventCollector(s.database.events)

        // when All time is confirmed
        // The 5 s budget is on the clear call alone (setup is excluded) and is load-normalized (TASK-475): the wall time
        // is scaled by the CPU share a spinning probe thread was given while the clear ran, so a machine running at
        // load average 700 does not turn a 2 s clear into a 13 s failure, while a clear that really does more work or
        // stalls (the share stays near 1) still reads its full wall time against 5 s.
        let probe = CPUShareProbe()
        defer { _ = probe.stop() }  // a throwing clear must still end the spin thread; stop() is idempotent
        let started = DispatchTime.now().uptimeNanoseconds
        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: false) { done, total in
            progress.mutate { $0.append([done, total]) }
        }.get()
        let wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        let share = probe.stop()
        let loadNormalized = wall * max(share, 0.02)

        // then it finished within 5 s (load-normalized), deleted 10,000, left no row, representation or blob, and told the UI
        #expect(loadNormalized < 5.0, "Clear History of 10,000 took \(wall) s wall, CPU share \(share), load-normalized \(loadNormalized) s")
        #expect(outcome.deletedCount == 10_000)
        #expect(try s.count("item") == 0)
        #expect(try s.count("representation") == 0)
        #expect(events.deletedIds.count == 10_000)
        #expect(!s.exists(s.blobURL(8_001, 1)))
        #expect(!s.exists(s.blobURL(10_000, 1)))
        #expect(progress.value.last == [10_000, 10_000])
        #expect(progress.value.count == 20)
        #expect(progress.value.allSatisfy { $0[1] == 10_000 })
    }

    // MARK: OC-7106 (logic half)

    /// OC-7106 logic half. Red if the toggle maps a state to the wrong mode, Curated stops showing Pause, or the
    /// poll gate answers yes while paused.
    @Test("OC-7106 the menu toggle flips Active and Paused, Curated pauses, and only Active lets the poll and screenshots save")
    func oc7106_menuToggleAndGates() throws {
        // given each mode, then when the menu item is chosen
        // then the mode, the label state and both gates are the literal expected values
        #expect(CaptureMode.active.afterMenuToggle == .paused)
        #expect(CaptureMode.paused.afterMenuToggle == .active)
        #expect(CaptureMode.curated.afterMenuToggle == .paused)
        #expect(CaptureMode.active.isPaused == false)
        #expect(CaptureMode.paused.isPaused == true)
        #expect(CaptureMode.curated.isPaused == false)
        #expect(CaptureMode.active.capturesClipboardAutomatically == true)
        #expect(CaptureMode.paused.capturesClipboardAutomatically == false)
        #expect(CaptureMode.curated.capturesClipboardAutomatically == false)
        #expect(CaptureMode.active.importsScreenshots == true)
        #expect(CaptureMode.paused.importsScreenshots == false)
        #expect(CaptureMode.curated.importsScreenshots == false)
        #expect(CaptureMode.allCases.count == 3)
    }

    /// OC-7106, sequence. Pause then Resume: the stored mode is Paused after the first choice and Active after the
    /// second, read through a fresh SettingsStore, and the label state follows. Red if the toggled mode is not stored.
    @Test("OC-7106 Pause then Resume leaves Paused and then Active in the setting, read back by a fresh store")
    func oc7106_pauseThenResumePersists() throws {
        // given Active (the default) in a store
        let kv = MemoryKV()
        let first = SettingsStore(store: kv)
        #expect(first.value(SettingKeys.captureMode) == .active)

        // when Pause Capture is chosen
        first.set(first.value(SettingKeys.captureMode).afterMenuToggle, for: SettingKeys.captureMode)

        // then a fresh store reads Paused and the menu would read Resume Capture
        let afterPause = SettingsStore(store: kv).value(SettingKeys.captureMode)
        #expect(afterPause == .paused)
        #expect(afterPause.isPaused == true)
        #expect(afterPause.capturesClipboardAutomatically == false)

        // when Resume Capture is chosen
        first.set(afterPause.afterMenuToggle, for: SettingKeys.captureMode)

        // then a fresh store reads Active again and capture is on
        let afterResume = SettingsStore(store: kv).value(SettingKeys.captureMode)
        #expect(afterResume == .active)
        #expect(afterResume.isPaused == false)
        #expect(afterResume.capturesClipboardAutomatically == true)
    }

    // MARK: OC-7118 (storage half)

    /// OC-7118 storage half. Red if the image tier is dropped, one of the five images slips through, a refusal is
    /// not a warning, or a refusal leaves a row or blob.
    @Test("OC-7118 at 400 MiB free five images in a row create 0 items and each is refused STO-LIM-002 as a warning")
    func oc7118_fiveImagesRefused() async throws {
        // given 400 MiB free and an empty library
        let rig = try await Rig.make(capacity: 400 * mib)
        defer { rig.cleanUp() }

        // when five different images are copied
        var results: [FlotsamResult<IngestResult>] = []
        for n in 1...5 {
            rig.store.clock.advance(ms: 1_000)
            results.append(await rig.ingest.ingest(rig.image("k-7118-\(n)", png16)))
        }

        // then every one is refused as a warning carrying the free space, and nothing was stored
        let errors = results.compactMap(failure)
        #expect(errors.count == 5)
        #expect(errors.allSatisfy { $0.code == .stoLim002 })
        #expect(errors.allSatisfy { $0.severity == .warning })
        #expect(errors.allSatisfy { $0.context[.byteSize] == .bytes(419_430_400) })
        #expect(try rig.itemCount() == 0)
        #expect(try rig.store.count("representation") == 0)
        #expect(rig.blobFiles().isEmpty)

        // when the volume frees up, then the same kind of image is stored (the refusals did not poison the store)
        rig.fileSystem.setCapacity(10 * 1024 * mib)
        _ = try await rig.create(rig.image("k-7118-after", png16))
        #expect(try rig.itemCount() == 1)
    }
}

/// How much of a core the machine gave a thread that wanted all of one, over the window between `init` and `stop()`:
/// thread CPU time divided by wall time, 1.0 on an idle machine and small when it is starved. A wall-clock budget
/// multiplied by this is the time the work would have taken with the CPU to itself, so the budget stops depending on
/// how many other processes (or other tests) are running. A sleep or an I/O stall inside the work does not lower the
/// share, so it still counts against the budget in full.
final class CPUShareProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    private var share = 1.0
    private var sink: UInt64 = 0
    private let running = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)

    init() {
        let thread = Thread { [self] in run() }
        thread.start()
        running.wait()
    }

    /// Ends the window and returns the share, in (0, 1]. Safe to call more than once (a `defer` guards the throw
    /// path while the happy path reads the value): the first call ends the window, later calls return the same share.
    func stop() -> Double {
        lock.withLock { stopRequested = true }
        finished.wait()
        finished.signal()
        return lock.withLock { share }
    }

    private static func threadCPUNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }

    private func run() {
        let wall0 = DispatchTime.now().uptimeNanoseconds
        let cpu0 = Self.threadCPUNanos()
        running.signal()
        var acc: UInt64 = 1
        while !lock.withLock({ stopRequested }) {
            for _ in 0..<20_000 { acc = acc &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        }
        sink = acc
        let cpu = Double(Self.threadCPUNanos() - cpu0)
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wall0)
        lock.withLock { share = wall > 0 ? min(1, cpu / wall) : 1 }
        finished.signal()
    }
}

/// A value two threads touch, for callbacks that run off the test's task.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

extension Store {
    func presentIdStrings() throws -> Set<String> {
        Set(try reader().read { try String.fetchAll($0, sql: "SELECT id FROM item") })
    }
}
