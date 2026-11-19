import Foundation

/// How one launch is wired to the real machine (TASK-519). The one home of three decisions that otherwise reach the
/// user's real data: where the data folder is, which defaults domain holds the settings, and whether secure items use
/// the real Keychain and LocalAuthentication. `real` is every shipped launch. A Debug build can read overrides from the
/// environment so an agent can start an isolated instance (docs/AGENT-LAUNCH.md).
///
/// Release builds compile none of the override code: the variable names, the parser and the in-memory fakes all sit
/// behind `#if DEBUG`, and `fromProcess()` answers `real` there without reading the environment.
public struct LaunchIsolation: Equatable, Sendable {
    /// What the fake authenticator answers when `fakeSecure` is on.
    public enum AuthScript: Equatable, Sendable {
        case allow
        case deny
    }

    /// Replaces the data folder when set; nil means `~/Library/Application Support/Flotsam`.
    public let dataFolderOverride: URL?
    /// A separate defaults domain for every setting and onboarding key; nil means the app's own (standard) domain.
    public let defaultsSuite: String?
    /// True: secure items use an in-memory key and a scripted authenticator, so no Keychain or LocalAuthentication
    /// call is made.
    public let fakeSecure: Bool
    public let authScript: AuthScript

    public init(dataFolderOverride: URL?, defaultsSuite: String?, fakeSecure: Bool, authScript: AuthScript) {
        self.dataFolderOverride = dataFolderOverride
        self.defaultsSuite = defaultsSuite
        self.fakeSecure = fakeSecure
        self.authScript = authScript
    }

    /// Nothing overridden: the user's real folder, defaults and Keychain. The only value a Release build ever has.
    public static let real = LaunchIsolation(dataFolderOverride: nil, defaultsSuite: nil, fakeSecure: false, authScript: .allow)

    /// The folder the database opens in, and what the Fatal alert reveals (FR-007-01). The one place the Application
    /// Support location is spelled.
    public var dataFolder: URL { dataFolderOverride ?? Self.realDataFolder }

    /// `~/Library/Application Support/Flotsam`: where the user's real data lives.
    public static var realDataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flotsam", isDirectory: true)
    }
}

/// A launch override that cannot be honoured is a `SYS-INT-001` whose message names the variable. The launch refuses
/// to start rather than fall back to the real data: a typo in an isolation variable must never turn an isolated launch
/// into one that touches the user's files.
extension LaunchIsolation {
    /// The isolation for this process: environment overrides in a Debug build, `real` in a Release build.
    public static func fromProcess() -> FlotsamResult<LaunchIsolation> {
        #if DEBUG
        return resolve(environment: ProcessInfo.processInfo.environment, isDebugBuild: true)
        #else
        return .success(.real)
        #endif
    }
}

#if DEBUG
extension LaunchIsolation {
    public static let dataDirVariable = "FLOTSAM_DATA_DIR"
    public static let defaultsSuiteVariable = "FLOTSAM_DEFAULTS_SUITE"
    public static let fakeSecureVariable = "FLOTSAM_FAKE_SECURE"
    public static let fakeAuthVariable = "FLOTSAM_FAKE_AUTH"

    /// Pure: reads `environment` and nothing else. `isDebugBuild: false` is the Release rule written as a value: every
    /// variable is ignored (the real Release build never reaches this function at all).
    ///
    /// - `FLOTSAM_DATA_DIR`: an absolute path, used as the data folder itself. It may not be the real folder.
    /// - `FLOTSAM_DEFAULTS_SUITE`: a non-empty defaults domain name.
    /// - `FLOTSAM_FAKE_SECURE`: `1` turns the fakes on; `0` or unset leaves them off.
    /// - `FLOTSAM_FAKE_AUTH`: `allow` (default) or `deny`; only meaningful with `FLOTSAM_FAKE_SECURE=1`.
    ///
    /// A variable that is set but unusable is an error, never a fallback to the real thing.
    public static func resolve(
        environment: [String: String], isDebugBuild: Bool
    ) -> FlotsamResult<LaunchIsolation> {
        guard isDebugBuild else { return .success(.real) }

        var folder: URL?
        if let raw = environment[dataDirVariable] {
            guard raw.hasPrefix("/") else {
                return .failure(FlotsamError(.sysInt001, "FLOTSAM_DATA_DIR must be an absolute path"))
            }
            let url = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
            let real = realDataFolder.standardizedFileURL.resolvingSymlinksInPath()
            guard url.resolvingSymlinksInPath().path != real.path else {
                return .failure(FlotsamError(.sysInt001, "FLOTSAM_DATA_DIR is the real data folder"))
            }
            folder = url
        }

        var suite: String?
        if let raw = environment[defaultsSuiteVariable] {
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(FlotsamError(.sysInt001, "FLOTSAM_DEFAULTS_SUITE must not be empty"))
            }
            suite = raw
        }

        var fakeSecure = false
        switch environment[fakeSecureVariable] {
        case nil, "0": break
        case "1": fakeSecure = true
        case .some:
            return .failure(FlotsamError(.sysInt001, "FLOTSAM_FAKE_SECURE must be 1 or 0"))
        }

        var script = AuthScript.allow
        switch environment[fakeAuthVariable] {
        case nil, "allow": break
        case "deny": script = .deny
        case .some:
            return .failure(FlotsamError(.sysInt001, "FLOTSAM_FAKE_AUTH must be allow or deny"))
        }

        return .success(LaunchIsolation(
            dataFolderOverride: folder, defaultsSuite: suite, fakeSecure: fakeSecure, authScript: script))
    }
}
#endif
