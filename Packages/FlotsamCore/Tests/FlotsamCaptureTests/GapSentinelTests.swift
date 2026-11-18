import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

/// TASK-121, TASK-122, TASK-032 (FR-000-10, FR-001-04, AC-000-03): clip content never reaches a log, a signpost, the
/// error buffer, the user-facing error text or the diagnostics report, on the stored path and on every rejected path.
private struct SentinelDataSource: DiagnosticsDataSource {
    let database: FlotsamDatabase
    func permissionStates() async -> [PermissionName: PermissionState] { [:] }
    func itemCounts() async -> [ItemKind: Int] {
        let count = (try? await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") }) ?? 0
        return [.text: count ?? 0]
    }
    func storageBytes() async -> (database: Int, blobs: Int) { (0, 0) }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct GapSentinelTests {
    /// OC-121-01 OC-122-01 OC-032-01. given one unique secret copied through every gate (stored, concealed, transient,
    /// auto-generated, own write, ignored app, paused, unhonoured type, vanished file, existing file named with the
    /// secret), when every log sink the app has is scanned, then the secret appears in none of them. Turns red if any
    /// capture path (a gate skip, a raised error, the stored log, the diagnostics report, the HUD or notices) puts
    /// clip text or a file name into a log record, the error ring buffer, a notice or the report. The scan is not
    /// vacuous: the same run proves the secret WAS captured into the database, that records exist for each path, and
    /// that the scanner flags a string that does contain it.
    @Test("OC-121-01 OC-122-01 OC-032-01 a unique secret copied through every path never appears in any log sink")
    func secretNeverReachesAnyLogSink() async throws {
        let secret = "SENTINEL-\(UUID().uuidString)-hunter2"
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()

        // given: three empty-bytes changes in a row, which suspends capture with the Warning CAP-PRM-001. This puts a
        // real entry in the error ring buffer, the notices and the diagnostics report, so those scans are not vacuous.
        for _ in 1...3 {
            rig.pasteboard.beginCopy()
            for _ in 1...3 { rig.capture.captureNow() }
        }
        // given: stored path
        rig.text(secret)
        rig.capture.captureNow()
        // given: gate 3, every never-store marker
        for marker in PasteboardMarkers.neverStore {
            rig.text(secret, markers: [marker])
            rig.capture.captureNow()
        }
        // given: gate 4 ignored app
        rig.ignored.value = [GapRig.frontmostBundle]
        rig.text("\(secret)-ignored")
        rig.capture.captureNow()
        rig.ignored.value = []
        // given: gate 2 own write
        _ = rig.ledger.write([PasteboardRepresentation(uti: GapRig.textType, data: Data("\(secret)-own".utf8))], to: rig.pasteboard)
        rig.capture.captureNow()
        // given: gate 1 paused
        rig.settings.set(.paused, for: SettingKeys.captureMode)
        rig.text("\(secret)-paused")
        rig.capture.captureNow()
        rig.settings.set(.active, for: SettingKeys.captureMode)
        // given: an unhonoured type carrying the secret as bytes (CAP-VAL-001)
        rig.pasteboard.copy(["com.example.opaque": Data("\(secret)-opaque".utf8)])
        rig.capture.captureNow()
        // given: a copied file that no longer exists, named with the secret (CAP-DAT-001)
        rig.pasteboard.copy(["public.file-url": Data("file:///nonexistent/\(secret)-gone.txt".utf8)])
        rig.capture.captureNow()
        // given: a copied file that exists, named with the secret
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(secret)-real.txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        rig.pasteboard.copy(["public.file-url": Data(file.absoluteString.utf8)])
        await rig.settle()

        // when: everything is read back
        let reporter = rig.reporter
        let sink = rig.sink
        // CAP-VAL-001 and CAP-DAT-001 are Info: logged, never in the ring buffer, so the sink is where they show.
        let raisedCodes = await eventually { sink.dump.contains("CAP-VAL-001") && sink.dump.contains("CAP-DAT-001") }
        let report = await DiagnosticsSnapshotBuilder(
            settings: rig.settings, source: SentinelDataSource(database: rig.database),
            recentErrors: { await reporter.recentErrors() }).report()
        let raised = await reporter.recentErrors()
        let ring = String(reflecting: raised)
        let sinkText = rig.sink.dump
        let shown = rig.presenter.shown
        let signpostNames = PerfInterval.allCases.map(\.rawValue).joined(separator: "\n")
        let rows = try await rig.freshRows()

        // then: positive controls, so the scan below cannot pass by looking at nothing
        #expect(raisedCodes, "the unhonoured type and the vanished file must each have logged their code")
        let headlines = rig.sink.records.map(\.headline).joined(separator: "|")
        for policy in ["CAP-POL-001", "CAP-POL-002", "CAP-POL-003", "CAP-POL-004"] {
            #expect(headlines.contains(policy) || rig.sink.dump.contains(policy), "no skip record for \(policy)")
        }
        #expect(rows.filter { $0.plainText == secret }.count == 1, "the secret copy must have been stored exactly once")
        #expect(rows.count == 2, "stored: the secret text and the existing file only, got \(rows.count)")
        #expect(raised.map(\.code) == [.capPrm001], "the ring buffer must hold the one Warning raised, got \(raised)")
        #expect(shown.contains("capPrm001"), "the notices must show the Warning: \(shown)")
        #expect(report.contains("CAP-PRM-001") && report.contains("Items"), "the report must list the Warning:\n\(report)")
        #expect(!rig.sink.records.isEmpty)

        // then: the secret appears in no sink
        let sinks: [(String, String)] = [
            ("log sink records", sinkText), ("error ring buffer", ring), ("HUD and notices", shown),
            ("diagnostics report", report), ("signpost names", signpostNames),
        ]
        for (name, text) in sinks {
            #expect(!text.contains("SENTINEL"), "\(name) leaked the secret: \(text.prefix(400))")
            #expect(!text.contains("hunter2"), "\(name) leaked the secret: \(text.prefix(400))")
        }
        // scanner control: a string that does contain the secret is flagged
        #expect("noise \(secret) noise".contains("SENTINEL"))
    }
}
