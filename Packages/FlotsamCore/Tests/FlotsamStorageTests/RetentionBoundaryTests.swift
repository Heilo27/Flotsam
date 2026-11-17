import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T remediation, retention boundaries and in-transaction guards (FR-007-08, 09, 10, 11, 15). Every expected
// value is a literal. Where a test has to land a pin, trigger, hotkey or grace stamp between a run's read and its
// delete, it holds the database writer with the edit uncommitted: the run's reads still see the old snapshot, its delete
// queues behind the writer, and the edit commits first. That is the only ordering the public API cannot produce on its own.

/// What lands between the read and the delete, as the SQL a user action would have run.
private enum LateEdit: CaseIterable, CustomTestStringConvertible, Sendable {
    case pinned, trigger, hotkey, graceReentered

    var testDescription: String {
        switch self {
        case .pinned: "pinned"
        case .trigger: "given a trigger"
        case .hotkey: "given a shortcut"
        case .graceReentered: "unpinned again (grace restarted)"
        }
    }

    /// Applies the edit to one item. `now` is the store clock at the time of the run.
    func apply(_ db: Database, item: String, now: Int64) throws {
        switch self {
        case .pinned:
            try db.execute(sql: "UPDATE item SET pinned = 1 WHERE id = ?", arguments: [item])
        case .trigger:
            try db.execute(sql: "UPDATE item SET \"trigger\" = ';late' WHERE id = ?", arguments: [item])
        case .hotkey:
            try db.execute(sql: "UPDATE item SET hotkeyCode = 5, hotkeyModifiers = 1 WHERE id = ?", arguments: [item])
        case .graceReentered:
            try db.execute(sql: "UPDATE item SET exemptReleasedAt = ? WHERE id = ?", arguments: [now - 3_600_000, item])
        }
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var error: Error? { lock.withLock { stored } }
    func set(_ error: Error) { lock.withLock { stored = error } }
}

/// Synchronous on purpose: GRDB's async `read` overload would otherwise be chosen inside an async test.
private func scalar(_ s: Store, _ sql: String, _ arguments: StatementArguments = []) throws -> Int? {
    try s.reader().read { try Int.fetchOne($0, sql: sql, arguments: arguments) }
}

private func wait(for semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            semaphore.wait()
            continuation.resume()
        }
    }
}

/// Runs `operation` while `edit` sits uncommitted in the writer. The operation's reads see the state before the edit; its
/// delete cannot start until the edit commits, so the delete's own guard is the only thing standing between the edit
/// and a deletion. If the operation's read were slow enough to see the committed edit, the outcome assertions in the
/// callers would go red (a different set of items is chosen), so this cannot turn a failure into a silent pass.
private func runWithEditLandingBeforeDelete<T: Sendable>(
    _ s: Store, edit: @escaping @Sendable (Database) throws -> Void, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let pool = s.database.pool
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let failure = ErrorBox()
    DispatchQueue.global().async {
        do {
            try pool.write { db in
                let applied = Result { try edit(db) }
                held.signal()
                release.wait()
                try applied.get()
            }
        } catch {
            failure.set(error)
        }
        finished.signal()
    }
    await wait(for: held)
    let running = Task { try await operation() }
    try await Task.sleep(for: .milliseconds(500))
    release.signal()
    await wait(for: finished)
    if let error = failure.error { throw error }
    return try await running.value
}

@Suite struct RetentionBoundaryTests {
    private func images(_ range: ClosedRange<Int>, extra: (Int) -> Spec = { Spec(n: $0) }) -> [Spec] {
        range.map { n in
            var spec = extra(n)
            spec.n = n
            spec.kind = .image
            spec.blobs = 1
            spec.repBytes = 100 * mib
            spec.ageMs = Int64(range.upperBound - n + 1) * dayMs  // n = 1 is the oldest
            return spec
        }
    }

    // MARK: In-transaction guard, image budget (FR-007-08, FR-007-15)

    /// OC-7059 / OC-7071. Given 600 MiB of six unpinned 100 MiB images against a 500 MiB budget, so the plan is the two
    /// oldest (1 and 2), when image 1 becomes exempt (or re-enters its grace) after the plan and before the delete, then
    /// only image 2 goes: 1 is kept with its blob, 3..6 are untouched, and the count is 1, not the planned 2.
    @Test(arguments: LateEdit.allCases)
    fileprivate func oc7059_oc7071_budgetKeepsImageThatBecameProtectedAfterPlan(_ edit: LateEdit) async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(images(1...6, extra: { n in Spec(n: n, releasedAgoMs: n == 1 && edit == .graceReentered ? 2 * dayMs : nil) }))
        let now = s.clock.millis
        let victim = Store.id(1).uuidString

        let outcome = try await runWithEditLandingBeforeDelete(
            s, edit: { try edit.apply($0, item: victim, now: now) },
            operation: { [database = s.database] in try await database.enforceImageBudget(.mib500).get() })

        #expect(outcome.evictedCount == 1)
        #expect(try s.presentIds() == [1, 3, 4, 5, 6])
        #expect(s.exists(s.blobURL(1, 1)))
        #expect(!s.exists(s.blobURL(2, 1)))
        #expect(try s.sumRepresentationBytes() == 500 * mib)
        #expect(outcome.notice == nil)
    }

    // MARK: In-transaction guard, Clear History (FR-007-11, FR-007-15)

    /// OC-7089. Given four non-exempt items selected for Clear History (all time, exempt items kept), when item 1 is
    /// pinned, item 2 given a trigger and item 3 given a shortcut after the selection and before the delete, then only
    /// item 4 goes, the count says 1, and 1, 2 and 3 keep their pin, trigger and shortcut.
    @Test func oc7089_clearHistoryKeepsItemsExemptedAfterSelection() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert((1...4).map { Spec(n: $0, ageMs: hourMs) })
        let (one, two, three) = (Store.id(1).uuidString, Store.id(2).uuidString, Store.id(3).uuidString)

        let outcome = try await runWithEditLandingBeforeDelete(
            s,
            edit: { db in
                try LateEdit.pinned.apply(db, item: one, now: 0)
                try LateEdit.trigger.apply(db, item: two, now: 0)
                try LateEdit.hotkey.apply(db, item: three, now: 0)
            },
            operation: { [database = s.database] in try await database.clearHistory(range: .allTime, includeExempt: false).get() })

        #expect(outcome.deletedCount == 1)
        #expect(try s.presentIds() == [1, 2, 3])
        #expect(try s.trigger(of: 2) == ";late")
        #expect(try scalar(s, "SELECT pinned FROM item WHERE id = ?", [one]) == 1)
        #expect(try scalar(s, "SELECT hotkeyCode FROM item WHERE id = ?", [three]) == 5)
    }

    // MARK: 24 h grace boundary (FR-007-10)

    /// OC-7071. Given an item 40 d old whose last exemption was released R ago, when a 30 d sweep runs, then at R = 24 h
    /// less 1 ms and at exactly 24 h it is kept, and at 24 h plus 1 ms it goes.
    @Test(arguments: [
        (Int64(86_399_999), true),
        (Int64(86_400_000), true),
        (Int64(86_400_001), false),
    ])
    func oc7071_sweepGraceBoundary(releasedAgoMs: Int64, kept: Bool) async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: 40 * dayMs, releasedAgoMs: releasedAgoMs), Spec(n: 2, ageMs: 40 * dayMs)])

        let outcome = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        // The never-exempt control proves the sweep ran and deleted what it may.
        #expect(outcome.retentionDeleted == (kept ? 1 : 2))
        #expect(try s.presentIds() == (kept ? [1] : []))
    }

    /// OC-7071 on the budget path, which reads the same grace. Given six 100 MiB images with 1 released exactly 24 h ago
    /// and 2 released 24 h plus 1 ms ago, when the 500 MiB budget is enforced, then 1 is not a candidate, so 2 and 3 are
    /// evicted and 1 survives.
    @Test func oc7071_budgetGraceBoundary() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(images(1...6, extra: { n in
            Spec(n: n, releasedAgoMs: n == 1 ? 86_400_000 : (n == 2 ? 86_400_001 : nil))
        }))

        let outcome = try await s.database.enforceImageBudget(.mib500).get()

        #expect(outcome.evictedCount == 2)
        #expect(try s.presentIds() == [1, 4, 5, 6])
        #expect(s.exists(s.blobURL(1, 1)))
        #expect(!s.exists(s.blobURL(2, 1)) && !s.exists(s.blobURL(3, 1)))
    }

    // MARK: exemptReleasedAt is stamped only on the exempt to not-exempt transition (FR-007-10)

    private static let editsThatLeaveAnItemUnexempt: [ExemptionEdit] = [.setPinned(false), .setTrigger(nil), .setHotkey(nil)]

    /// OC-7072. Given an item that was never exempt, when an edit that removes nothing runs (unpin, clear trigger, clear
    /// shortcut), then exemptReleasedAt stays null and the item is not given a grace; the edit still reports success.
    @Test(arguments: RetentionBoundaryTests.editsThatLeaveAnItemUnexempt)
    func oc7072_editingNeverExemptItemLeavesStampNull(edit: ExemptionEdit) async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: 40 * dayMs), Spec(n: 2, ageMs: 40 * dayMs, pinned: true)])
        s.clock.advance(ms: hourMs)

        let applied = try await s.database.applyExemptionEdit(edit, to: Store.id(1)).get()

        #expect(applied)
        #expect(try s.exemptReleasedAt(1) == nil)
        #expect(try s.exemptReleasedAt(2) == nil)
    }

    /// OC-7074. Given an item whose pin was released 5 h ago (stamp = U), when the user clears its absent trigger or
    /// shortcut or unpins it again an hour later, then the stamp is still U (grace is not extended) and a sweep at
    /// U + 24 h 1 min removes it.
    @Test(arguments: RetentionBoundaryTests.editsThatLeaveAnItemUnexempt)
    func oc7074_editingAlreadyReleasedItemDoesNotExtendGrace(edit: ExemptionEdit) async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        let released = s.clock.millis - 5 * hourMs
        try await s.insert(Spec(n: 1, ageMs: 40 * dayMs, releasedAgoMs: 5 * hourMs))
        s.clock.advance(ms: hourMs)

        _ = try await s.database.applyExemptionEdit(edit, to: Store.id(1)).get()

        #expect(try s.exemptReleasedAt(1) == released)
        s.clock.advance(ms: 18 * hourMs + 61 * 60_000)  // now = U + 24 h 1 min... 5 h + 1 h + 18 h 61 min after U + 5 h
        let outcome = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        #expect(outcome.retentionDeleted == 1)
        #expect(try s.count("item") == 0)
    }

    /// OC-7072 control for the two tests above: the stamp is the unpin instant when the edit does remove the last
    /// exemption, for each of pin, trigger and shortcut.
    @Test(arguments: [
        (Spec(n: 1, ageMs: 40 * dayMs, pinned: true), ExemptionEdit.setPinned(false)),
        (Spec(n: 1, ageMs: 40 * dayMs, trigger: ";x"), ExemptionEdit.setTrigger(nil)),
        (Spec(n: 1, ageMs: 40 * dayMs, hotkey: 9), ExemptionEdit.setHotkey(nil)),
    ])
    func oc7072_removingLastExemptionStampsTheEditInstant(spec: Spec, edit: ExemptionEdit) async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(spec)
        s.clock.advance(ms: 3 * hourMs)
        let editedAt = s.clock.millis

        _ = try await s.database.applyExemptionEdit(edit, to: Store.id(1)).get()

        #expect(try s.exemptReleasedAt(1) == editedAt)
    }

    // MARK: Clear History range edges (FR-007-11)

    /// OC-7091. Given five items last copied 1 ms after the clear starts, at the start instant, 1 ms inside the range, exactly
    /// at the range edge and 1 ms beyond it, when Clear History runs for the range, then the start instant, the inside item and
    /// the edge item go, and the future and beyond-the-edge items stay. The preview agrees.
    @Test(arguments: [
        (ClearRange.lastHour, Int64(3_600_000)),
        (ClearRange.last24Hours, Int64(86_400_000)),
    ])
    func oc7091_clearRangeEdges(range: ClearRange, lookbackMs: Int64) async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([
            Spec(n: 1, ageMs: -1),
            Spec(n: 2, ageMs: 0),
            Spec(n: 3, ageMs: lookbackMs - 1),
            Spec(n: 4, ageMs: lookbackMs),
            Spec(n: 5, ageMs: lookbackMs + 1),
        ])

        let preview = try await s.database.clearHistoryPreview(range: range, includeExempt: false).get()
        let outcome = try await s.database.clearHistory(range: range, includeExempt: false).get()

        #expect(preview.count == 3)
        #expect(outcome.deletedCount == 3)
        #expect(try s.presentIds() == [1, 5])
        #expect(try s.count("item") == 2)
    }

    /// OC-7091 (all time). Given an item at the start instant, one 400 d old and one copied 1 ms after the start, when all
    /// time is cleared, then the first two go (no lower bound) and the future one stays (upper bound).
    @Test func oc7091_allTimeHasUpperBoundOnly() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: -1), Spec(n: 2, ageMs: 0), Spec(n: 3, ageMs: 400 * dayMs)])

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: false).get()

        #expect(outcome.deletedCount == 2)
        #expect(try s.presentIds() == [1])
    }

    // MARK: Database scrub (FR-007-11)

    private func fileBytes(_ s: Store, _ name: String) -> Data {
        (try? Data(contentsOf: s.root.appendingPathComponent(name))) ?? Data()
    }

    private func fileSize(_ s: Store, _ name: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: s.root.appendingPathComponent(name).path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// OC-7153. Given 150 text items of about 6 KB each carrying a unique marker, folded into the main database file, when
    /// Clear History (all time) completes, then no free pages are left (freelist_count 0), the database file is far
    /// smaller than before, and neither the file nor its WAL holds any marker.
    @Test func oc7153_clearAllReturnsFreePagesAndLeavesNoMarkerBytes() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        let padding = String(repeating: "lorem ipsum dolor sit amet ", count: 220)
        try await s.insert((1...150).map { Spec(n: $0, ageMs: hourMs, text: "ORCHID-7153-\($0)-\(padding)") })
        try await s.database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        let sizeBefore = fileSize(s, "flotsam.sqlite")
        let freeBefore = try scalar(s, "PRAGMA freelist_count")
        #expect(freeBefore == 0)
        #expect(fileBytes(s, "flotsam.sqlite").range(of: Data("ORCHID-7153-77-".utf8)) != nil)  // the scan can find a marker
        #expect(sizeBefore > 1_500_000)

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: false).get()

        #expect(outcome.deletedCount == 150)
        #expect(outcome.checkpointCompleted)
        #expect(try s.count("item") == 0)
        #expect(try scalar(s, "PRAGMA freelist_count") == 0)
        #expect(fileSize(s, "flotsam.sqlite") < 400_000)
        for name in ["flotsam.sqlite", "flotsam.sqlite-wal"] {
            #expect(fileBytes(s, name).range(of: Data("ORCHID-7153-".utf8)) == nil, "marker bytes left in \(name)")
        }
        #expect(fileSize(s, "flotsam.sqlite-wal") == 0)
    }
}
