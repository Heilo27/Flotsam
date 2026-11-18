import FlotsamBase
import FlotsamCapture
@testable import FlotsamStorage
import Foundation
import GRDB
import Testing
@testable import FlotsamTriggers

/// TASK-424 / FR-001-03: a trigger expansion writes the pasteboard twice (the item, then the restored clipboard), and
/// the real capture, polling that pasteboard, must store neither write as a new item. The marker and ledger half is
/// pinned in `TriggerExpanderAdversarialTests`; this is the observable half: the item count.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct Task424TriggerOwnWriteCaptureTests {
    private struct NoSourceApp: SourceAppPort {
        func frontmostApp() -> SourceApp? { SourceApp(bundleId: "com.example.editor", name: "Editor") }
        func localizedName(forBundleId bundleId: String) -> String? { nil }
    }

    private final class MemoryKV: KeyValueStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func string(forKey key: String) -> String? { lock.withLock { values[key] } }
        func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
        func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
    }

    /// Real `ClipboardCapture`, `IngestActor` and on-disk database over the harness's pasteboard and ledger.
    @MainActor private struct CaptureRig {
        let capture: ClipboardCapture
        let database: FlotsamDatabase
        let reporter: ErrorReporter
        let sink: RecordingSink
        let folder: URL

        init(harness h: ExpanderHarness) async throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-task424-\(UUID().uuidString)")
            database = try await FlotsamDatabase.open(folder: folder).get()
            let settings = SettingsStore(store: MemoryKV())
            sink = RecordingSink()
            reporter = ErrorReporter(presenter: h.presenter, clock: h.clock, sink: sink)
            capture = ClipboardCapture(
                pasteboard: h.pasteboard, sourceApps: NoSourceApp(), ownWrites: h.ledger,
                ingest: IngestActor(database: database, settings: settings), settings: settings,
                reporter: reporter, ignoredApps: { [] }, clock: h.clock, sink: sink,
                scheduleTimer: { _, _, _ in { } })
        }

        /// One poll, then waits until everything handed to ingest has been stored.
        func poll() async {
            capture.captureNow()
            await capture.stop()
            capture.start()
            for _ in 0..<8 {
                await Task.yield()
                _ = await reporter.recentErrors()
            }
        }

        func itemCount() async throws -> Int {
            try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") ?? -1 }
        }

        /// How many pasteboard changes capture has skipped as Flotsam's own writes (CAP-POL-004).
        func ownWriteSkips() -> Int {
            sink.allText.components(separatedBy: ErrorCode.capPol004.rawValue).count - 1
        }

        func finish() async {
            await capture.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func anExpansionAndItsClipboardRestoreCreateNoItem() async throws {
        // Given capture running over the user's own clipboard (already stored, so it is the baseline) / when a trigger
        // expands and capture polls during the restore wait (sees the item write) and after it (sees the restore
        // write) / then each write is skipped as Flotsam's own (CAP-POL-004) and the item count is unchanged.
        // The skip count is what catches the restore write: its text is the baseline item, so dedupe would hide it
        // from the item count. Red if either expansion write bypasses the ledger and markers.
        let h = ExpanderHarness()
        let rig = try await CaptureRig(harness: h)
        rig.capture.start()
        await rig.poll()
        let baseline = try await rig.itemCount()
        let skipsBefore = rig.ownWriteSkips()

        let capture = rig.capture
        // The clock sleeps off the main actor while the expander is suspended, so hop to the main queue to poll.
        h.clock.onSleep = { _ in
            let poll = { MainActor.assumeIsolated { capture.captureNow() } }
            if Thread.isMainThread { poll() } else { DispatchQueue.main.sync(execute: poll) }
        }
        let outcome = await h.expander.expand(h.match())
        h.clock.onSleep = nil
        await rig.poll()

        #expect(outcome == .expanded)
        #expect(h.pasteboard.writes.count == 2)
        #expect(rig.ownWriteSkips() - skipsBefore == 2)
        #expect(try await rig.itemCount() == baseline)
        await rig.finish()
    }

    @Test func anExpansionWhosePasteFailedLeavesTheItemOnTheClipboardAndCreatesNoItem() async throws {
        // The failed-paste path leaves the expansion's write on the pasteboard unrestored; capture must still skip it.
        let h = ExpanderHarness()
        h.keys.failPaste = true
        let rig = try await CaptureRig(harness: h)
        rig.capture.start()
        await rig.poll()
        let baseline = try await rig.itemCount()

        _ = await h.expander.expand(h.match())
        await rig.poll()

        #expect(h.pasteboard.writes.count == 1)
        #expect(h.pasteboard.plainText == "expanded text")
        #expect(try await rig.itemCount() == baseline)
        await rig.finish()
    }
}
