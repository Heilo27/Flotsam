import Foundation
import Testing
@testable import FlotsamBase

// TASK-519: DEBUG-only launch isolation. The resolution is a pure function of an environment dictionary; these pin every
// combination, the Release rule, the fakes, and (by source scan) that no UserDefaults, data-folder or secure-store use
// bypasses the one resolution home.

private func repoRoot() -> URL? {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) { return url }
        url.deleteLastPathComponent()
    }
    return nil
}

/// Every `.swift` file under `relativePath` as (path relative to the repo root, text).
private func swiftSources(under relativePath: String) -> [(path: String, text: String)] {
    guard let root = repoRoot() else { return [] }
    var found: [(String, String)] = []
    let files = FileManager.default.enumerator(at: root.appendingPathComponent(relativePath), includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
        guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        found.append((String(url.path.dropFirst(root.path.count + 1)), text))
    }
    return found
}

/// Source with `//` comments removed, so a rule named in prose is not a use.
private func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let range = line.range(of: "//") else { return line }
        return line[..<range.lowerBound]
    }.joined(separator: "\n")
}

/// Source with every `#if DEBUG ... #endif` region (nesting-aware) removed: what a Release build compiles.
private func releaseText(_ text: String) -> String {
    var kept: [String] = []
    var depth = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if depth > 0 {
            if trimmed.hasPrefix("#if") { depth += 1 } else if trimmed.hasPrefix("#endif") { depth -= 1 }
            continue
        }
        if trimmed == "#if DEBUG" { depth = 1; continue }
        kept.append(String(line))
    }
    return kept.joined(separator: "\n")
}

private func resolved(_ environment: [String: String], debug: Bool = true) -> LaunchIsolation? {
    if case .success(let value) = LaunchIsolation.resolve(environment: environment, isDebugBuild: debug) { return value }
    return nil
}

/// The refusal's message, which names the variable.
private func refusal(_ environment: [String: String]) -> String? {
    failure(environment).map { "\($0.internalMessage)" }
}

private func failure(_ environment: [String: String]) -> FlotsamError? {
    if case .failure(let error) = LaunchIsolation.resolve(environment: environment, isDebugBuild: true) { return error }
    return nil
}

@Suite("TASK-519 launch isolation resolution")
struct LaunchIsolationResolutionTests {
    @Test("no variables: the real launch, unchanged")
    func noVariables() {
        #expect(resolved([:]) == .real)
        #expect(LaunchIsolation.real.dataFolderOverride == nil)
        #expect(LaunchIsolation.real.defaultsSuite == nil)
        #expect(!LaunchIsolation.real.fakeSecure)
        #expect(LaunchIsolation.real.dataFolder == LaunchIsolation.realDataFolder)
        #expect(LaunchIsolation.realDataFolder.path.hasSuffix("/Library/Application Support/Flotsam"))
        // Unrelated variables are not read.
        #expect(resolved(["HOME": "/x", "PATH": "/bin"]) == .real)
    }

    @Test("each variable alone sets only its own field")
    func eachAlone() {
        let dir = resolved(["FLOTSAM_DATA_DIR": "/tmp/flotsam-519-a"])
        #expect(dir?.dataFolder.path == "/tmp/flotsam-519-a" || dir?.dataFolder.path == "/private/tmp/flotsam-519-a")
        #expect(dir?.defaultsSuite == nil)
        #expect(dir?.fakeSecure == false)

        let suite = resolved(["FLOTSAM_DEFAULTS_SUITE": "io.example.agent"])
        #expect(suite?.defaultsSuite == "io.example.agent")
        #expect(suite?.dataFolderOverride == nil)
        #expect(suite?.fakeSecure == false)

        let secure = resolved(["FLOTSAM_FAKE_SECURE": "1"])
        #expect(secure?.fakeSecure == true)
        #expect(secure?.authScript == .allow)
        #expect(secure?.dataFolderOverride == nil)
        #expect(secure?.defaultsSuite == nil)
    }

    @Test("all three together, and the auth script")
    func allTogether() {
        let env = ["FLOTSAM_DATA_DIR": "/tmp/flotsam-519-b", "FLOTSAM_DEFAULTS_SUITE": "io.example.agent", "FLOTSAM_FAKE_SECURE": "1"]
        let allow = resolved(env)
        #expect(allow?.fakeSecure == true && allow?.defaultsSuite == "io.example.agent" && allow?.dataFolderOverride != nil)
        #expect(allow?.authScript == .allow)
        #expect(resolved(env.merging(["FLOTSAM_FAKE_AUTH": "allow"]) { $1 })?.authScript == .allow)
        #expect(resolved(env.merging(["FLOTSAM_FAKE_AUTH": "deny"]) { $1 })?.authScript == .deny)
    }

    @Test("FLOTSAM_FAKE_SECURE=0 is off")
    func fakeSecureZero() {
        #expect(resolved(["FLOTSAM_FAKE_SECURE": "0"])?.fakeSecure == false)
    }

    @Test("a Release build ignores every variable")
    func releaseIgnores() {
        let all = [
            "FLOTSAM_DATA_DIR": "/tmp/flotsam-519-c", "FLOTSAM_DEFAULTS_SUITE": "io.example.agent",
            "FLOTSAM_FAKE_SECURE": "1", "FLOTSAM_FAKE_AUTH": "deny",
        ]
        #expect(resolved(all, debug: false) == .real)
        // Even values that would be errors in Debug are not read.
        #expect(resolved(["FLOTSAM_DATA_DIR": "relative", "FLOTSAM_FAKE_SECURE": "yes"], debug: false) == .real)
    }

    @Test("a set but unusable variable refuses the launch instead of falling back to the real data")
    func unusableRefuses() {
        #expect(refusal(["FLOTSAM_DATA_DIR": "relative/dir"])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
        #expect(refusal(["FLOTSAM_DATA_DIR": ""])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
        #expect(refusal(["FLOTSAM_DATA_DIR": "~/x"])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
        #expect(refusal(["FLOTSAM_DEFAULTS_SUITE": ""])?.hasPrefix("FLOTSAM_DEFAULTS_SUITE") == true)
        #expect(refusal(["FLOTSAM_DEFAULTS_SUITE": "   "])?.hasPrefix("FLOTSAM_DEFAULTS_SUITE") == true)
        #expect(refusal(["FLOTSAM_FAKE_SECURE": "yes"])?.hasPrefix("FLOTSAM_FAKE_SECURE") == true)
        #expect(refusal(["FLOTSAM_FAKE_SECURE": ""])?.hasPrefix("FLOTSAM_FAKE_SECURE") == true)
        #expect(refusal(["FLOTSAM_FAKE_AUTH": "maybe"])?.hasPrefix("FLOTSAM_FAKE_AUTH") == true)
    }

    @Test("the real data folder is not an acceptable override, however it is spelled")
    func realFolderRefused() {
        let real = LaunchIsolation.realDataFolder.path
        #expect(refusal(["FLOTSAM_DATA_DIR": real])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
        #expect(refusal(["FLOTSAM_DATA_DIR": real + "/"])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
        #expect(refusal(["FLOTSAM_DATA_DIR": real + "/../Flotsam"])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
        // A sibling is a different folder; a folder inside the real one is not acceptable (QA, Worf).
        #expect(resolved(["FLOTSAM_DATA_DIR": real + "-519"]) != nil)
        #expect(refusal(["FLOTSAM_DATA_DIR": real + "/child"])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
        #expect(refusal(["FLOTSAM_DATA_DIR": real + "/blobs/x/"])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
    }

    @Test("a symlink to the real folder, and a symlink's parent that is the real folder, are refused")
    func symlinkedRealFolderRefused() throws {
        // Given a throwaway folder holding a link to the real folder and a link to a folder inside it.
        let real = LaunchIsolation.realDataFolder
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("task519-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let link = scratch.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        // When the link, the link with a trailing slash and a path through it are given
        // Then each names the real folder and is refused.
        #expect(refusal(["FLOTSAM_DATA_DIR": link.path])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
        #expect(refusal(["FLOTSAM_DATA_DIR": link.path + "/"])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
        #expect(refusal(["FLOTSAM_DATA_DIR": link.path + "/blobs"])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
    }

    @Test("a different-case spelling of the real folder is refused")
    func caseVariantRealFolderRefused() {
        let real = LaunchIsolation.realDataFolder.path
        #expect(refusal(["FLOTSAM_DATA_DIR": real.lowercased()])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
        #expect(refusal(["FLOTSAM_DATA_DIR": real.uppercased()])?.hasPrefix("FLOTSAM_DATA_DIR") == true)
    }

    @Test("a defaults suite that names the app's own domain is refused: exact, other case, or as a file path")
    func ownDomainSuiteRefused() {
        let own = "io.example.Own"
        func suite(_ name: String) -> String? {
            if case .failure(let error) = LaunchIsolation.resolve(
                environment: ["FLOTSAM_DEFAULTS_SUITE": name], isDebugBuild: true, appDomain: own) { return "\(error.internalMessage)" }
            return nil
        }
        #expect(suite(own)?.hasPrefix("FLOTSAM_DEFAULTS_SUITE") == true)
        #expect(suite("IO.EXAMPLE.OWN")?.hasPrefix("FLOTSAM_DEFAULTS_SUITE") == true)
        #expect(suite("/Users/someone/Library/Preferences/io.example.Own")?.hasPrefix("FLOTSAM_DEFAULTS_SUITE") == true)
        #expect(suite("../Preferences/io.example.Own")?.hasPrefix("FLOTSAM_DEFAULTS_SUITE") == true)
        // A different name is fine, including one that merely contains the app's id.
        #expect(suite("io.example.Own.agent") == nil)
        #expect(suite("io.example.Other") == nil)
        // And a Release build never reads the variable at all.
        #expect(LaunchIsolation.resolve(
            environment: ["FLOTSAM_DEFAULTS_SUITE": own], isDebugBuild: false, appDomain: own) == .success(.real))
    }

    @Test("the process answer in this (Debug) test build reads the real process environment")
    func fromProcessReadsTheEnvironment() {
        // Given the variables set in this process (the only test that touches them)
        setenv("FLOTSAM_FAKE_SECURE", "1", 1)
        setenv("FLOTSAM_FAKE_AUTH", "deny", 1)
        defer { unsetenv("FLOTSAM_FAKE_SECURE"); unsetenv("FLOTSAM_FAKE_AUTH"); unsetenv("FLOTSAM_DEFAULTS_SUITE") }
        // When the process answer is asked for
        // Then it carries what the environment said, not the real launch
        if case .success(let isolation) = LaunchIsolation.fromProcess() {
            #expect(isolation.fakeSecure && isolation.authScript == .deny)
        } else { Issue.record("a valid environment must resolve") }
    }
}

/// Empties the throwaway suite and deletes the preferences file it left, so a test run leaves nothing behind.
private func removeSuite(_ name: String) {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
        try? FileManager.default.removeItem(at: library.appendingPathComponent("Preferences/\(name).plist"))
    }
}

@Suite("TASK-519 launch isolation effects")
struct LaunchIsolationEffectsTests {
    @Test("a suite store writes to its own domain and not to the standard one")
    func suiteIsSeparate() throws {
        let name = "flotsam-519-\(UUID().uuidString)"
        defer { removeSuite(name) }
        let key = "task519.\(UUID().uuidString)"
        let store = try #require(LaunchIsolation(
            dataFolderOverride: nil, defaultsSuite: name, fakeSecure: false, authScript: .allow).settingsStore())
        store.setString("v", forKey: key)
        #expect(store.string(forKey: key) == "v")
        #expect(UserDefaults(suiteName: name)?.string(forKey: key) == "v")
        #expect(UserDefaults.standard.string(forKey: key) == nil)
        store.removeValue(forKey: key)
        #expect(store.string(forKey: key) == nil)
    }

    @Test("no suite means the standard domain: the store reads what standard holds")
    func noSuiteIsStandard() throws {
        // Read-only on the real domain: a key that standard certainly does not hold reads nil through both.
        let key = "task519.absent.\(UUID().uuidString)"
        let store = try #require(LaunchIsolation.real.settingsStore())
        #expect(store.string(forKey: key) == nil)
        #expect(UserDefaults.standard.string(forKey: key) == nil)
    }

    @Test("the in-memory key store keeps the first key and never touches anything outside memory")
    func inMemoryKeyStore() throws {
        let store = InMemorySecureKeyStore()
        #expect(try store.readKey().get() == nil)
        let first = Data(repeating: 1, count: 32)
        let second = Data(repeating: 2, count: 32)
        #expect(try store.storeKeyIfAbsent(first).get() == first)
        #expect(try store.storeKeyIfAbsent(second).get() == first)
        #expect(try store.readKey().get() == first)
        // A second store is a different, empty keychain.
        #expect(try InMemorySecureKeyStore().readKey().get() == nil)
    }

    @Test("the scripted authenticator confirms or denies exactly as scripted")
    func scriptedAuthenticator() async {
        let allow = await ScriptedAuthenticator(script: .allow).authenticate(reason: "r")
        #expect({ if case .success = allow { return true } else { return false } }())
        let deny = await ScriptedAuthenticator(script: .deny).authenticate(reason: "r")
        if case .failure(let error) = deny { #expect(error.code == .libOs002) } else { Issue.record("deny must fail") }
    }
}

@Suite("TASK-519 secure services selection")
struct LaunchIsolationSecureServicesTests {
    private struct RealKeys: SecureKeyStore {
        func readKey() -> FlotsamResult<Data?> { .success(nil) }
        func storeKeyIfAbsent(_ key: Data) -> FlotsamResult<Data> { .success(key) }
    }
    private struct RealAuth: UserAuthenticator {
        func authenticate(reason: String) async -> FlotsamResult<Void> { .success(()) }
    }

    @Test("fake secure builds the fakes and never constructs the real Keychain or LocalAuthentication services")
    func fakeNeverBuildsReal() {
        // Given a launch with the fakes on and a counter on the real factory
        var realBuilt = 0
        let isolation = LaunchIsolation(dataFolderOverride: nil, defaultsSuite: nil, fakeSecure: true, authScript: .deny)
        // When the services are chosen
        let services = isolation.secureServices { realBuilt += 1; return (RealKeys(), RealAuth()) }
        // Then the real factory ran zero times and the fakes came back, scripted as asked
        #expect(realBuilt == 0)
        #expect(services.keys is InMemorySecureKeyStore)
        #expect((services.authenticator as? ScriptedAuthenticator)?.script == .deny)
    }

    @Test("without fake secure the real services are used, built exactly once")
    func realUsedOtherwise() {
        var realBuilt = 0
        let services = LaunchIsolation.real.secureServices { realBuilt += 1; return (RealKeys(), RealAuth()) }
        #expect(realBuilt == 1)
        #expect(services.keys is RealKeys)
        #expect(services.authenticator is RealAuth)
    }
}

@Suite("TASK-519 single resolution home (source scan)")
struct LaunchIsolationSourceScanTests {
    private static let production = ["Packages/FlotsamCore/Sources", "App"]

    /// Each pattern is a use that reaches the real machine, with the only files that may contain it and why.
    private static let rules: [(pattern: String, homes: [String: String])] = [
        ("UserDefaults.standard", ["Packages/FlotsamCore/Sources/FlotsamBase/Ports/Adapters.swift": "the one UserDefaults adapter (ADR-0009)"]),
        ("UserDefaults(", ["Packages/FlotsamCore/Sources/FlotsamBase/Ports/Adapters.swift": "the one UserDefaults adapter (ADR-0009)"]),
        (".applicationSupportDirectory", ["Packages/FlotsamCore/Sources/FlotsamBase/Launch/LaunchIsolation.swift": "the data folder's home"]),
        ("realDataFolder", ["Packages/FlotsamCore/Sources/FlotsamBase/Launch/LaunchIsolation.swift": "the data folder's home"]),
        ("KeychainSecureKeyStore(", ["App/Flotsam/AppEnvironment.swift": "the secure store is chosen here"]),
        ("LocalAuthenticator(", ["App/Flotsam/AppEnvironment.swift": "the authenticator is chosen here"]),
        ("UserDefaultsStore(", ["Packages/FlotsamCore/Sources/FlotsamBase/Ports/Adapters.swift": "the adapter and the launch's settingsStore()"]),
        ("SecItemCopyMatching(", ["App/Platform/SystemKeychainKeyItem.swift": "the Keychain adapter, reached only through KeychainSecureKeyStore"]),
        ("SecItemAdd(", ["App/Platform/SystemKeychainKeyItem.swift": "the Keychain adapter, reached only through KeychainSecureKeyStore"]),
        ("LAContext", ["App/Platform/LocalAuthenticator.swift": "the LocalAuthentication adapter, reached only through LocalAuthenticator"]),
        // Spellings the plain patterns above would miss (QA, Worf): none may appear in production at all.
        ("NSUserDefaults", [:]), ("UserDefaults.init", [:]), ("UserDefaults .standard", [:]), ("UserDefaults.self", [:]),
        (": UserDefaults = .standard", [:]), ("AppStorage", [:]), ("SceneStorage", [:]), ("NSUserDefaultsController", [:]),
        ("CFPreferencesSetAppValue", [:]), ("CFPreferencesSetValue", [:]), ("CFPreferencesSetMultiple", [:]),
        ("NSHomeDirectory", [:]), ("NSSearchPathForDirectoriesInDomains", [:]), (".libraryDirectory", [:]),
        (".cachesDirectory", [:]), (".documentDirectory", [:]), ("SecItemUpdate", [:]), ("SecItemDelete", [:]),
        ("kSecClass", ["App/Platform/SystemKeychainKeyItem.swift": "the Keychain adapter"]),
        ("import LocalAuthentication", ["App/Platform/LocalAuthenticator.swift": "the LocalAuthentication adapter"]),
        ("autosaveName", [:]),
        // Exempt by design (docs/AGENT-LAUNCH.md): the screenshot folder is the user's real one and is not isolated.
        ("homeDirectoryForCurrentUser", ["App/Flotsam/AppContainer.swift": "screenshot pickup resolves the real ~/Desktop; shared, documented"]),
    ]

    @Test("the scan finds the files it is meant to scan")
    func scanSeesTheTree() {
        let paths = Self.production.flatMap(swiftSources(under:)).map(\.path)
        #expect(paths.contains("App/Flotsam/AppContainer.swift"))
        #expect(paths.contains("App/Flotsam/AppEnvironment.swift"))
        #expect(paths.contains("Packages/FlotsamCore/Sources/FlotsamBase/Launch/LaunchIsolation.swift"))
    }

    @Test("every use that reaches real data sits in its one home")
    func usesGoThroughTheHome() {
        let files = Self.production.flatMap(swiftSources(under:))
        for rule in Self.rules {
            let found = files.filter { code($0.text).contains(rule.pattern) }.map(\.path).sorted()
            #expect(found.allSatisfy { rule.homes[$0] != nil }, "\(rule.pattern) used outside \(rule.homes.keys.sorted()): \(found)")
            // The home must still use it, so a stale entry cannot hide a moved use.
            // Only a ban (a rule with no home) may go unused: the spelling is already gone from production.
            #expect(!found.isEmpty || rule.homes.isEmpty || rule.pattern == "UserDefaults.standard", "\(rule.pattern) is no longer used anywhere: drop its rule")
        }
    }

    @Test("AppEnvironment resolves the process and takes every value from the resolution, nothing from the real machine")
    func environmentUsesResolution() throws {
        let file = try #require(swiftSources(under: "App/Flotsam").first { $0.path.hasSuffix("/AppEnvironment.swift") })
        let text = code(file.text)
        for needed in ["LaunchIsolation.fromProcess()", "isolation.dataFolder", "isolation.settingsStore()", "isolation.secureServices"] {
            #expect(text.contains(needed), "AppEnvironment no longer uses \(needed)")
        }
        #expect(!text.contains("realDataFolder"))
        #expect(!text.contains(".success(.real)"))
    }

    @Test("the suite check defaults to the running app's bundle id (a test process has none, so it is pinned in the source)")
    func appDomainDefaultsToBundleId() throws {
        let file = try #require(swiftSources(under: "Packages/FlotsamCore/Sources/FlotsamBase/Launch").first { $0.path.hasSuffix("LaunchIsolation.swift") })
        #expect(code(file.text).contains("appDomain: String? = Bundle.main.bundleIdentifier"))
    }

    @Test("the composition root takes the folder, the settings and the secure services from AppEnvironment")
    func containerUsesEnvironment() throws {
        let container = try #require(swiftSources(under: "App/Flotsam").first { $0.path.hasSuffix("/AppContainer.swift") })
        let text = code(container.text)
        for needed in ["environment.dataFolder", "environment.settingsStore", "environment.secureKeys", "environment.authenticator"] {
            #expect(text.contains(needed), "AppContainer no longer uses \(needed)")
        }
        #expect(!text.contains(".standard"))
    }

    @Test("Release compiles no isolation variable, parser or fake: all of it is inside #if DEBUG")
    func releaseHasNoIsolationCode() {
        let files = Self.production.flatMap(swiftSources(under:))
        for (path, text) in files {
            let release = code(releaseText(text))
            for banned in ["FLOTSAM_", "InMemorySecureKeyStore", "ScriptedAuthenticator", "isDebugBuild", "dataDirVariable"] {
                #expect(!release.contains(banned), "\(path) would ship \(banned) in Release")
            }
        }
        // The stripper itself removes what it should (guards the guard).
        let sample = "a\n#if DEBUG\nFLOTSAM_X\n#if os(macOS)\ninner\n#endif\nmore\n#endif\nb"
        #expect(releaseText(sample) == "a\nb")
    }

    @Test("the fakes file is wholly DEBUG")
    func fakesWhollyDebug() throws {
        let fakes = try #require(swiftSources(under: "Packages/FlotsamCore/Sources/FlotsamBase/Launch").first { $0.path.hasSuffix("LaunchFakes.swift") })
        #expect(releaseText(fakes.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
