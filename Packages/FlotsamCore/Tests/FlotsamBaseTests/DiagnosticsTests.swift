import Foundation
import Testing
@testable import FlotsamBase

// FRD-000 FR-000-14 diagnostics report. The report is observed as the finished string and as what lands on the
// pasteboard port; expected values are literals.

private let environment = DiagnosticsEnvironment(appVersion: "1.2.3", build: "45", macOSVersion: "Version 15.1 (Build 24B83)", cpuArchitecture: "arm64")

private func builder(
    source: any DiagnosticsDataSource = FakeDataSource(),
    toggles: @escaping @Sendable () -> [String: Bool] = { [:] },
    errors: [RaisedError] = []
) -> DiagnosticsSnapshotBuilder {
    DiagnosticsSnapshotBuilder(
        environment: environment,
        settings: SettingsStore(store: MemoryKeyValueStore()),
        source: source,
        toggles: toggles,
        recentErrors: { errors }
    )
}

/// Reference-typed source so a test can change state between two reports.
private final class MutableSource: DiagnosticsDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var permissions: [PermissionName: PermissionState] = [:]
    private var counts: [ItemKind: Int] = [:]

    func set(permission: PermissionName, _ state: PermissionState) { lock.withLock { permissions[permission] = state } }
    func set(count: Int, for kind: ItemKind) { lock.withLock { counts[kind] = count } }
    func permissionStates() async -> [PermissionName: PermissionState] { lock.withLock { permissions } }
    func itemCounts() async -> [ItemKind: Int] { lock.withLock { counts } }
    func storageBytes() async -> (database: Int, blobs: Int) { (0, 0) }
}

@Suite struct DiagnosticsTests {
    // MARK: OC-0045

    /// OC-0045. given items of several kinds, 30 day retention, 2 GB budget, fixed permissions, toggles, sizes and two
    /// ring entries, when the report is built, then it equals this text exactly: version and build, macOS, CPU, the
    /// four permission states, presets, toggles, per-kind counts, both byte sizes, ring oldest first.
    @Test("OC-0045 report equals the FR-000-14 text exactly")
    func fullReport() async {
        let source = FakeDataSource(
            permissions: [.accessibility: .granted, .inputMonitoring: .denied, .pasteboard: .granted],
            counts: [.text: 7, .link: 2, .image: 1],
            bytes: (database: 4096, blobs: 1_048_576)
        )
        let errors = [
            RaisedError(code: .capOs001, severity: .warning, timestamp: Date(timeIntervalSince1970: 1_800_000_000)),
            RaisedError(code: .stoDb001, severity: .error, timestamp: Date(timeIntervalSince1970: 1_800_000_061)),
        ]
        let report = await builder(source: source, toggles: { ["general.launchAtLogin": true, "capture.pauseOnSecure": false] }, errors: errors).report()
        let expected = """
        Flotsam diagnostics

        App: 1.2.3 (45)
        macOS: Version 15.1 (Build 24B83)
        CPU: arm64

        Permissions
          accessibility: granted
          inputMonitoring: denied
          screenshotFolder: notDetermined
          pasteboard: granted

        Settings
          retention: d30
          imageBudget: gib2
          capture.pauseOnSecure: off
          general.launchAtLogin: on

        Items
          text: 7
          richText: 0
          link: 2
          color: 0
          phone: 0
          email: 0
          image: 1
          file: 0
          folder: 0
          bundle: 0
          screenshot: 0

        Storage
          database bytes: 4096
          blob bytes: 1048576

        Recent errors (2, oldest first)
          2027-01-15T08:00:00Z warning CAP-OS-001
          2027-01-15T08:01:01Z error STO-DB-001

        """
        #expect(report == expected)
    }

    /// OC-0045 settings. given the user changed retention to 1 year and the budget to unlimited, then the report shows them.
    @Test("OC-0045 report shows changed retention and budget presets")
    func changedPresets() async {
        let store = MemoryKeyValueStore()
        let settings = SettingsStore(store: store)
        settings.set(RetentionPreset.y1, for: SettingKeys.storageRetention)
        settings.set(ImageBudget.unlimited, for: SettingKeys.storageImageBudget)
        let report = await DiagnosticsSnapshotBuilder(environment: environment, settings: settings, source: FakeDataSource(), recentErrors: { [] }).report()
        #expect(report.contains("  retention: y1\n"))
        #expect(report.contains("  imageBudget: unlimited\n"))
        #expect(!report.contains("retention: d30"))
    }

    // MARK: OC-0046

    /// OC-0046. given toggle keys shaped like user text, when the report is built, then those keys are dropped and no
    /// marker text appears; a registry-shaped key stays.
    @Test("OC-0046 non-registry toggle keys never reach the report")
    func nonRegistryTogglesDropped() async {
        let hostile: [String: Bool] = [
            "MARK-IGN.app": true, "a.b.c": true, "com.example.MARK-IGN": true, "has space.x": true,
            "": true, ".x": true, "x.": true, "ok.Key1": true,
        ]
        let report = await builder(toggles: { hostile }).report()
        #expect(!report.contains("MARK-IGN"))
        #expect(!report.contains("a.b.c"))
        #expect(!report.contains("has space"))
        #expect(report.contains("  ok.Key1: on\n"))
        let toggleLines = report.split(separator: "\n").filter { $0.hasSuffix(": on") && $0.contains(".") }
        #expect(toggleLines.count == 1)
    }

    // MARK: Clamping

    /// given negative counts and sizes from a faulty source, then the report shows 0, never a negative number.
    @Test("report clamps negative counts and byte sizes to zero")
    func clampsNegatives() async {
        let source = FakeDataSource(counts: [.text: -5, .image: 3], bytes: (database: -1, blobs: -2048))
        let report = await builder(source: source).report()
        #expect(report.contains("  text: 0\n"))
        #expect(report.contains("  image: 3\n"))
        #expect(report.contains("  database bytes: 0\n"))
        #expect(report.contains("  blob bytes: 0\n"))
        #expect(!report.contains("-"), "no negative number anywhere (the only hyphen-free report)")
    }

    // MARK: OC-0047

    /// OC-0047. given a report, when it is copied, then the pasteboard gets the plain text plus the marker types, one
    /// write (changeCount delta 1), and the returned count matches.
    @MainActor
    @Test("OC-0047 copy writes the text and the self-write marker types in one write")
    func copyWritesTextAndMarkers() throws {
        let pasteboard = FakePasteboard()
        let copier = DiagnosticsCopier(pasteboard: pasteboard, ownWriteTypes: ["com.flotsamtest.own-write", "com.flotsamtest.own-write-2"])
        let before = pasteboard.changeCount
        let result = copier.copy("Flotsam diagnostics\n")
        #expect(try result.get() == 1)
        #expect(pasteboard.changeCount - before == 1)
        #expect(pasteboard.written.count == 1)
        let written = try #require(pasteboard.written.first)
        #expect(written.map(\.uti) == ["public.utf8-plain-text", "com.flotsamtest.own-write", "com.flotsamtest.own-write-2"])
        #expect(String(decoding: written[0].data, as: UTF8.self) == "Flotsam diagnostics\n")
        #expect(written[1].data.isEmpty)
    }

    /// OC-0047 negative. given the pasteboard write fails, then the failure is returned and nothing is on the pasteboard.
    @MainActor
    @Test("OC-0047 a failed write returns the error and leaves the pasteboard untouched")
    func copyFailureWritesNothing() {
        let pasteboard = FakePasteboard()
        pasteboard.failWith = FlotsamError(.capOs001, "test")
        let copier = DiagnosticsCopier(pasteboard: pasteboard, ownWriteTypes: ["com.flotsamtest.own-write"])
        let result = copier.copy("x")
        #expect(throws: FlotsamError.self) { try result.get() }
        #expect(pasteboard.changeCount == 0)
        #expect(pasteboard.written.isEmpty)
    }

    // MARK: OC-0068, OC-0043 (report side)

    /// OC-0068. given an empty ring, then the report's recent-errors section reads zero and lists no entries.
    @Test("OC-0068 empty ring renders 'Recent errors (0, oldest first)' with no entry lines")
    func emptyRingSection() async {
        let report = await builder().report()
        #expect(report.hasSuffix("Recent errors (0, oldest first)\n"))
    }

    /// OC-0043 (report). given the last 100 of 105 raises, when the report is built, then 100 lines list, the 6th raise
    /// (timestamp 1_800_000_305 = 2027-01-15T08:05:05Z) is first and the 5th (08:04:04Z) is absent.
    @Test("OC-0043 report lists 100 ring entries, E6 first, E5 absent")
    func reportShowsHundredEntries() async {
        let errors = (5..<105).map { RaisedError(code: .stoDb001, severity: .error, timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 61)) }
        let report = await builder(errors: errors).report()
        let lines = report.components(separatedBy: "Recent errors (100, oldest first)\n").last?.split(separator: "\n") ?? []
        #expect(lines.count == 100)
        #expect(lines.first == "  2027-01-15T08:05:05Z error STO-DB-001")
        #expect(!report.contains("2027-01-15T08:04:04Z"))
    }

    // MARK: OC-0076

    /// OC-0076. given a report R1, when the state changes (text count +1, Accessibility revoked), then a second report
    /// from the same builder reflects it: built from current state, not cached.
    @Test("OC-0076 a second report reflects current counts and permissions")
    func reportNotCached() async {
        let source = MutableSource()
        source.set(permission: .accessibility, .granted)
        source.set(count: 4, for: .text)
        source.set(count: 2, for: .link)
        let reporter = builder(source: source)

        let first = await reporter.report()
        #expect(first.contains("  accessibility: granted\n"))
        #expect(first.contains("  text: 4\n"))

        source.set(count: 5, for: .text)
        source.set(permission: .accessibility, .denied)
        let second = await reporter.report()
        #expect(second.contains("  accessibility: denied\n"))
        #expect(second.contains("  text: 5\n"))
        #expect(second.contains("  link: 2\n"), "other kinds unchanged")
        #expect(second != first)
    }
}
