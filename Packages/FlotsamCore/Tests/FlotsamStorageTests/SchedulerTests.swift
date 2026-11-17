import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T, the two background schedulers: RetentionScheduler (FR-007-09, OC-7075) and ReconcileScheduler
// (FR-007-13, scheduler part of OC-7113). Expected durations and counts are literals from the FRD.
//
// The schedulers sleep on `database.clock`. `ManualClock.sleep` returns at once, which would spin the loop, so these
// tests use `GatedClock`: every `sleep` is recorded and then holds until the test releases it, which is "the time has
// passed". It never relies on `sleep` throwing: a cancelled sleeper just returns, and the scheduler stops because its
// task is cancelled, which is true whether or not the protocol's `sleep` can throw.
//
// What a scheduler did is read from the world, not from the scheduler: rows through a second read-only connection,
// blob files on disk, the clock's own record of the durations it was asked to wait, and how often the settings store
// was read (one read of the retention key is one sweep).

// MARK: Doubles

/// Literal durations from the FRD, typed once so expectations stay cheap to type-check.
let oneWeek: Duration = .seconds(604_800)
let oneHour: Duration = .seconds(3600)
let thirtySeconds: Duration = .seconds(30)
let fifteenSeconds: Duration = .seconds(15)

/// Holds every `sleep` until `release()`; reports `now()` from a `ManualClock` so the Store helpers and file ages agree.
final class GatedClock: WallClock, @unchecked Sendable {
    private let base: ManualClock
    private let lock = NSLock()
    private var requested: [Duration] = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelled: Set<UUID> = []

    init(_ base: ManualClock) { self.base = base }

    func now() -> Date { base.now() }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Recorded in the same critical section that registers the waiter, so a test that sees the duration
                // can release it without the wake-up being lost.
                let resumeNow = lock.withLock { () -> Bool in
                    requested.append(duration)
                    if cancelled.contains(id) || Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                cancelled.insert(id)
                return waiters.removeValue(forKey: id)
            }
            waiter?.resume()
        }
    }

    /// Every duration a scheduler has asked to sleep, in order.
    var sleeps: [Duration] { lock.withLock { requested } }

    /// The time has passed: wakes every sleeper that is waiting right now.
    func release() {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let all = Array(waiters.values)
            waiters.removeAll()
            return all
        }
        for waiter in woken { waiter.resume() }
    }
}

/// A settings backing store that counts reads per key.
final class CountingKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var reads: [String: Int] = [:]

    func string(forKey key: String) -> String? { lock.withLock { reads[key, default: 0] += 1; return values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
    func readCount(of key: String) -> Int { lock.withLock { reads[key, default: 0] } }
}

/// Collects what `onNotice` was handed.
final class NoticeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [ErrorCode] = []
    func add(_ error: FlotsamError) { lock.withLock { codes.append(error.code) } }
    var all: [ErrorCode] { lock.withLock { codes } }
}

/// A store whose database sleeps on a `GatedClock`.
func makeGatedStore() async throws -> (store: Store, clock: GatedClock) {
    let manual = ManualClock()
    let gated = GatedClock(manual)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-sched-\(UUID().uuidString)")
    let database = try await FlotsamDatabase.open(folder: root, fileSystem: LocalFileSystem(), clock: gated).get()
    return (Store(root: root, clock: manual, database: database), gated)
}

/// Lets anything that would wrongly run get its chance. Used only to prove an absence.
func settle() async { try? await Task.sleep(nanoseconds: 300_000_000) }

// MARK: Retention

@Suite struct RetentionSchedulerTests {
    private let retentionKey = "storage.retention"

    private func make() async throws -> (store: Store, clock: GatedClock, kv: CountingKV, settings: SettingsStore, notices: NoticeBox, scheduler: RetentionScheduler) {
        let (store, clock) = try await makeGatedStore()
        let kv = CountingKV()
        let settings = SettingsStore(store: kv)
        settings.set(.d30, for: SettingKeys.storageRetention)
        settings.set(.unlimited, for: SettingKeys.storageImageBudget)
        let notices = NoticeBox()
        let scheduler = RetentionScheduler(database: store.database, settings: settings, onNotice: { notices.add($0) })
        return (store, clock, kv, settings, notices, scheduler)
    }

    /// OC-7075, launch delay (RetentionScheduler.swift:9). Given retention 30 d and one 31 d old item, when the
    /// scheduler starts, then it asks to wait 30 s, nothing is swept while it waits, and once that wait ends the
    /// old item goes while the pinned and recent items stay.
    @Test func oc7075_firstSweepWaitsThirtySecondsThenRuns() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        try await r.store.insert([Spec(n: 1, ageMs: 31 * dayMs), Spec(n: 2, ageMs: 31 * dayMs, pinned: true), Spec(n: 3, ageMs: dayMs)])

        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 1 })
        #expect(r.clock.sleeps == [thirtySeconds])
        await settle()
        #expect(try r.store.presentIds() == [1, 2, 3])
        #expect(r.kv.readCount(of: retentionKey) == 0)

        r.clock.release()
        #expect(await waitUntil { (try? r.store.presentIds()) == [2, 3] })
        #expect(try r.store.count("item") == 2)
        await r.scheduler.stop()
    }

    /// OC-7075, cadence (RetentionScheduler.swift:10). Given the first sweep has run, when the scheduler waits again,
    /// then it asks for one hour, an item that became eligible meanwhile is not swept early, and it goes when that
    /// hour ends.
    @Test func oc7075_nextSweepIsOneHourLater() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        try await r.store.insert(Spec(n: 1, ageMs: 31 * dayMs))
        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 1 })
        r.clock.release()
        #expect(await waitUntil { r.clock.sleeps.count == 2 })
        #expect(try r.store.presentIds() == [])
        #expect(r.clock.sleeps == [thirtySeconds, oneHour])

        try await r.store.insert([Spec(n: 4, ageMs: 40 * dayMs), Spec(n: 5, ageMs: dayMs)])
        await settle()
        #expect(try r.store.presentIds() == [4, 5])

        r.clock.release()
        #expect(await waitUntil { (try? r.store.presentIds()) == [5] })
        #expect(await waitUntil { r.clock.sleeps.count == 3 })
        #expect(r.clock.sleeps == [thirtySeconds, oneHour, oneHour])
        await r.scheduler.stop()
    }

    /// OC-7075, stop (RetentionScheduler.swift:44). Given a scheduler waiting for its first sweep, when it is stopped
    /// and the wait then ends, then no sweep happens and it waits no further.
    @Test func oc7075_stopBeforeFirstSweepPreventsAnySweep() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        try await r.store.insert([Spec(n: 1, ageMs: 31 * dayMs), Spec(n: 2, ageMs: dayMs)])
        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 1 })

        await r.scheduler.stop()
        r.clock.release()
        await settle()

        #expect(try r.store.presentIds() == [1, 2])
        #expect(r.kv.readCount(of: retentionKey) == 0)
        #expect(r.clock.sleeps.count == 1)
    }

    /// OC-7075, stop between sweeps. Given a scheduler that has swept once and is waiting an hour, when it is stopped
    /// and the hour ends, then the item that became eligible stays and the loop does not wait again.
    @Test func oc7075_stopBetweenSweepsPreventsTheNextSweep() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        try await r.store.insert(Spec(n: 1, ageMs: 31 * dayMs))
        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 1 })
        r.clock.release()
        #expect(await waitUntil { r.clock.sleeps.count == 2 })
        try await r.store.insert(Spec(n: 2, ageMs: 40 * dayMs))

        await r.scheduler.stop()
        r.clock.release()
        await settle()

        #expect(try r.store.presentIds() == [2])
        #expect(r.clock.sleeps.count == 2)
    }

    /// OC-7075, restart. Given a stopped scheduler, when it is started again, then it begins a fresh launch delay and
    /// sweeps after it (stop cleared the running loop).
    @Test func oc7075_startAfterStopBeginsAFreshLoop() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        try await r.store.insert(Spec(n: 1, ageMs: 31 * dayMs))
        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 1 })
        await r.scheduler.stop()

        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 2 })
        #expect(r.clock.sleeps == [thirtySeconds, thirtySeconds])
        r.clock.release()
        #expect(await waitUntil { (try? r.store.presentIds()) == [] })
        await r.scheduler.stop()
    }

    /// Start is idempotent. Given a running scheduler, when start is called twice more, then there is still one
    /// waiting loop, not three.
    @Test func startWhileRunningDoesNotAddALoop() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        await r.scheduler.start()
        await r.scheduler.start()
        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count >= 1 })
        await settle()
        #expect(r.clock.sleeps == [thirtySeconds])
        await r.scheduler.stop()
    }

    /// OC-7075, wake from sleep. Given a scheduler that was never started, when sweepNow is called (the app does this
    /// on wake), then the sweep runs immediately and without waiting on the clock.
    @Test func oc7075_sweepNowSweepsImmediatelyWithoutWaiting() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        try await r.store.insert([Spec(n: 1, ageMs: 31 * dayMs), Spec(n: 2, ageMs: dayMs)])

        await r.scheduler.sweepNow()

        #expect(try r.store.presentIds() == [2])
        #expect(r.clock.sleeps.isEmpty)
    }

    /// FR-007-09, settings read per run. Given Forever, when a sweep runs and the user then picks 30 days, then the
    /// first keeps the old item and the next removes it, with no restart.
    @Test func settingsAreReadAtEachRun() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        r.settings.set(.forever, for: SettingKeys.storageRetention)
        try await r.store.insert([Spec(n: 1, ageMs: 400 * dayMs), Spec(n: 2, ageMs: dayMs)])

        await r.scheduler.sweepNow()
        #expect(try r.store.presentIds() == [1, 2])

        r.settings.set(.d30, for: SettingKeys.storageRetention)
        await r.scheduler.sweepNow()
        #expect(try r.store.presentIds() == [2])
    }

    /// Overlap guard (RetentionScheduler.swift:51). Given two sweepNow calls at the same moment over a library with
    /// work to do, when both finish, then exactly one sweep ran (one read of the retention setting); and once idle a
    /// further call does run, so the guard releases.
    @Test func overlappingSweepNowRunsOnlyOneSweep() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        try await r.store.insert((1...300).map { Spec(n: $0, ageMs: 31 * dayMs) } + [Spec(n: 999, ageMs: dayMs)])

        async let first: Void = r.scheduler.sweepNow()
        async let second: Void = r.scheduler.sweepNow()
        _ = await (first, second)

        #expect(r.kv.readCount(of: retentionKey) == 1)
        #expect(try r.store.presentIds() == [999])

        await r.scheduler.sweepNow()
        #expect(r.kv.readCount(of: retentionKey) == 2)
    }

    /// FR-007-08 through the scheduler. Given 600 MiB of pinned images against a 500 MiB budget, when sweeps run, then
    /// nothing is deleted, `onNotice` receives STO-LIM-001 once, and a second sweep within 24 h passes none.
    @Test func budgetNoticeReachesOnNoticeOncePerDay() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        r.settings.set(.mib500, for: SettingKeys.storageImageBudget)
        try await r.store.insert(
            (1...6).map { Spec(n: $0, kind: .image, ageMs: dayMs, pinned: true, blobs: 1, repBytes: 100 * mib) })

        await r.scheduler.sweepNow()
        #expect(r.notices.all == [.stoLim001])
        await r.scheduler.sweepNow()
        #expect(r.notices.all == [.stoLim001])
        #expect(try r.store.count("item") == 6)
    }
}

// MARK: Reconcile

@Suite struct ReconcileSchedulerTests {
    private func make() async throws -> (store: Store, clock: GatedClock, scheduler: ReconcileScheduler) {
        let (store, clock) = try await makeGatedStore()
        return (store, clock, ReconcileScheduler(database: store.database))
    }

    /// OC-7113 (scheduler part), launch delay (ReconcileScheduler.swift:9). Given an orphan blob older than 10 min, a
    /// 2 min old orphan and a referenced blob, when the scheduler starts, then it asks to wait 15 s, repairs nothing
    /// while it waits, and after the wait removes only the old orphan.
    @Test func oc7113_firstPassWaitsFifteenSecondsThenRemovesOnlyTheOldOrphan() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        try await r.store.insert(Spec(n: 1, kind: .image, blobs: 1, repBytes: 10))
        let old = try r.store.plantOrphanBlob(50, ageMs: 11 * 60_000)
        let young = try r.store.plantOrphanBlob(51, ageMs: 2 * 60_000)

        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 1 })
        #expect(r.clock.sleeps == [fifteenSeconds])
        await settle()
        #expect(r.store.exists(old))

        r.clock.release()
        #expect(await waitUntil { !r.store.exists(old) })
        #expect(r.store.exists(young))
        #expect(r.store.exists(r.store.blobURL(1, 1)))
        #expect(try r.store.presentIds() == [1])
        await r.scheduler.stop()
    }

    /// OC-7113, weekly. Given the launch pass has run and an orphan is created after launch, when 7 days pass, then
    /// the scheduler waited 7 days (not 1) and the orphan, now older than 10 min, is deleted without a relaunch.
    @Test func oc7113_weeklyPassDeletesAnOrphanCreatedAfterLaunch() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 1 })
        r.clock.release()
        #expect(await waitUntil { r.clock.sleeps.count == 2 })
        #expect(r.clock.sleeps == [fifteenSeconds, oneWeek])

        let orphan = try r.store.plantOrphanBlob(60, ageMs: 2 * 60_000)
        let bystander = try r.store.plantOrphanBlob(61, ageMs: 2 * 60_000)
        r.store.clock.advance(ms: 7 * dayMs)
        let fresh = try r.store.plantOrphanBlob(62, ageMs: 60_000)
        #expect(r.store.exists(orphan))

        r.clock.release()
        #expect(await waitUntil { !r.store.exists(orphan) })
        #expect(!r.store.exists(bystander))
        #expect(r.store.exists(fresh))
        #expect(await waitUntil { r.clock.sleeps.count == 3 })
        #expect(r.clock.sleeps.last == oneWeek)
        await r.scheduler.stop()
    }

    /// OC-7113, stop (ReconcileScheduler.swift:36). Given a scheduler waiting for its first pass, when it is stopped
    /// and the wait ends, then the orphan stays and it waits no further.
    @Test func oc7113_stopBeforeFirstPassPreventsAnyPass() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        let orphan = try r.store.plantOrphanBlob(70, ageMs: 11 * 60_000)
        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 1 })

        await r.scheduler.stop()
        r.clock.release()
        await settle()

        #expect(r.store.exists(orphan))
        #expect(r.clock.sleeps.count == 1)
    }

    /// OC-7113, stop between passes. Given a scheduler waiting out the week after its first pass, when it is stopped
    /// and the week ends, then the new orphan stays and the loop does not wait again.
    @Test func oc7113_stopBetweenPassesPreventsTheWeeklyPass() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 1 })
        r.clock.release()
        #expect(await waitUntil { r.clock.sleeps.count == 2 })
        let orphan = try r.store.plantOrphanBlob(71, ageMs: 11 * 60_000)

        await r.scheduler.stop()
        r.clock.release()
        await settle()

        #expect(r.store.exists(orphan))
        #expect(r.clock.sleeps.count == 2)
    }

    /// Restart. Given a stopped scheduler, when it is started again, then it begins a fresh 15 s delay and repairs
    /// after it.
    @Test func startAfterStopBeginsAFreshLoop() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        let orphan = try r.store.plantOrphanBlob(72, ageMs: 11 * 60_000)
        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 1 })
        await r.scheduler.stop()

        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count == 2 })
        #expect(r.clock.sleeps == [fifteenSeconds, fifteenSeconds])
        r.clock.release()
        #expect(await waitUntil { !r.store.exists(orphan) })
        await r.scheduler.stop()
    }

    /// Start is idempotent. Given a running scheduler, when start is called twice more, then there is still one
    /// waiting loop.
    @Test func startWhileRunningDoesNotAddALoop() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        await r.scheduler.start()
        await r.scheduler.start()
        await r.scheduler.start()
        #expect(await waitUntil { r.clock.sleeps.count >= 1 })
        await settle()
        #expect(r.clock.sleeps == [fifteenSeconds])
        await r.scheduler.stop()
    }

    /// reconcileNow runs one pass at once and reports it. Given an old orphan and a young one, when it is called
    /// without start, then it returns an outcome counting exactly the one removal and no clock wait happened.
    @Test func reconcileNowRunsImmediatelyAndReportsTheOutcome() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        let old = try r.store.plantOrphanBlob(80, ageMs: 11 * 60_000)
        let young = try r.store.plantOrphanBlob(81, ageMs: 2 * 60_000)

        let outcome = await r.scheduler.reconcileNow()

        #expect(outcome?.orphanBlobsRemoved == 1)
        #expect(!r.store.exists(old))
        #expect(r.store.exists(young))
        #expect(r.clock.sleeps.isEmpty)
    }

    /// Overlap guard (ReconcileScheduler.swift:43). Given two reconcileNow calls at the same moment, when both finish,
    /// then exactly one ran a pass (one outcome, one nil) and that outcome removed the single orphan; once idle a
    /// further call does run, so the guard releases.
    @Test func overlappingReconcileNowRunsOnlyOnePass() async throws {
        let r = try await make()
        defer { r.store.cleanUp() }
        let orphan = try r.store.plantOrphanBlob(90, ageMs: 11 * 60_000)

        async let first = r.scheduler.reconcileNow()
        async let second = r.scheduler.reconcileNow()
        let results = await [first, second]

        #expect(results.compactMap { $0 }.count == 1)
        #expect(results.filter { $0 == nil }.count == 1)
        #expect(results.compactMap { $0 }.first?.orphanBlobsRemoved == 1)
        #expect(!r.store.exists(orphan))

        #expect(await r.scheduler.reconcileNow() != nil)
    }
}
