import Foundation
import Testing
@testable import FlotsamBase

// FRD-000 mutation survivors (TASK-377): error-code parsing, FlotsamError equality, registry-key shape and the
// build/system strings in DiagnosticsEnvironment. Expected values are literals only.

private func baseError() -> FlotsamError {
    FlotsamError(
        .capOs001, "base",
        context: [.count: .int(3)],
        underlying: UnderlyingErrorInfo(domain: "NSCocoaErrorDomain", code: 640)
    )
}

@Suite(.timeLimit(.minutes(1))) struct ErrorCodeParseSurvivorTests {
    /// OC-0005 negative (kills X155). given a well-formed code with one extra empty segment (leading, trailing,
    /// doubled), when parsed, then it is rejected; the clean form still parses with the right parts.
    @Test("OC-0005 codes with an extra empty segment are rejected, not collapsed")
    func emptySegmentsRejected() {
        for bad in ["SYS-IO-001-", "-SYS-IO-001", "SYS--IO-001", "SYS-IO--001", "SYS-IO-001--", "--SYS-IO-001"] {
            #expect(ErrorCodeParts.parse(bad) == nil, "\(bad) must not parse")
        }
        let clean = ErrorCodeParts.parse("SYS-IO-001")
        #expect(clean?.module == .sys)
        #expect(clean?.category == .io)
        #expect(clean?.number == 1)
    }

    /// OC-0005 negative (kills X166). given a three-character number part that Int() would accept but that is not
    /// three digits (sign prefix), when parsed, then it is rejected.
    @Test("OC-0005 a signed number part is not three digits")
    func signedNumberRejected() {
        for bad in ["SYS-IO-+12", "SYS-IO-+01", "SYS-IO-+99"] {
            #expect(ErrorCodeParts.parse(bad) == nil, "\(bad) must not parse")
        }
        #expect(ErrorCodeParts.parse("SYS-IO-012")?.number == 12)
    }
}

@Suite(.timeLimit(.minutes(1))) struct FlotsamErrorEqualitySurvivorTests {
    /// OC-0004 (kills X223, X224, X225). given two errors that differ only in the static message, when compared,
    /// then they are equal.
    @Test("OC-0004 errors with the same code, context and cause are equal whatever the message")
    func sameFailureIsEqual() {
        let twin = FlotsamError(
            .capOs001, "another wording",
            context: [.count: .int(3)],
            underlying: UnderlyingErrorInfo(domain: "NSCocoaErrorDomain", code: 640)
        )
        #expect(baseError() == twin)
        #expect(!(baseError() != twin))
    }

    /// OC-0004 (kills X226, X227). given two errors that differ only in code, when compared, then they differ.
    @Test("OC-0004 a different code alone makes errors unequal")
    func codeAloneDiffers() {
        let other = FlotsamError(
            .stoDb001, "base",
            context: [.count: .int(3)],
            underlying: UnderlyingErrorInfo(domain: "NSCocoaErrorDomain", code: 640)
        )
        #expect(baseError() != other)
        #expect(other != baseError())
    }

    /// OC-0004 (kills X224, X227). given two errors that differ only in context (value, key, or presence), when
    /// compared, then they differ.
    @Test("OC-0004 a different context alone makes errors unequal")
    func contextAloneDiffers() {
        let underlying = UnderlyingErrorInfo(domain: "NSCocoaErrorDomain", code: 640)
        let variants: [[LogKey: LogSafeValue]] = [
            [.count: .int(4)],
            [.rows: .int(3)],
            [:],
            [.count: .int(3), .rows: .int(1)],
        ]
        for context in variants {
            let other = FlotsamError(.capOs001, "base", context: context, underlying: underlying)
            #expect(baseError() != other, "\(context)")
        }
    }

    /// OC-0004 (kills X225, X227). given two errors that differ only in the underlying cause (domain, code, or
    /// present vs absent), when compared, then they differ.
    @Test("OC-0004 a different underlying cause alone makes errors unequal")
    func underlyingAloneDiffers() {
        let variants: [UnderlyingErrorInfo?] = [
            UnderlyingErrorInfo(domain: "NSPOSIXErrorDomain", code: 640),
            UnderlyingErrorInfo(domain: "NSCocoaErrorDomain", code: 641),
            nil,
        ]
        for underlying in variants {
            let other = FlotsamError(.capOs001, "base", context: [.count: .int(3)], underlying: underlying)
            #expect(baseError() != other, "\(String(describing: underlying))")
        }
        let noCauseA = FlotsamError(.capOs001, "a")
        let noCauseB = FlotsamError(.capOs001, "b")
        #expect(noCauseA == noCauseB)
        #expect(noCauseA != baseError())
    }
}

@Suite(.timeLimit(.minutes(1))) struct RegistryKeySurvivorTests {
    /// OC-0046 (kills X142). given keys with an empty segment between, before or after real segments, when the shape
    /// is checked, then each is rejected; real two-part keys pass.
    @Test("OC-0046 registry keys with empty parts are rejected")
    func emptyPartsRejected() {
        for bad in ["a..b", ".a.b", "a.b.", "..a", "a.."] {
            #expect(!DiagnosticsSnapshotBuilder.isRegistryKey(bad), "\(bad)")
        }
        for good in ["a.b", "ok.Key1", "capture.pauseOnSecure"] {
            #expect(DiagnosticsSnapshotBuilder.isRegistryKey(good), "\(good)")
        }
    }

    /// OC-0046 end to end (kills X142). given a toggle key `a..b`, when the report is built, then the key is dropped
    /// from the snapshot and the report text.
    @Test("OC-0046 a double-dot toggle key never reaches the report")
    func doubleDotKeyDropped() async {
        let builder = DiagnosticsSnapshotBuilder(
            environment: DiagnosticsEnvironment(appVersion: "1", build: "1", macOSVersion: "m", cpuArchitecture: "c"),
            settings: SettingsStore(store: MemoryKeyValueStore()),
            source: FakeDataSource(),
            toggles: { ["a..b": true, "ok.Key1": false] },
            recentErrors: { [] }
        )
        let snapshot = await builder.build()
        #expect(snapshot.toggles == ["ok.Key1": false])
        let report = DiagnosticsReport.render(snapshot)
        #expect(!report.contains("a..b"))
        #expect(report.contains("  ok.Key1: off\n"))
    }
}

/// Serialized: these tests mutate the process-wide `Bundle.main.infoDictionary` (an NSMutableDictionary) and must not
/// overlap each other.
@Suite(.serialized, .timeLimit(.minutes(1))) struct DiagnosticsEnvironmentSurvivorTests {
    private static let versionKey = "CFBundleShortVersionString"
    private static let buildKey = "CFBundleVersion"

    private static func mainInfo() -> NSMutableDictionary? {
        Bundle.main.perform(NSSelectorFromString("infoDictionary"))?.takeUnretainedValue() as? NSMutableDictionary
    }

    /// OC-0076 (kills X101, X103). given the main bundle declares a short version and a build number, when the
    /// environment is read, then it reports exactly those values from those Info.plist keys.
    @Test("OC-0076 the environment reports the bundle's short version and build")
    func readsVersionAndBuildFromBundle() throws {
        let info = try #require(Self.mainInfo(), "main bundle info dictionary must be mutable in the test host")
        let savedVersion = info[Self.versionKey]
        let savedBuild = info[Self.buildKey]
        defer {
            if let savedVersion { info[Self.versionKey] = savedVersion } else { info.removeObject(forKey: Self.versionKey) }
            if let savedBuild { info[Self.buildKey] = savedBuild } else { info.removeObject(forKey: Self.buildKey) }
        }
        info[Self.versionKey] = "9.9.9"
        info[Self.buildKey] = "77"
        let env = DiagnosticsEnvironment.current
        #expect(env.appVersion == "9.9.9")
        #expect(env.build == "77")
    }

    /// OC-0076 negative (kills X102, X104). given the main bundle declares neither key, when the environment is read,
    /// then both fields are exactly "unknown".
    @Test("OC-0076 missing version and build keys report unknown")
    func missingKeysReportUnknown() throws {
        let info = try #require(Self.mainInfo(), "main bundle info dictionary must be mutable in the test host")
        let savedVersion = info[Self.versionKey]
        let savedBuild = info[Self.buildKey]
        defer {
            if let savedVersion { info[Self.versionKey] = savedVersion }
            if let savedBuild { info[Self.buildKey] = savedBuild }
        }
        info.removeObject(forKey: Self.versionKey)
        info.removeObject(forKey: Self.buildKey)
        let env = DiagnosticsEnvironment.current
        #expect(env.appVersion == "unknown")
        #expect(env.build == "unknown")
    }

    /// OC-0076 (kills X098). given a build for this CPU, when the environment is read, then the architecture is the
    /// bare name with no decoration.
    @Test("OC-0076 the environment reports the bare CPU architecture name")
    func architectureIsBareName() {
        #if arch(arm64)
        #expect(DiagnosticsEnvironment.current.cpuArchitecture == "arm64")
        #elseif arch(x86_64)
        #expect(DiagnosticsEnvironment.current.cpuArchitecture == "x86_64")
        #else
        #expect(DiagnosticsEnvironment.current.cpuArchitecture == "unknown")
        #endif
    }
}
