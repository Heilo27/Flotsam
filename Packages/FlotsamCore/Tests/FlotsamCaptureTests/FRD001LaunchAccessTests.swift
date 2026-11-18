import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamStorage
@testable import FlotsamCapture

@MainActor
private struct StubAccess: PasteboardAccessPort {
    let isReadAllowed: Bool
}

/// OC-1084 (FR-001-18 a): the launch check goes through `PasteboardAccessPort`, the seam for the system's
/// "Paste from Other Apps" setting.
@MainActor
@Suite("FRD-001 FR-001-18 a: launch access check")
struct FRD001LaunchAccessTests {

    private func run(allowed: Bool, _ body: (ErrorReporter, FRD001RecordingPresenter, RecordingSink, ContractPasteboard, ClipboardCapture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-frd001-access-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data")).get()
        let presenter = FRD001RecordingPresenter()
        let sink = RecordingSink()
        let clock = ManualClock()
        let reporter = ErrorReporter(presenter: presenter, clock: clock, sink: sink)
        let settings = SettingsStore(store: ContractKV())
        let pasteboard = ContractPasteboard()
        let capture = ClipboardCapture(
            pasteboard: pasteboard, sourceApps: ContractSourceApps(frontmost: ContractRig.writerApp), ownWrites: OwnWriteLedger(),
            ingest: IngestActor(database: database, settings: settings), settings: settings, reporter: reporter,
            ignoredApps: { [] }, access: StubAccess(isReadAllowed: allowed), clock: clock, sink: sink)
        capture.start()
        do { try await body(reporter, presenter, sink, pasteboard, capture) } catch {
            await capture.stop()
            throw error
        }
        await capture.stop()
    }

    private func settle(_ reporter: ErrorReporter) async {
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(30))
            _ = await reporter.recentErrors()
        }
    }

    @Test("OC-1084: access other than Allow at launch raises CAP-PRM-001 and shows the warning")
    func blockedAtLaunch() async throws {
        try await run(allowed: false) { reporter, presenter, sink, _, _ in
            await settle(reporter)
            #expect(presenter.latestNotices.map(\.code) == [.capPrm001])
            #expect(sink.logged(.capPrm001).count == 1)
        }
    }

    @Test("OC-1084 boundary: access Allow at launch raises nothing")
    func allowedAtLaunch() async throws {
        try await run(allowed: true) { reporter, presenter, sink, _, _ in
            await settle(reporter)
            #expect(presenter.latestNotices.isEmpty)
            #expect(sink.logged(.capPrm001).isEmpty)
        }
    }

    @Test("OC-1084 recovery: after a blocked launch, the first readable copy stores and clears the warning")
    func blockedAtLaunchThenReadable() async throws {
        try await run(allowed: false) { reporter, presenter, _, pasteboard, capture in
            await settle(reporter)
            #expect(presenter.latestNotices.map(\.code) == [.capPrm001])
            pasteboard.copyText(uid("R"))
            capture.captureNow()
            for _ in 0..<100 where !presenter.latestNotices.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            #expect(presenter.latestNotices.isEmpty, "the warning clears on the first successful read")
        }
    }
}
