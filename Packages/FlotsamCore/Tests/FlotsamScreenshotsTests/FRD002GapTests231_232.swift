import FlotsamBase
import Foundation
import Testing
@testable import FlotsamScreenshots
@testable import FlotsamStorage

// TASK-231 and TASK-232 (OC-2069, FR-002-15, FR-000-10, AC-002-12): no screenshot filename and no folder name shows up
// in Notices, in log records or in the diagnostics report, for the two failures a screenshot can raise that carry a
// path in their context: SSP-IO-001 (the system folder is unusable) and SSP-LIM-001 (a file over 100 MiB).
//
// Real wiring: `RealIngestRig` (real watcher, real IngestActor, real database in a temp folder, real ErrorReporter).
// The markers are LITERALS; the expected side of every absence check carries no production symbol.
//
// UNTESTABLE-AT-PACKAGE: the real OSLog stream (`log show --predicate 'subsystem == ...'`), which needs the signed app
// and a unified-logging reader. Seam: `LogSink`. `ErrorReporter` and `FlotsamLog` hand every record to a `LogSink`
// before `OSLogSink` formats it, and `RealIngestRig.logRecords` is the recording sink, so `LogRecord.publicText` and
// `.privateText` are asserted instead (they are what `OSLogSink` writes, public and `.private` halves).

private let folderMarker = "fold-zq7marker"
private let nameMarker = "zq7marker"
private let secretMarker = "SECRETNAME-7f3"
private let sizeCeiling = 100 * 1024 * 1024

/// A small stand-in for the owners of the numbers (Capture, Shortcuts, Storage): none of them is the subject here.
private struct EmptyDiagnosticsSource: DiagnosticsDataSource {
    func permissionStates() async -> [PermissionName: PermissionState] { [:] }
    func itemCounts() async -> [ItemKind: Int] { [:] }
    func storageBytes() async -> (database: Int, blobs: Int) { (0, 0) }
}

/// One scenario's artefacts: where the markers could leak, and the file names that carry them.
private struct Leak231Scenario {
    let rig: RealIngestRig
    let uuid: String
    let fileName: String
    let markers: [String]

    /// Case-insensitive occurrences of every marker in `text`, as "marker: count" for the markers that appear.
    func leaks(in text: String) -> [String] {
        let haystack = text.lowercased()
        return markers.compactMap { marker in
            let count = haystack.components(separatedBy: marker.lowercased()).count - 1
            return count > 0 ? "\(marker) x\(count)" : nil
        }
    }

    var noticeText: String {
        rig.notices.map { "\(String(describing: $0)) \($0.message) \($0.code.rawValue)" }.joined(separator: "\n")
    }
    var logText: String {
        rig.logRecords.map { "\($0.publicText)\n\($0.privateText)" }.joined(separator: "\n")
    }
    func report() async -> String {
        let rig = rig
        return await DiagnosticsSnapshotBuilder(
            settings: rig.settings, source: EmptyDiagnosticsSource(), recentErrors: { await rig.recentErrors() }
        ).report()
    }

    /// Hides `fold-zq7marker`, the system screenshot location, so the watcher falls back to the Desktop (SSP-IO-001).
    /// The secret-named file sits inside that folder.
    func provokeUnusableSystemFolder() async throws {
        let folder = try rig.temp.folder(folderMarker)
        try rig.shot(in: folder, fileName)
        rig.preferences.set(location: folder.path)
        rig.fileSystem.hide(folder)
        await rig.watcher.start()
    }

    /// A secret-named screenshot on the Desktop, one byte over the 100 MiB image ceiling (SSP-LIM-001). Sparse: the
    /// size is set with `truncate`, so no 100 MiB is written to disk.
    func provokeOversizeScreenshot(born: Date) async throws {
        let url = try rig.shot(in: rig.desktop, fileName, born: born).url
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(sizeCeiling + 1))
        try handle.close()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == sizeCeiling + 1, "precondition: the file is one byte over the ceiling")
    }
}

private func makeScenario(watermark: Date? = nil) async throws -> Leak231Scenario {
    let uuid = UUID().uuidString
    return Leak231Scenario(
        rig: try await RealIngestRig.make(watermark: watermark), uuid: uuid,
        fileName: "Screenshot \(nameMarker)-\(secretMarker)-\(uuid).png",
        markers: [nameMarker, secretMarker, folderMarker, uuid])
}

@Suite("FRD-002 gap: no path in Notices, logs or the report (TASK-231/232)", .serialized)
struct NoPathLeakGapTests {
    @Test("TASK-231 TASK-232 OC-2069: SSP-IO-001 on a hidden fold-zq7marker names no folder or file in Notices or logs")
    func unusableSystemFolderLeaksNothing() async throws {
        // given the system screenshot folder is fold-zq7marker, holding a secret-named screenshot, and it vanishes
        let scenario = try await makeScenario()
        defer { scenario.rig.cleanUp() }
        // when the watcher starts and falls back to the Desktop
        try await scenario.provokeUnusableSystemFolder()
        // then the warning is live (so the absence checks can fail) ...
        #expect(await scenario.rig.watcher.status == .usingDesktop)
        #expect(scenario.rig.noticeCodes == [.sspIo001], "exactly one notice, SSP-IO-001")
        #expect(scenario.rig.logRecords.contains { $0.headline.hasPrefix("SSP-IO-001") }, "SSP-IO-001 reached the log sink")
        // ... and nothing the user could read or copy names the folder or the file
        #expect(scenario.leaks(in: scenario.noticeText) == [], "Notices text")
        #expect(scenario.leaks(in: scenario.logText) == [], "log publicText + privateText")
    }

    @Test("TASK-231 TASK-232 OC-2069: SSP-LIM-001 for a >100 MiB secret-named screenshot names no file or folder in Notices or logs")
    func oversizeScreenshotLeaksNothing() async throws {
        // given a watermark and a secret-named screenshot one byte over the 100 MiB ceiling, born after it
        let mark = Date().addingTimeInterval(-100)
        let scenario = try await makeScenario(watermark: mark)
        defer { scenario.rig.cleanUp() }
        try await scenario.provokeOversizeScreenshot(born: mark.addingTimeInterval(30))
        scenario.rig.clock.advance(by: 60)
        // when the watcher starts and reconciles
        await scenario.rig.watcher.start()
        // then SSP-LIM-001 is raised and logged, nothing was stored, and no marker appears anywhere
        #expect(await eventually { scenario.rig.noticeCodes.contains(.sspLim001) }, "SSP-LIM-001 notice raised")
        #expect(scenario.rig.noticeCodes == [.sspLim001], "exactly one notice")
        #expect(scenario.rig.logRecords.contains { $0.headline.hasPrefix("SSP-LIM-001") }, "SSP-LIM-001 reached the log sink")
        #expect(try await scenario.rig.itemCount() == 0, "an over-ceiling file is skipped, not stored")
        #expect(scenario.leaks(in: scenario.noticeText) == [], "Notices text")
        #expect(scenario.leaks(in: scenario.logText) == [], "log publicText + privateText")
    }

    @Test("TASK-231 TASK-232 OC-2069 FR-000-10: the diagnostics report lists SSP-IO-001 and SSP-LIM-001 and names no folder or file")
    func diagnosticsReportLeaksNothing() async throws {
        // given both failures were raised with the secret folder and file names in play
        let mark = Date().addingTimeInterval(-100)
        let scenario = try await makeScenario(watermark: mark)
        defer { scenario.rig.cleanUp() }
        try await scenario.provokeOversizeScreenshot(born: mark.addingTimeInterval(30))
        scenario.rig.clock.advance(by: 60)
        let folder = try scenario.rig.temp.folder(folderMarker)
        scenario.rig.preferences.set(location: folder.path)
        scenario.rig.fileSystem.hide(folder)
        await scenario.rig.watcher.start()
        #expect(await eventually { Set(scenario.rig.noticeCodes) == [.sspIo001, .sspLim001] }, "both notices raised")
        // when the report is built
        let report = await scenario.report()
        // then liveness: the Recent errors section holds both codes ...
        let recent = report.components(separatedBy: "Recent errors").last ?? ""
        #expect(recent.contains("SSP-IO-001"), "report lists SSP-IO-001")
        #expect(recent.contains("SSP-LIM-001"), "report lists SSP-LIM-001")
        #expect(recent.contains("(2, oldest first)"), "the section counts exactly the two raised errors")
        // ... and no marker appears in the report, the Notices or the logs
        #expect(scenario.leaks(in: report) == [], "diagnostics report")
        #expect(scenario.leaks(in: scenario.noticeText) == [], "Notices text")
        #expect(scenario.leaks(in: scenario.logText) == [], "log publicText + privateText")
    }

    @Test("TASK-231 TASK-232 OC-2069: control, the leak detector finds each marker when present and nothing in clean or empty text")
    func detectorControl() async throws {
        // given a scenario, and the detector run over text that does contain the markers
        let scenario = try await makeScenario()
        defer { scenario.rig.cleanUp() }
        let planted = "failed to read /Users/x/\(folderMarker)/Screenshot \(nameMarker)-\(secretMarker)-\(scenario.uuid).png"
        // then it reports each marker (the three required plus the file's uuid), so an empty result elsewhere means absence
        #expect(scenario.leaks(in: planted).count == 4)
        #expect(scenario.leaks(in: planted.uppercased()).count == 4, "case-insensitive")
        #expect(scenario.leaks(in: "SSP-LIM-001 error limit 100 MiB") == [])
        #expect(scenario.leaks(in: "") == [])
    }
}
